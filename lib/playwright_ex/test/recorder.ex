defmodule PlaywrightEx.Test.Recorder do
  @moduledoc false
  # The artifacts of one registered test (`use PlaywrightEx.Test`), after Playwright Test's
  # `ArtifactsRecorder`, `SnapshotRecorder` and `_contextFactory`
  # (`packages/playwright/src/index.ts`) and `mergeTraceFiles`
  # (`packages/playwright/src/worker/testTracing.ts`).
  #
  # A process per test that creates a context (`PlaywrightEx.Test.Pool.recorder/1`, started on
  # its first one; on its registration when it traces, for the steps of `test.trace`), alive to
  # the end of its `on_exit`: it remembers the test's contexts and anchors them (so their pages
  # and videos stay readable after the process that created or closed them exits). The driver's
  # listener (`listener/0`) runs in the processes that create and close contexts; `finish/3`
  # runs in ExUnit's `on_exit` process, once the test's result is known, and keeps or drops the
  # artifacts by it. Every artifact step rescues and logs: an exception in `on_exit` would fail
  # the test and hide its own error, and upstream's artifact code swallows its errors too.
  #
  # The recorder also owns the test's timeout (upstream's `closeReason` of a `timedOut` test):
  # just before ExUnit kills the test process, it closes the test's open contexts with
  # "Test timeout of <ms>ms exceeded.", so a Playwright call that hangs until then fails with that
  # reason and its call log, after the close's artifact steps ran (`test_timeout_margin/1`).
  use GenServer

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.TestTracing
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Video

  require Logger

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

  @doc "The recorder of the test `test_pid`, if it started one, or `nil`."
  def lookup(test_pid) do
    case Pool.started?() && :ets.lookup(Pool.table(), {:recorder, test_pid}) do
      [{_, pid}] -> pid
      _ -> nil
    end
  end

  @doc "Whether the recorder `recorder` (or `nil`) closed its test's contexts at the test timeout."
  def timed_out?(nil), do: false
  def timed_out?(recorder), do: match?(%{timed_out: true}, call(recorder, :state))

  @doc """
  The registration of the running test (`PlaywrightEx.Test`'s per-test setup) of the calling
  process or a process in its `$callers`, or `nil`.
  """
  def registration do
    Enum.find_value([self() | List.wrap(Process.get(:"$callers"))], &registration/1)
  end

  @doc "The registration of the test `test_pid`, or `nil`."
  def registration(test_pid) do
    case Pool.started?() && :ets.lookup(Pool.table(), {:test, test_pid}) do
      [{_key, test}] -> test
      _ -> nil
    end
  end

  @doc "`TestTracing`'s `_appendTraceEvent`: adds `event` to the test's trace (`PlaywrightEx.Test.TestTracing`)."
  def append_trace_event(pid, event), do: call(pid, {:append_trace_event, event})

  @doc """
  The listener each driver of `PlaywrightEx.Test.BrowserPool` gets when it starts (upstream's
  `_setupArtifacts` `csiListener`, `ArtifactsRecorder`'s and `_contextFactory`'s parts). It runs
  in the process that creates or closes a context, for every context of the driver: it looks up
  the creator's test (`registration/0`) and records only the test's contexts. A process that
  creates one unregistered is noted (`PlaywrightEx.Test.Pool.note_unregistered/1`): the test
  process of a case template's `setup` that runs before `use PlaywrightEx.Test`'s fails its
  registration.
  """
  def listener do
    %{
      runBeforeCreateBrowserContext: &__MODULE__.before_create_browser_context/1,
      runAfterCreateBrowserContext: &__MODULE__.after_create_browser_context/1,
      runBeforeCloseBrowserContext: &__MODULE__.before_close_browser_context/1,
      runBeforeCreateRequestContext: &__MODULE__.before_create_request_context/1,
      runAfterCreateRequestContext: &__MODULE__.after_create_request_context/1,
      runBeforeCloseRequestContext: &__MODULE__.before_close_request_context/1
    }
  end

  @doc """
  How long before the test's ExUnit timeout its contexts are closed: 1 s, at most 5% of the
  timeout. The close's artifact steps (the trace chunk, screenshots, the page snapshot) and the
  failing call's reply must fit in it, or ExUnit's kill comes first.
  """
  def test_timeout_margin(timeout), do: min(1000, div(timeout, 20))

  @impl true
  def init(test) do
    # `contexts` in creation order, `closed` (guids) in close order, `requests` the open request
    # contexts of `APIRequest.new_context/2`, `screenshots` (temporary files) in capture order;
    # `snapshotted` the guids of the pages with a screenshot, `ordinal` the screenshots named so
    # far (upstream's `SnapshotRecorder`). `timer` the test timeout's, `timed_out` once it fired,
    # `closing` the process that closes the contexts then.
    {:ok,
     %{
       timer: arm(test),
       timed_out: false,
       closing: nil,
       test_pid: test.test_pid,
       opts: test,
       contexts: [],
       closed: [],
       requests: [],
       chunks: [],
       screenshots: [],
       snapshotted: MapSet.new(),
       ordinal: 0,
       page_snapshot: nil,
       tracing: TestTracing.new()
     }}
  end

  @impl true
  def handle_call({:add_context, context}, _from, state) do
    # The recorder anchors the context: its videos are saved after its creator may have exited.
    ChannelOwner._set_creator(context)
    {:reply, :ok, %{state | contexts: state.contexts ++ [%{guid: context.guid, context: context, pages: []}]}}
  end

  def handle_call({:closed, guid}, _from, state), do: {:reply, :ok, %{state | closed: state.closed ++ [guid]}}

  def handle_call({:add_request, request}, _from, state),
    do: {:reply, :ok, %{state | requests: state.requests ++ [request]}}

  def handle_call({:request_closed, guid}, _from, state),
    do: {:reply, :ok, %{state | requests: Enum.reject(state.requests, &(&1.guid == guid))}}

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

  def handle_call({:append_trace_event, event}, _from, state),
    do: {:reply, :ok, %{state | tracing: %{state.tracing | trace_events: [event | state.tracing.trace_events]}}}

  @impl true
  def handle_info(:test_timeout, state) do
    reason = "Test timeout of #{state.opts.test_timeout}ms exceeded."
    open = for %{guid: guid, context: context} <- state.contexts, guid not in state.closed, do: context

    # Not in the recorder: the close's hooks call it.
    {:ok, closing} =
      Task.start(fn ->
        open
        |> Task.async_stream(&step("close a context", fn -> BrowserContext.close(&1, reason: reason) end),
          timeout: :infinity
        )
        |> Stream.run()
      end)

    {:noreply, %{state | timer: nil, timed_out: true, closing: closing}}
  end

  # The test process ended before its timeout.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{test_pid: pid} = state) do
    if state.timer && !Process.cancel_timer(state.timer) do
      receive do
        :test_timeout -> :ok
      after
        0 -> :ok
      end
    end

    {:noreply, %{state | timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The test timeout's timer, `nil` without one (`:infinity`, `--trace`).
  defp arm(%{deadline: deadline, test_timeout: timeout, test_pid: test_pid}) when is_integer(deadline) do
    Process.monitor(test_pid)
    Process.send_after(self(), :test_timeout, deadline - test_timeout_margin(timeout), abs: true)
  end

  defp arm(_test), do: nil

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

  @doc false
  # `runBeforeCreateBrowserContext`: `_contextFactory`'s `{ ...videoOptions, ...options }`, then
  # `_combinedContextOptions` for each key not in the options (a key given as `nil` stays).
  def before_create_browser_context(options) do
    case registration() do
      nil ->
        note_unregistered()
        options

      test ->
        options =
          if test.video[:mode] != :off and not Map.has_key?(options, :recordVideo),
            do:
              Map.put(
                options,
                :recordVideo,
                Map.new([dir: Path.join(test.tmp, "videos")] ++ Keyword.take(test.video, [:size]))
              ),
            else: options

        Map.merge(test.context_options, options)
    end
  end

  @doc false
  # `runBeforeCreateRequestContext`: `_combinedContextOptions` for each key not in the options.
  def before_create_request_context(options) do
    case registration() do
      nil ->
        note_unregistered()
        options

      test ->
        # `_defaultContextTimeout` (`actionTimeout || 0`), a default of the request context's own.
        timeout = if test.timeouts.action_timeout == :infinity, do: 0, else: test.timeouts.action_timeout
        Map.merge(Map.put(test.context_options, :timeout, timeout), options)
    end
  end

  # The test process, the root of the `$callers`.
  defp note_unregistered, do: Pool.note_unregistered(List.last([self() | List.wrap(Process.get(:"$callers"))]))

  @doc false
  # `runAfterCreateBrowserContext`: `didCreateBrowserContext`, on the test's recorder, started on
  # its first context. A row `{{:context, guid}, recorder}` per recorded context: `before_close`
  # reads it, no call into every test's recorder on each close.
  def after_create_browser_context(context) do
    with %{} = test <- registration(),
         recorder when is_pid(recorder) <- Pool.recorder(test.test_pid),
         true <- :ets.insert_new(Pool.table(), {{:context, context.guid}, recorder}),
         do: record(context, recorder, test)

    nil
  end

  # `didCreateBrowserContext`: a trace chunk of the context and of its `request`.
  defp record(context, recorder, test) do
    # `_setupContextOptions`'s `playwright._defaultContextTimeout = actionTimeout || 0` (and the
    # navigation's), which `Browser._setupBrowserContext` applies to each context. Per context
    # here: the Playwright of a shared driver serves concurrent tests.
    BrowserContext.set_default_timeout(context, test.timeouts.action_timeout)
    BrowserContext.set_default_navigation_timeout(context, test.timeouts.navigation_timeout)
    call(recorder, {:add_context, context})

    if test.trace[:mode] != :off do
      step("start tracing", fn -> start_tracing(BrowserContext.tracing(context), test) end)
      request = BrowserContext.request(context)

      if :ets.insert_new(Pool.table(), {{:request, request.guid}, recorder}), do: start_request_tracing(request, test)
    end

    if test.video[:mode] != :off, do: step("follow the context's pages", fn -> follow_pages(context, recorder) end)
  end

  # `_startTraceChunkOnContextCreation`: `tracing.start({ ...options, title, name })`.
  defp start_tracing(tracing, opts) do
    Tracing.start!(
      tracing,
      Keyword.delete(opts.trace, :mode) ++
        [title: opts.title, name: "playwright_ex-#{System.unique_integer([:positive])}"]
    )
  end

  @doc false
  # `runAfterCreateRequestContext` (`didCreateRequestContext`): a request context of
  # `APIRequest.new_context/2` in the test, kept to dispose of at its end, and its trace chunk.
  def after_create_request_context(request) do
    with %{} = test <- registration(),
         recorder when is_pid(recorder) <- Pool.recorder(test.test_pid),
         true <- :ets.insert_new(Pool.table(), {{:request, request.guid}, recorder}) do
      call(recorder, {:add_request, request})

      if test.trace[:mode] != :off, do: start_request_tracing(request, test)
    end

    nil
  end

  @doc false
  # `runBeforeCloseRequestContext` (`willCloseRequestContext`): the trace chunk of a request
  # context, also a browser context's `request` (its close disposes it first).
  def before_close_request_context(request) do
    with [{_key, recorder}] <- :ets.take(Pool.table(), {:request, request.guid}),
         %{} = state <- call(recorder, :state) do
      call(recorder, {:request_closed, request.guid})

      if state.opts.trace[:mode] != :off, do: stop_request_tracing(request, recorder, state.opts)
    end

    nil
  end

  defp start_request_tracing(request, test),
    do: step("start tracing", fn -> start_tracing(APIRequestContext.tracing(request), test) end)

  defp stop_request_tracing(request, recorder, opts),
    do: step("save the trace", fn -> stop_tracing(APIRequestContext.tracing(request), recorder, opts) end)

  defp follow_pages(context, recorder) do
    BrowserContext.on(context, :page, &GenServer.cast(recorder, {:add_page, context.guid, &1}))
    for page <- BrowserContext.pages(context), do: GenServer.cast(recorder, {:add_page, context.guid, page})
  end

  @doc false
  # `runBeforeCloseBrowserContext` (`willCloseBrowserContext`): the trace chunk, the screenshots
  # (`captureTemporary`), then the page snapshot (`_takePageSnapshot`). Taking the row makes it
  # once per context, also when closes race.
  def before_close_browser_context(context) do
    with [{_key, recorder}] <- :ets.take(Pool.table(), {:context, context.guid}),
         %{} = state <- call(recorder, :state) do
      call(recorder, {:closed, context.guid})
      collect(context, recorder, state)
    end

    nil
  end

  defp collect(context, recorder, %{opts: opts} = state) do
    if opts.trace[:mode] != :off,
      do: step("save the trace", fn -> stop_tracing(BrowserContext.tracing(context), recorder, opts) end)

    if opts.screenshot[:mode] != :off, do: screenshots(context, recorder, opts)
    step("take a page snapshot", fn -> page_snapshot(context, recorder, state) end)
  end

  # `_takePageSnapshot`: once per test, of the first page, when the test failed (upstream's
  # `testInfo.errors`) without a matcher's snapshot, or timed out (its close is the timeout's). A
  # context closed while the test runs has no errors yet, as upstream's.
  defp page_snapshot(context, recorder, state) do
    with true <- state.timed_out or failed_without_snapshot?(state.test_pid),
         %{page_snapshot: nil} <- call(recorder, :state),
         [page | _] <- BrowserContext.pages(context),
         # The snapshot may fail: ignored, as upstream's.
         {:ok, snapshot} <- Page.aria_snapshot(page, mode: :ai, timeout: 5000),
         do: call(recorder, {:page_snapshot, snapshot})
  end

  defp failed_without_snapshot?(test_pid) do
    with false <- Process.alive?(test_pid),
         {:failed, failures} <- Pool.result(test_pid, 5000) do
      not Enum.any?(failures, &ErrorContext.error(&1).error_context)
    else
      _ -> false
    end
  end

  defp stop_tracing(tracing, recorder, opts) do
    File.mkdir_p!(opts.tmp)
    path = Path.join(opts.tmp, "#{System.unique_integer([:positive])}.zip")
    Tracing.stop_chunk!(tracing, path: path)
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
  The end of the test (in its registration's `on_exit`, so it runs last), with its `result`
  (`PlaywrightEx.Test.Pool.result/2`): within `budget` ms (ExUnit's `on_exit` shares the test's
  timeout), closes its contexts still open, then keeps the videos, trace and screenshots as the
  modes and the result say and writes `error-context.md` of a failure. Then, whatever happened,
  stops the recorder. Returns the path of the trace it kept, or `nil`.
  """
  def finish(pid, result, budget) do
    task = Task.async(fn -> step("finish the recording", fn -> collect_all(pid, result) end) end)

    case Task.yield(task, budget) do
      {:ok, trace} ->
        trace

      nil ->
        Task.shutdown(task, :brutal_kill)
        log("finish the recording", "it took over #{budget} ms")
        step("close the contexts left", fn -> close_leftovers(GenServer.call(pid, :state, :infinity)) end)
        nil
    end
  after
    :ets.match_delete(Pool.table(), {{:context, :_}, pid})
    :ets.match_delete(Pool.table(), {{:request, :_}, pid})
    step("stop the recorder", fn -> GenServer.stop(pid) end)
  end

  defp collect_all(pid, {verdict, failures}) do
    state = GenServer.call(pid, :state, :infinity)
    # The test timeout's closes, with their artifact steps.
    if state.closing, do: await_exit(state.closing)
    # A test of another macro (a doctest) has no result: kept as a failure's.
    failed? = verdict != :passed

    # `didFinishTest`: the open pages' screenshots, then the leftover contexts. A pooled browser
    # outlives the test.
    if capture?(state.opts.screenshot[:mode], failed?), do: capture(pid, failed?)

    for %{guid: guid, context: context} <- state.contexts,
        guid not in state.closed,
        do: step("close a context", fn -> BrowserContext.close!(context, reason: "Test ended.") end)

    # The leftover request contexts too, as upstream's `request` fixture is disposed.
    for request <- state.requests,
        do: step("dispose a request context", fn -> APIRequestContext.dispose!(request, reason: "Test ended.") end)

    state = GenServer.call(pid, :state, :infinity)
    save_videos(state, failed?)
    trace = save_trace(state, failed?)
    persist_screenshots(state, failed?)

    if verdict == :failed do
      info = Map.merge(Map.take(state.opts, [:dir, :title_path, :location]), %{page_snapshot: state.page_snapshot})
      step("write error-context.md", fn -> ErrorContext.write(info, failures) end)
    end

    trace
  end

  defp await_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  # Past the budget: the contexts still open are closed in the background, so they don't pile up
  # in a pooled browser. The task anchors them before the recorder stops.
  defp close_leftovers(state) do
    leftovers =
      for(%{guid: guid, context: context} <- state.contexts, guid not in state.closed, do: context) ++ state.requests

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

  defp close_leftover(%PlaywrightEx.APIRequestContext{} = request),
    do: step("dispose a request context", fn -> APIRequestContext.dispose(request, reason: "Test ended.") end)

  defp close_leftover(context),
    do: step("close a context", fn -> BrowserContext.close(context, reason: "Test ended.") end)

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

  # `testTracing`'s `stopIfNeeded`: the test's `test.trace` and its contexts' chunks. The path,
  # when kept.
  defp save_trace(state, failed?) do
    path = Path.join(state.opts.dir, "trace.zip")

    result =
      step("merge the traces", fn ->
        TestTracing.stop_if_needed(
          state.tracing,
          state.opts,
          state.chunks,
          failed?,
          state.opts[:test_timeout],
          state.opts.tmp,
          path
        )
      end)

    if result == :saved, do: path
  end

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

  @doc "A test file relative to `test_dir/0`, else to the working directory: the output dir's name."
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
