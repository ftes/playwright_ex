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
  # process. Every artifact step rescues and logs: an exception in `on_exit` would fail the
  # test and hide its own error, and upstream's artifact code swallows its errors too.
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

  @doc "A test's key, `{module, name, parameters}`, as the formatter gets it (`%ExUnit.Test{}`)."
  def test_key(%{module: module, test: test} = context), do: {module, test, parameters(module, context)}

  @doc """
  The parameters of `context` in `module` (`%{}` for a module without `parameterize:`): a guess,
  the module's parameter map whose keys have the context's values.
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

  @doc """
  Starts the recorder of the test `test_pid` (`opts.test_key` names its retained files for the
  formatter). Not linked: it outlives the test process, until `finish/2`.
  """
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
      runBeforeCloseBrowserContext: &before_close(&1, this, opts)
    }

    # `contexts` in creation order, `closed` (guids) in close order.
    {:ok,
     %{
       opts: opts,
       listener: listener,
       instrumentations: [],
       contexts: [],
       closed: [],
       chunks: [],
       screenshots: 0,
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

  def handle_call(:next_screenshot, _from, state),
    do: {:reply, state.screenshots + 1, %{state | screenshots: state.screenshots + 1}}

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
    if opts.video != :off and not Map.has_key?(options, :recordVideo) and ours?(test_pid),
      do: Map.put(options, :recordVideo, %{dir: Path.join(opts.tmp, "videos")}),
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
    if opts.trace != :off, do: step("start tracing", fn -> start_tracing(context, opts) end)
    if opts.video != :off, do: step("follow the context's pages", fn -> follow_pages(context, recorder) end)
  end

  # `_startTraceChunkOnContextCreation`, with upstream's default trace options.
  defp start_tracing(context, opts) do
    Tracing.start!(BrowserContext.tracing(context),
      name: "playwright_ex-#{System.unique_integer([:positive])}",
      title: opts.title,
      screenshots: true,
      snapshots: true,
      sources: true
    )
  end

  defp follow_pages(context, recorder) do
    BrowserContext.on(context, :page, &GenServer.cast(recorder, {:add_page, context.guid, &1}))
    for page <- BrowserContext.pages(context), do: GenServer.cast(recorder, {:add_page, context.guid, page})
  end

  # `willCloseBrowserContext`: the trace chunk, the screenshots (`captureTemporary`), then the
  # page snapshot (`_takePageSnapshot`).
  # Taking the row makes it once per context, also when closes race.
  defp before_close(context, recorder, opts) do
    if :ets.select_delete(Pool.table(), [{{{:context, context.guid}, recorder}, [], [true]}]) == 1 do
      call(recorder, {:closed, context.guid})
      collect(context, recorder, opts)
    end

    nil
  end

  defp collect(context, recorder, opts) do
    if opts.trace != :off, do: step("save the trace", fn -> stop_tracing(context, recorder, opts) end)
    if opts.screenshot != :off, do: screenshots(context, recorder, opts)
    if opts.error_context, do: step("take a page snapshot", fn -> page_snapshot(context, recorder) end)
  end

  # `_takePageSnapshot` (`packages/playwright/src/index.ts:767`): once per test, of the first page.
  # Taken for every test, passed or not: ExUnit tells `on_exit` nothing of the result.
  defp page_snapshot(context, recorder) do
    with %{page_snapshot: nil} <- call(recorder, :state),
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

  defp screenshots(context, recorder, opts) do
    for page <- step("list the pages", fn -> BrowserContext.pages(context) end) || [],
        do: step("take a screenshot", fn -> screenshot(page, recorder, opts) end)
  end

  # `SnapshotRecorder`: `page.screenshot({ timeout: 5000, path, caret: 'initial' })`, named
  # `test-finished-N.png` (`on`) or `test-failed-N.png` (`only_on_failure`, kept on failure only).
  defp screenshot(page, recorder, opts) do
    kind = if opts.screenshot == :only_on_failure, do: "failed", else: "finished"
    path = Path.join(opts.dir, "test-#{kind}-#{call(recorder, :next_screenshot)}.png")
    Page.screenshot!(page, path: path, timeout: 5000, caret: :initial)
  end

  defp call(recorder, message) do
    GenServer.call(recorder, message, :infinity)
  catch
    # The test is over.
    :exit, _ -> nil
  end

  @doc """
  The end of the test (its first `on_exit`, so it runs last): closes the test's contexts still
  open, saves the videos, merges the trace and notes the files to delete if the test passes,
  within `budget` ms (ExUnit's `on_exit` shares the test's timeout). Then, whatever happened,
  removes the listener and stops the recorder.
  """
  def finish(pid, budget) do
    task = Task.async(fn -> step("finish the recording", fn -> collect_all(pid) end) end)
    finished? = Task.yield(task, budget) != nil

    if !finished? do
      Task.shutdown(task, :brutal_kill)
      log("finish the recording", "it took over #{budget} ms")
    end

    step("remove the listener", fn ->
      state = GenServer.call(pid, :state, :infinity)
      for instrumentation <- state.instrumentations, do: remove_listener(instrumentation, state.listener)
      if !finished?, do: close_leftovers(state)

      # For the formatter: `error-context.md` if the test failed.
      if state.opts.error_context do
        info = Map.merge(Map.take(state.opts, [:dir, :title_path, :location]), %{page_snapshot: state.page_snapshot})
        :ets.insert(Pool.table(), {{:error_context, state.opts.test_key}, info})
      end
    end)

    :ok
  after
    :ets.match_delete(Pool.table(), {{:recorder, :_}, pid})
    :ets.match_delete(Pool.table(), {{:context, :_}, pid})
    step("stop the recorder", fn -> GenServer.stop(pid) end)
  end

  defp collect_all(pid) do
    state = GenServer.call(pid, :state, :infinity)

    # `didFinishTest`: the leftover contexts. A shared browser outlives the test.
    for %{guid: guid, context: context} <- state.contexts,
        guid not in state.closed,
        do: step("close a context", fn -> BrowserContext.close!(context, reason: "Test ended.") end)

    state = GenServer.call(pid, :state, :infinity)
    retained = save_videos(state) ++ save_trace(state) ++ failure_screenshots(state)
    if retained != [], do: :ets.insert(Pool.table(), {{:retained, state.opts.test_key}, retained})
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

  # `_contextFactory`'s close: `video.webm`, `video-1.webm`, ... in the order the contexts closed.
  defp save_videos(%{opts: %{video: :off}}), do: []

  defp save_videos(state) do
    by_guid = Map.new(state.contexts, &{&1.guid, &1})
    open = for %{guid: guid} <- state.contexts, guid not in state.closed, do: guid
    pages = for guid <- state.closed ++ open, page <- by_guid[guid].pages, do: page
    videos = for page <- pages, video = step("find a video", fn -> Page.video(page) end), video != nil, do: video

    saved =
      for {video, i} <- Enum.with_index(videos),
          path = Path.join(state.opts.dir, if(i == 0, do: "video.webm", else: "video-#{i}.webm")),
          step("save a video", fn -> save_video(video, path) end),
          do: path

    if state.opts.video == :retain_on_failure, do: saved, else: []
  end

  defp save_video(video, path) do
    File.mkdir_p!(Path.dirname(path))
    Video.save_as!(video, path)
  end

  defp save_trace(%{opts: %{trace: :off}}), do: []

  defp save_trace(state) do
    path = Path.join(state.opts.dir, "trace.zip")

    case step("merge the traces", fn -> merge_traces(path, state.chunks) end) do
      :ok when state.opts.trace == :retain_on_failure -> [path]
      _ -> []
    end
  end

  defp failure_screenshots(%{opts: %{screenshot: :only_on_failure, dir: dir}}),
    do: Path.wildcard(Path.join(dir, "test-failed-*.png"))

  defp failure_screenshots(_state), do: []

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

  @doc """
  Called by the formatter with the test's `state`: deletes the retained files of a passing test
  (and its dir if empty), writes `error-context.md` of a failed one (`didFinishTest`).
  """
  def test_finished(key, state) do
    {retained, error_context} =
      if Pool.started?(),
        do: {:ets.take(Pool.table(), {:retained, key}), :ets.take(Pool.table(), {:error_context, key})},
        else: {[], []}

    for {_, files} <- retained, state == nil do
      Enum.each(files, &File.rm/1)
      files |> Enum.map(&Path.dirname/1) |> Enum.uniq() |> Enum.each(&File.rmdir/1)
    end

    for {_, info} <- error_context,
        {:failed, failures} <- [state],
        do: step("write error-context.md", fn -> ErrorContext.write(info, failures) end)

    :ok
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
    cwd = File.cwd!()
    file = Path.expand(file)
    test_dir = Path.join(cwd, "test")

    relative =
      if String.starts_with?(file, test_dir <> "/"),
        do: Path.relative_to(file, test_dir),
        else: Path.relative_to(file, cwd)

    relative = relative |> String.replace_suffix("_test.exs", "") |> String.replace_suffix(".exs", "")
    name = trim_long_string(String.replace(relative, "/", "-") <> "-" <> sanitize_for_file_path(name))

    Path.join(root, name <> "-" <> short_hash(:erlang.term_to_binary({module, parameters}, [:deterministic])))
  end

  @doc "Upstream's `sanitizeForFilePath`."
  def sanitize_for_file_path(s), do: Regex.replace(~r/[\x00-\x2C\x2E-\x2F\x3A-\x40\x5B-\x60\x7B-\x7F]+/, s, "-")

  @doc "Upstream's `trimLongString`, at `windowsFilesystemFriendlyLength` (60)."
  def trim_long_string(s, length \\ 60) do
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
