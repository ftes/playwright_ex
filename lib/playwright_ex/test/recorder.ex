defmodule PlaywrightEx.Test.Recorder do
  @moduledoc false
  # The artifacts of one test (`PlaywrightEx.Test.record_artifacts/2`), after Playwright Test's
  # `ArtifactsRecorder`, `SnapshotRecorder` and `_contextFactory`
  # (`packages/playwright/src/index.ts`) and `mergeTraceFiles`
  # (`packages/playwright/src/worker/testTracing.ts`).
  #
  # A process per test, alive from the test's setup to the end of its `on_exit`: it remembers
  # the test's contexts and anchors them (so their pages and videos stay readable after the
  # process that created or closed them exits). Its listener (`ClientInstrumentation`) runs in
  # the processes that create and close contexts; `finish/2` runs in ExUnit's `on_exit`
  # process, once the test's result is known (`PlaywrightEx.Test.Pool.result/2`), and keeps or
  # drops the artifacts by it. Every artifact step rescues and logs: an exception in `on_exit`
  # would fail the test and hide its own error, and upstream's artifact code swallows its errors
  # too.
  use GenServer

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Video

  require Logger

  # The `test_pid` `PlaywrightEx.Test.new_context/2` puts while it creates a context, so the
  # listener records a context made in a process with no `$callers` (a GenServer).
  @identity {PlaywrightEx.Test, :identity}

  @doc "Runs `fun` as the test `test_pid`: the contexts it creates are the test's."
  def with_identity(test_pid, fun) do
    previous = Process.put(@identity, test_pid)

    try do
      fun.()
    after
      if previous, do: Process.put(@identity, previous), else: Process.delete(@identity)
    end
  end

  @doc """
  The parameters of `context` in `module` (`%{}` for a module without `parameterize:`), for its
  output dir: a guess, the module's parameter map whose keys have the context's values.
  """
  def parameters(module, context) do
    case parameterize(module) do
      list when is_list(list) -> Enum.find(list, %{}, &(is_map(&1) and Map.take(context, Map.keys(&1)) == &1))
      _ -> %{}
    end
  end

  # `__ex_unit__(:config)` is ExUnit's internal API (`@doc false`; a map with `:parameterize`
  # in 1.18 to 1.20): any other shape is no parameters.
  defp parameterize(module) do
    case Code.ensure_loaded?(module) and function_exported?(module, :__ex_unit__, 1) and module.__ex_unit__(:config) do
      %{parameterize: list} -> list
      _ -> nil
    end
  end

  @doc "A test name without its macro's prefix (`test `, or the context's `test_type`)."
  def test_name(%{test: test} = context),
    do: test |> to_string() |> String.replace_prefix("#{context[:test_type] || :test} ", "")

  @doc "Upstream's `testInfo.titlePath`: the file, the describe block, the test."
  def title_path(%{file: file} = context) do
    name = test_name(context)

    case context[:describe] do
      nil -> [Path.relative_to_cwd(file), name]
      describe -> [Path.relative_to_cwd(file), describe, String.replace_prefix(name, describe <> " ", "")]
    end
  end

  @doc "The recorder of the test `test_pid`, or `nil`."
  def lookup(test_pid) do
    case Pool.started?() && :ets.lookup(Pool.table(), {:recorder, test_pid}) do
      [{_, pid}] -> pid
      _ -> nil
    end
  end

  @doc "Starts the recorder of the test `test_pid`. Not linked: it outlives the test process, until `finish/2`."
  def start(test_pid, opts) do
    Pool.ensure_started()
    {:ok, pid} = GenServer.start(__MODULE__, {test_pid, opts})
    :ets.insert(Pool.table(), {{:recorder, test_pid}, pid})
    pid
  end

  @doc "Adds the recorder's listener to `instrumentation` (once)."
  def ensure_listener(pid, instrumentation), do: GenServer.call(pid, {:ensure_listener, instrumentation}, :infinity)

  @impl true
  def init({test_pid, opts}) do
    tmp = Path.join(System.tmp_dir!(), "playwright_ex-test-#{System.unique_integer([:positive])}")
    opts = Map.put(opts, :tmp, tmp)
    this = self()

    listener = %{
      runBeforeCreateBrowserContext: &before_create(&1, test_pid, opts),
      runAfterCreateBrowserContext: &after_create(&1, this, test_pid, opts),
      runBeforeCloseBrowserContext: &before_close(&1, this, test_pid, opts)
    }

    # `contexts` in creation order, `closed` (guids) in close order, `screenshots` (temporary
    # files) in capture order; `snapshotted` the guids of the pages with a screenshot, `ordinal`
    # the screenshots named so far (upstream's `SnapshotRecorder`).
    {:ok,
     %{
       test_pid: test_pid,
       opts: opts,
       listener: listener,
       instrumentations: [],
       contexts: [],
       closed: [],
       chunks: [],
       screenshots: [],
       snapshotted: MapSet.new(),
       ordinal: 0,
       page_snapshot: nil
     }}
  end

  @impl true
  def handle_call({:ensure_listener, instrumentation}, _from, state) do
    if instrumentation in state.instrumentations do
      {:reply, :ok, state}
    else
      ClientInstrumentation.add_listener(instrumentation, state.listener)
      {:reply, :ok, %{state | instrumentations: [instrumentation | state.instrumentations]}}
    end
  end

  def handle_call({:add_context, context}, _from, state) do
    # The recorder anchors the context: its videos are saved after its creator may have exited.
    ChannelOwner._set_creator(context)
    {:reply, :ok, %{state | contexts: state.contexts ++ [%{guid: context.guid, context: context, pages: []}]}}
  end

  def handle_call({:closed, guid}, _from, state), do: {:reply, :ok, %{state | closed: state.closed ++ [guid]}}

  def handle_call({:add_screenshot, path}, _from, state),
    do: {:reply, :ok, %{state | screenshots: state.screenshots ++ [path]}}

  # `_snapshotPage`: a page once per test.
  def handle_call({:snapshot?, guid}, _from, state) do
    if MapSet.member?(state.snapshotted, guid),
      do: {:reply, false, state},
      else: {:reply, true, %{state | snapshotted: MapSet.put(state.snapshotted, guid)}}
  end

  # `maybeCapture`'s pages: those of the open contexts without a screenshot, each with the path
  # of its screenshot (`_createAttachmentPath`).
  def handle_call({:capture, failed?}, _from, state) do
    pages =
      for %{guid: guid, context: context} <- state.contexts,
          guid not in state.closed,
          page <- step("list the pages", fn -> BrowserContext.pages(context) end) || [],
          not MapSet.member?(state.snapshotted, page.guid),
          do: page

    {paths, ordinal} =
      Enum.map_reduce(pages, state.ordinal, fn page, ordinal ->
        {{page, attachment_path(state.opts.dir, failed?, ordinal)}, ordinal + 1}
      end)

    snapshotted = Enum.reduce(pages, state.snapshotted, &MapSet.put(&2, &1.guid))
    {:reply, {paths, state.opts}, %{state | ordinal: ordinal, snapshotted: snapshotted}}
  end

  def handle_call({:add_chunk, path}, _from, state), do: {:reply, :ok, %{state | chunks: state.chunks ++ [path]}}
  def handle_call({:page_snapshot, snapshot}, _from, state), do: {:reply, :ok, %{state | page_snapshot: snapshot}}
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def terminate(_reason, state), do: File.rm_rf(state.opts.tmp)

  @impl true
  def handle_cast({:add_page, guid, page}, state) do
    contexts =
      Enum.map(state.contexts, fn
        %{guid: ^guid, pages: pages} = entry -> if page in pages, do: entry, else: %{entry | pages: pages ++ [page]}
        entry -> entry
      end)

    {:noreply, %{state | contexts: contexts}}
  end

  # The listener. It runs in the process that creates or closes a context, for every context of
  # the driver: only the test's own count.
  defp ours?(test_pid) do
    self() == test_pid or test_pid in List.wrap(Process.get(:"$callers")) or Process.get(@identity) == test_pid
  end

  # `_contextFactory`: `browser.newContext({ ...videoOptions, ...options })`.
  defp before_create(options, test_pid, opts) do
    if opts.video[:mode] != :off and not Map.has_key?(options, :recordVideo) and ours?(test_pid),
      do:
        Map.put(
          options,
          :recordVideo,
          Map.new([dir: Path.join(opts.tmp, "videos")] ++ Keyword.take(opts.video, [:size]))
        ),
      else: options
  end

  # A row `{{:context, guid}, recorder}` per recorded context: `before_close` reads it, no call
  # into every test's recorder on each close.
  defp after_create(context, recorder, test_pid, opts) do
    if ours?(test_pid) and :ets.insert_new(Pool.table(), {{:context, context.guid}, recorder}) do
      call(recorder, {:add_context, context})
      record(context, recorder, opts)
    end

    nil
  end

  defp record(context, recorder, opts) do
    if opts.trace[:mode] != :off, do: step("start tracing", fn -> start_tracing(context, opts) end)
    if opts.video[:mode] != :off, do: step("follow the context's pages", fn -> follow_pages(context, recorder) end)
  end

  # `_startTraceChunkOnContextCreation`: `tracing.start({ ...options, title, name })`.
  defp start_tracing(context, opts) do
    Tracing.start!(
      BrowserContext.tracing(context),
      Keyword.delete(opts.trace, :mode) ++
        [title: opts.title, name: "playwright_ex-#{System.unique_integer([:positive])}"]
    )
  end

  defp follow_pages(context, recorder) do
    BrowserContext.on(context, :page, &GenServer.cast(recorder, {:add_page, context.guid, &1}))
    for page <- BrowserContext.pages(context), do: GenServer.cast(recorder, {:add_page, context.guid, page})
  end

  # `willCloseBrowserContext`: the trace chunk, the screenshots (`captureTemporary`), then the
  # page snapshot (`_takePageSnapshot`).
  # Taking the row makes it once per context, also when closes race.
  defp before_close(context, recorder, test_pid, opts) do
    if :ets.select_delete(Pool.table(), [{{{:context, context.guid}, recorder}, [], [true]}]) == 1 do
      call(recorder, {:closed, context.guid})
      collect(context, recorder, test_pid, opts)
    end

    nil
  end

  defp collect(context, recorder, test_pid, opts) do
    if opts.trace[:mode] != :off, do: step("save the trace", fn -> stop_tracing(context, recorder, opts) end)
    if opts.screenshot[:mode] != :off, do: screenshots(context, recorder, opts)
    step("take a page snapshot", fn -> page_snapshot(context, recorder, test_pid) end)
  end

  # `_takePageSnapshot`: once per test, of the first page, when the test failed (upstream's
  # `testInfo.errors`) without a matcher's snapshot. A context closed while the test runs has no
  # errors yet, as upstream's.
  defp page_snapshot(context, recorder, test_pid) do
    with false <- Process.alive?(test_pid),
         {:failed, failures} <- Pool.result(test_pid, 5000),
         false <- Enum.any?(failures, &ErrorContext.error(&1).error_context),
         %{page_snapshot: nil} <- call(recorder, :state),
         [page | _] <- BrowserContext.pages(context),
         # The snapshot may fail: ignored, as upstream's.
         {:ok, snapshot} <- Page.aria_snapshot(page, mode: :ai, timeout: 5000),
         do: call(recorder, {:page_snapshot, snapshot})
  end

  defp stop_tracing(context, recorder, opts) do
    File.mkdir_p!(opts.tmp)
    path = Path.join(opts.tmp, "#{System.unique_integer([:positive])}.zip")
    Tracing.stop_chunk!(BrowserContext.tracing(context), path: path)
    call(recorder, {:add_chunk, path})
  end

  # `SnapshotRecorder.captureTemporary`: the pages without a screenshot yet, to temporary files
  # kept by `persist_screenshots/2`.
  defp screenshots(context, recorder, opts) do
    for page <- step("list the pages", fn -> BrowserContext.pages(context) end) || [],
        call(recorder, {:snapshot?, page.guid}),
        path = Path.join([opts.tmp, "screenshots", "#{System.unique_integer([:positive])}.png"]),
        step("take a screenshot", fn -> screenshot(page, path, opts) end),
        do: call(recorder, {:add_screenshot, path})
  end

  # `page.screenshot({ ...screenshotOptions, timeout: 5000, path, caret: 'initial' })`.
  defp screenshot(page, path, opts) do
    File.mkdir_p!(Path.dirname(path))
    Page.screenshot!(page, Keyword.delete(opts.screenshot, :mode) ++ [timeout: 5000, path: path, caret: :initial])
  end

  defp attachment_path(dir, failed?, ordinal),
    do: Path.join(dir, "test-#{if failed?, do: "failed", else: "finished"}-#{ordinal + 1}.png")

  @doc """
  `SnapshotRecorder.maybeCapture` (upstream's `didFinishTestFunction`, and the start of
  `didFinishTest`): a screenshot of each page of the test's open contexts without one yet,
  `test-failed-N.png` or `test-finished-N.png`. For the modes that keep them.
  """
  def capture(pid, failed?) do
    {paths, opts} = GenServer.call(pid, {:capture, failed?}, :infinity)

    paths
    |> Task.async_stream(fn {page, path} -> step("take a screenshot", fn -> screenshot(page, path, opts) end) end,
      timeout: :infinity
    )
    |> Stream.run()
  end

  defp call(recorder, message) do
    GenServer.call(recorder, message, :infinity)
  catch
    # The test is over.
    :exit, _ -> nil
  end

  @doc """
  The end of the test (its first `on_exit`, so it runs last): within `budget` ms (ExUnit's
  `on_exit` shares the test's timeout), waits for the test's result, closes its contexts still
  open, then keeps the videos, trace and screenshots as the modes and the result say and writes
  `error-context.md` of a failure. Then, whatever happened, removes the listener and stops the
  recorder.
  """
  def finish(pid, budget) do
    task = Task.async(fn -> step("finish the recording", fn -> collect_all(pid, budget) end) end)
    finished? = Task.yield(task, budget) != nil

    if !finished? do
      Task.shutdown(task, :brutal_kill)
      log("finish the recording", "it took over #{budget} ms")
    end

    step("remove the listener", fn ->
      state = GenServer.call(pid, :state, :infinity)
      for instrumentation <- state.instrumentations, do: remove_listener(instrumentation, state.listener)
      if !finished?, do: close_leftovers(state)
    end)

    :ok
  after
    :ets.match_delete(Pool.table(), {{:recorder, :_}, pid})
    :ets.match_delete(Pool.table(), {{:context, :_}, pid})
    step("stop the recorder", fn -> GenServer.stop(pid) end)
  end

  defp collect_all(pid, budget) do
    state = GenServer.call(pid, :state, :infinity)
    {verdict, failures} = Pool.result(state.test_pid, budget)
    # A test of another macro (a doctest) has no result: kept as a failure's.
    failed? = verdict != :passed

    # `didFinishTest`: the open pages' screenshots, then the leftover contexts. A shared browser
    # outlives the test.
    if capture?(state.opts.screenshot[:mode], failed?), do: capture(pid, failed?)

    for %{guid: guid, context: context} <- state.contexts,
        guid not in state.closed,
        do: step("close a context", fn -> BrowserContext.close!(context, reason: "Test ended.") end)

    state = GenServer.call(pid, :state, :infinity)
    save_videos(state, failed?)
    save_trace(state, failed?)
    persist_screenshots(state, failed?)

    if verdict == :failed do
      info = Map.merge(Map.take(state.opts, [:dir, :title_path, :location]), %{page_snapshot: state.page_snapshot})
      step("write error-context.md", fn -> ErrorContext.write(info, failures) end)
    end
  end

  # Past the budget: the contexts still open are closed in the background, so they don't pile up
  # in a shared browser. The task anchors them before the recorder stops.
  defp close_leftovers(state) do
    leftovers = for %{guid: guid, context: context} <- state.contexts, guid not in state.closed, do: context
    {parent, ref} = {self(), make_ref()}

    if leftovers != [] do
      Task.start(fn ->
        Enum.each(leftovers, &ChannelOwner._set_creator/1)
        send(parent, ref)
        Enum.each(leftovers, &close_leftover/1)
      end)

      receive do
        ^ref -> :ok
      after
        5000 -> :ok
      end
    end
  end

  defp close_leftover(context),
    do: step("close a context", fn -> BrowserContext.close(context, reason: "Test ended.") end)

  # Exactly this listener: the ported `remove_listener` removes the last one for an unknown
  # listener, on a shared driver another test's. The listeners are rows of the connection's
  # table, written in its process: after the driver closed, they are gone with it.
  defp remove_listener(instrumentation, listener) do
    Heap.update(instrumentation, :listeners, &List.delete(&1, listener))
  rescue
    e in PlaywrightEx.TargetClosedError -> if e.message != "Playwright driver closed", do: reraise(e, __STACKTRACE__)
  end

  # `_contextFactory`'s close (`shouldPreserveVideo`): `video.webm`, `video-1.webm`, ... in the
  # order the contexts closed. The artifact options have their `mode` first.
  defp save_videos(%{opts: %{video: [{:mode, video} | _]}} = state, failed?)
       when video == :on or (video == :retain_on_failure and failed?) do
    by_guid = Map.new(state.contexts, &{&1.guid, &1})
    open = for %{guid: guid} <- state.contexts, guid not in state.closed, do: guid
    pages = for guid <- state.closed ++ open, page <- by_guid[guid].pages, do: page
    videos = for page <- pages, video = step("find a video", fn -> Page.video(page) end), video != nil, do: video

    for {video, i} <- Enum.with_index(videos) do
      path = Path.join(state.opts.dir, if(i == 0, do: "video.webm", else: "video-#{i}.webm"))
      step("save a video", fn -> save_video(video, path) end)
    end
  end

  # The recording goes with the recorder's temporary dir.
  defp save_videos(_state, _failed?), do: :ok

  defp save_video(video, path) do
    File.mkdir_p!(Path.dirname(path))
    Video.save_as!(video, path)
  end

  # `testTracing`'s `_shouldAbandonTrace`: a passed test's trace with `retain_on_failure`.
  defp save_trace(%{opts: %{trace: [{:mode, trace} | _]}} = state, failed?)
       when trace == :on or (trace == :retain_on_failure and failed?),
       do: step("merge the traces", fn -> merge_traces(Path.join(state.opts.dir, "trace.zip"), state.chunks) end)

  defp save_trace(_state, _failed?), do: :ok

  # `shouldCaptureUponFinish`.
  defp capture?(mode, failed?), do: mode == :on or (mode == :only_on_failure and failed?)

  # `SnapshotRecorder.persistTemporary`: `test-failed-N.png` of a failed test, else
  # `test-finished-N.png` (`on` only), in capture order, numbered after those taken at the end.
  defp persist_screenshots(state, failed?) do
    for {file, ordinal} <- Enum.with_index(state.screenshots, state.ordinal),
        capture?(state.opts.screenshot[:mode], failed?),
        path = attachment_path(state.opts.dir, failed?, ordinal),
        do: step("save a screenshot", fn -> save_screenshot(file, path) end)
  end

  defp save_screenshot(file, path) do
    File.mkdir_p!(Path.dirname(path))
    File.cp!(file, path)
  end

  @doc """
  Upstream's `mergeTraceFiles`: one trace of all of the test's chunks, each cut to its own stacks
  (`own_stacks/2`). With several chunks, newest first, `*trace.<ext>` entries get their chunk's
  index as a prefix, other entries (resources) are kept once. Returns `:none` without chunks.
  """
  def merge_traces(path, chunks) do
    case Enum.filter(chunks, &File.exists?/1) do
      [] ->
        :none

      chunks ->
        {entries, _names} =
          chunks
          |> Enum.with_index()
          |> Enum.reverse()
          |> Enum.reduce({[], MapSet.new()}, fn {chunk, i}, acc ->
            Enum.reduce(read_chunk(chunk), acc, &merge_entry(&1, prefix(i, chunks), &2))
          end)

        File.mkdir_p!(Path.dirname(path))
        {:ok, _} = :zip.create(String.to_charlist(path), Enum.reverse(entries))
        Enum.each(chunks, &File.rm/1)
        :ok
    end
  end

  defp prefix(_i, [_chunk]), do: ""
  defp prefix(i, _chunks), do: "#{i}-"

  defp read_chunk(chunk) do
    {:ok, files} = :zip.unzip(String.to_charlist(chunk), [:memory])
    files = Enum.map(files, fn {name, data} -> {to_string(name), data} end)
    own_stacks(files, List.keyfind(files, "trace.stacks", 0))
  end

  # The driver adds every call's stack to every trace recording on its connection
  # (`addStackToTracingNoReply`), on a shared driver concurrent tests' too. Keeps the stacks of
  # the chunk's own actions (by `callId`), as `serializeClientSideCallMetadata` writes them, and
  # the `src/<sha1(file)><ext>` sources of their frames.
  defp own_stacks(files, nil), do: files

  defp own_stacks(files, {_, data}) do
    ids =
      for {name, trace} <- files,
          Path.extname(name) == ".trace",
          line <- String.split(trace, "\n", trim: true),
          into: MapSet.new(),
          do: JSON.decode!(line)["callId"]

    %{"files" => paths, "stacks" => stacks} = JSON.decode!(data)
    stacks = Enum.filter(stacks, fn [id, _frames] -> id in ids end)
    used = stacks |> Enum.flat_map(fn [_id, frames] -> Enum.map(frames, &hd/1) end) |> Enum.uniq()
    index = used |> Enum.with_index() |> Map.new()
    stacks = for [id, frames] <- stacks, do: [id, for([file | rest] <- frames, do: [index[file] | rest])]
    paths = Enum.map(used, &Enum.at(paths, &1))
    sources = MapSet.new(paths, &"src/#{sha1(&1)}#{Path.extname(&1)}")
    stacks_data = JSON.encode!(%{files: paths, stacks: stacks})

    for {name, _} = file <- files,
        not String.starts_with?(name, "src/") or name in sources,
        do: if(name == "trace.stacks", do: {name, stacks_data}, else: file)
  end

  defp merge_entry({name, data}, prefix, {entries, names}) do
    name = if name != "test.trace" and name =~ ~r/trace\.[a-z]*$/, do: prefix <> name, else: name

    if MapSet.member?(names, name),
      do: {entries, names},
      else: {[{String.to_charlist(name), data} | entries], MapSet.put(names, name)}
  end

  @doc "The output dir of the test of `context` (see `output_dir/5`)."
  def output_dir(%{module: module, file: file} = context),
    do:
      output_dir(PlaywrightEx.Test.Options.output_dir(), file, test_name(context), module, parameters(module, context))

  @doc """
  A test's output dir under `root`, as upstream's `testInfo.outputDir`: the file relative to
  `test/` without `_test.exs`, `/` as `-`, then `-` and the sanitized test `name`, trimmed to 60
  characters (`trimLongString`). Then `-` and a hash of the module and parameters, as upstream
  appends the project: modules of a file, or parameter sets, may share a test name.
  """
  def output_dir(root, file, name, module, parameters) do
    relative =
      file |> relative_test_file() |> String.replace_suffix("_test.exs", "") |> String.replace_suffix(".exs", "")

    name = trim_long_string(String.replace(relative, "/", "-") <> "-" <> sanitize_for_file_path(name), 60)

    Path.join(root, name <> "-" <> short_hash(:erlang.term_to_binary({module, parameters}, [:deterministic])))
  end

  @doc "Upstream's `testDir`: `test/` of the working directory."
  def test_dir, do: Path.join(File.cwd!(), "test")

  @doc "A test file relative to `test_dir/0` (upstream's `path.relative(testDir, file)`), else to the working directory."
  def relative_test_file(file) do
    file = Path.expand(file)

    if String.starts_with?(file, test_dir() <> "/"),
      do: Path.relative_to(file, test_dir()),
      else: Path.relative_to(file, File.cwd!())
  end

  @doc "Upstream's `sanitizeForFilePath`."
  def sanitize_for_file_path(s), do: Regex.replace(~r/[\x00-\x2C\x2E-\x2F\x3A-\x40\x5B-\x60\x7B-\x7F]+/, s, "-")

  @doc "Upstream's `trimLongString` (`windowsFilesystemFriendlyLength` is 60)."
  def trim_long_string(s, length \\ 100) do
    if String.length(s) <= length do
      s
    else
      middle = "-#{short_hash(s)}-"
      start = div(length - String.length(middle), 2)
      ending = length - String.length(middle) - start
      String.slice(s, 0, start) <> middle <> String.slice(s, -ending, ending)
    end
  end

  defp sha1(data), do: :crypto.hash(:sha, data) |> Base.encode16(case: :lower)
  defp short_hash(data), do: binary_part(sha1(data), 0, 5)

  defp step(what, fun) do
    fun.()
  rescue
    exception -> log(what, Exception.message(exception))
  catch
    kind, reason -> log(what, Exception.format_banner(kind, reason))
  end

  defp log(what, message) do
    Logger.warning("PlaywrightEx.Test could not #{what}: #{message}")
    nil
  end
end
