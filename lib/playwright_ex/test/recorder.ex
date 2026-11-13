defmodule PlaywrightEx.Test.Recorder do
  @moduledoc false
  # The artifacts of one registered test (`use PlaywrightEx.Test`), after Playwright Test's
  # `ArtifactsRecorder`, `SnapshotRecorder` and `_contextFactory`
  # (`packages/playwright/src/index.ts`).
  #
  # A process per test that creates a context (`PlaywrightEx.Test.Results.recorder/1`, started on
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
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Isomorphic.ProtocolFormatter
  alias PlaywrightEx.Isomorphic.StringUtils
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.Screencast
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Results
  alias PlaywrightEx.Test.TestInfo
  alias PlaywrightEx.Test.TestTracing
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Video

  require Logger

  @doc "The recorder of the test `test_pid`, if it started one, or `nil`."
  def lookup(test_pid) do
    case Results.started?() && :ets.lookup(Results.table(), {:recorder, test_pid}) do
      [{_, pid}] -> pid
      _ -> nil
    end
  end

  @doc "Whether the recorder `recorder` (or `nil`) closed its test's contexts at the test timeout."
  def timed_out?(nil), do: false
  def timed_out?(recorder), do: match?(%{timed_out: true}, call(recorder, {:fields, [:timed_out]}))

  @doc """
  The registration of the running test (`PlaywrightEx.Test`'s per-test setup) of the calling
  process or a process in its `$callers`, or `nil`.
  """
  def registration do
    Enum.find_value([self() | List.wrap(Process.get(:"$callers"))], &registration/1)
  end

  @doc "The registration of the test `test_pid`, or `nil`."
  def registration(test_pid) do
    case Results.started?() && :ets.lookup(Results.table(), {:test, test_pid}) do
      [{_key, test}] -> test
      _ -> nil
    end
  end

  @doc "`TestTracing`'s `_appendTraceEvent`: adds `event` to the test's trace (`PlaywrightEx.Test.TestTracing`)."
  def append_trace_event(pid, event), do: call(pid, {:append_trace_event, event})

  @doc """
  The listener each driver of `PlaywrightEx.Test.BrowserPool` gets when it starts (upstream's
  `_setupArtifacts` `csiListener`, `ArtifactsRecorder`'s and `_contextFactory`'s parts). Its
  context hooks run in the process that creates or closes a context, for every context of the
  driver: they look up the creator's test (`registration/0`) and record only the test's
  contexts. A process that creates one unregistered is noted
  (`PlaywrightEx.Test.Results.note_unregistered/1`): the test process of a case template's `setup`
  that runs before `use PlaywrightEx.Test`'s fails its registration.
  """
  def listener do
    %{
      onApiCallBegin: &__MODULE__.on_api_call_begin/2,
      onApiCallEnd: &__MODULE__.on_api_call_end/1,
      runBeforeCreateBrowserContext: &__MODULE__.before_create_browser_context/1,
      runAfterCreateBrowserContext: &__MODULE__.after_create_browser_context/1,
      runBeforeCloseBrowserContext: &__MODULE__.before_close_browser_context/1,
      runBeforeCreateRequestContext: &__MODULE__.before_create_request_context/1,
      runAfterCreateRequestContext: &__MODULE__.after_create_request_context/1,
      runBeforeCloseRequestContext: &__MODULE__.before_close_request_context/1
    }
  end

  @doc """
  `onApiCallBegin`: a driver call in a test that traces is a `pw:api` step (`PlaywrightEx.Test.TestInfo`) of
  the step it runs in, or of the open `Tracing.group/3`'s, whose id is its `callId`, so a trace
  shows them as one action. A matcher's driver call (`Frame.expect`, `Page.expectScreenshot`) in
  its expect step gets that step's id. It runs on every call of the driver, in tests or not.
  """
  def on_api_call_begin(data, channel) do
    if test_info = TestInfo.current(), do: on_api_call_begin(test_info, data, channel)
  end

  defp on_api_call_begin(test_info, _data, %{type: "Tracing", method: "tracingGroupEnd"}) do
    # The "tracing.group" step ends together with the "tracing.groupEnd" call.
    %{userData: fn error -> with %{} = step <- pop_tracing_group_step(test_info), do: complete(step, error) end}
  end

  defp on_api_call_begin(test_info, data, channel) do
    zone = Zones.data(:stepZone)

    is_expect_call =
      (channel.type == "Frame" and channel.method == "expect") or
        (channel.type == "Page" and channel.method == "expectScreenshot")

    cond do
      zone && zone.category == "expect" && is_expect_call ->
        %{callId: zone.stepId}

      # deviation: no step without the test's trace, where nothing would see it (no reporters):
      # the formatter and the step cost about a fifth of a fast call.
      not traced?(test_info) ->
        nil

      true ->
        api_step(test_info, data, channel)
    end
  end

  # In the general case, create a step for each api call, use it as a callId.
  defp api_step(test_info, data, channel) do
    params =
      ProtocolFormatter.render_params_for_call(%{type: channel.type, method: channel.method, params: channel.params})

    step =
      TestInfo._add_step(
        test_info,
        %{
          stack: data.frames,
          category: "pw:api",
          title: render_title(channel.type, channel.method, channel.params, data.title),
          subtitle: render_subtitle(channel.type, channel.method, channel.params),
          params: params,
          group: ProtocolFormatter.get_action_group(%{type: channel.type, method: channel.method})
        },
        List.first(tracing_group_steps(test_info))
      )

    if channel.type == "Tracing" and channel.method == "tracingGroup" do
      # The step will end later, when the corresponding "tracing.groupEnd" call finishes.
      push_tracing_group_step(test_info, step)
      %{callId: step.stepId}
    else
      %{callId: step.stepId, userData: fn error -> complete(step, error) end}
    end
  end

  defp traced?(test_info), do: match?(%{trace: [{:mode, mode} | _]} when mode != :off, registration(test_info.test_pid))

  @doc "`onApiCallEnd`: completes the call's step."
  def on_api_call_end(data) do
    if complete_step = data.userData, do: complete_step.(data[:error])
  end

  # `step.complete({ error })`: `error` the call's exception, or `nil`.
  defp complete(step, nil), do: TestInfo.step_complete(step, %{})
  defp complete(step, error), do: TestInfo.step_complete(step, %{error: {:error, error, []}})

  # `tracingGroupSteps`, newest first: a row of the test (`PlaywrightEx.Test.TestInfo`), as a
  # group may start and end in different processes of the test.
  defp tracing_group_steps(test_info) do
    case :ets.lookup(Results.table(), tracing_group_steps_key(test_info)) do
      [{_key, steps}] -> steps
      [] -> []
    end
  end

  defp push_tracing_group_step(test_info, step),
    do: :ets.insert(Results.table(), {tracing_group_steps_key(test_info), [step | tracing_group_steps(test_info)]})

  defp pop_tracing_group_step(test_info) do
    case tracing_group_steps(test_info) do
      [step | steps] ->
        :ets.insert(Results.table(), {tracing_group_steps_key(test_info), steps})
        step

      [] ->
        nil
    end
  end

  defp tracing_group_steps_key(test_info), do: {:test_info, test_info.test_pid, :tracing_group_steps}

  # `renderTitle`.
  defp render_title(type, method, params, title),
    do: ProtocolFormatter.render_title_for_call(%{title: title, type: type, method: method, params: params})

  # `renderSubtitle`.
  defp render_subtitle(type, method, params) do
    subtitle = ProtocolFormatter.render_subtitle_for_call(%{type: type, method: method, params: params})
    if subtitle != nil, do: ProtocolFormatter.truncate_param(subtitle)
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
    # `closing` the process that closes the contexts then; `finisher` the caller of `finish/3`.
    {:ok,
     %{
       timer: arm(test),
       timed_out: false,
       closing: nil,
       finisher: nil,
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
       tracing: TestTracing.new(),
       # `installScreencastTitleUpdater`'s: the contexts with the title overlay, the steps'
       # titles, the overlays by page guid.
       title_contexts: [],
       step_stack: [],
       overlays: %{}
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
        {{page, attachment_path(state.opts.output_dir, failed?, ordinal)}, ordinal + 1}
      end)

    snapshotted = Enum.reduce(pages, state.snapshotted, &MapSet.put(&2, &1.guid))
    {:reply, {paths, state.opts}, %{state | ordinal: ordinal, snapshotted: snapshotted}}
  end

  def handle_call({:add_chunk, path}, _from, state), do: {:reply, :ok, %{state | chunks: state.chunks ++ [path]}}
  def handle_call({:page_snapshot, snapshot}, _from, state), do: {:reply, :ok, %{state | page_snapshot: snapshot}}
  def handle_call(:state, _from, state), do: {:reply, state, state}
  # Those of `fields` alone: the whole state copies the test's trace events.
  def handle_call({:fields, fields}, _from, state), do: {:reply, Map.take(state, fields), state}
  # `TestTracing`'s flags, without its events.
  def handle_call(:tracing_flags, _from, state), do: {:reply, %{state.tracing | trace_events: []}, state}

  def handle_call({:title_context, context}, _from, state),
    do: {:reply, :ok, update_overlay(%{state | title_contexts: state.title_contexts ++ [context]})}

  # `testInfo._onUserStepBegin` and `_onUserStepEnd`.
  def handle_call({:user_step, {:begin, title}}, _from, state),
    do: {:reply, :ok, update_overlay(%{state | step_stack: state.step_stack ++ [title]})}

  def handle_call({:user_step, :end}, _from, state),
    do: {:reply, :ok, update_overlay(%{state | step_stack: Enum.drop(state.step_stack, -1)})}

  def handle_call({:did_finish_test_function_and_after_each_hooks, failed?}, _from, state),
    do:
      {:reply, :ok,
       %{state | tracing: TestTracing.did_finish_test_function_and_after_each_hooks(state.tracing, failed?)}}

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

  # Its `finish/3` was killed (ExUnit's timeout of the `on_exit` callback): it stops.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{finisher: pid} = state)
      when reason not in [:normal, :shutdown],
      do: {:stop, :normal, state}

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
  def terminate(_reason, state) do
    forget_rows(self())
    File.rm_rf(state.opts.tmp)
  end

  @impl true
  def handle_cast(:update_overlay, state), do: {:noreply, update_overlay(state)}

  def handle_cast({:finisher, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | finisher: pid}}
  end

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
                video_options(test)
              ),
            else: options

        Map.merge(test.context_options, options)
    end
  end

  # `videoOptions.recordVideo`.
  defp video_options(test) do
    show_actions = test.video[:show][:actions]

    options = [
      dir: Path.join(test.tmp, "videos"),
      size: test.video[:size],
      fps: test.video[:fps],
      showActions: show_actions
    ]

    for {key, value} <- options, value != nil, into: %{}, do: {key, value}
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
  defp note_unregistered, do: Results.note_unregistered(List.last([self() | List.wrap(Process.get(:"$callers"))]))

  @doc false
  # `runAfterCreateBrowserContext`: `didCreateBrowserContext`, on the test's recorder, started on
  # its first context. A row `{{:context, guid}, recorder}` per recorded context: `before_close`
  # reads it, no call into every test's recorder on each close.
  def after_create_browser_context(context) do
    with %{} = test <- registration(),
         recorder when is_pid(recorder) <- Results.recorder(test.test_pid),
         true <- :ets.insert_new(Results.table(), {{:context, context.guid}, recorder}),
         do: record(context, recorder, test)

    nil
  end

  # `didCreateBrowserContext`: a trace chunk of the context and of its `request`.
  defp record(context, recorder, test) do
    # `_setupContextOptions`'s `playwright._defaultContextTimeout = actionTimeout || 0` (and the
    # navigation's), which `Browser._setupBrowserContext` applies to each context. Per context
    # here: a pooled driver's Playwright outlives the test, and serves any process.
    BrowserContext.set_default_timeout(context, test.timeouts.action_timeout)
    BrowserContext.set_default_navigation_timeout(context, test.timeouts.navigation_timeout)
    call(recorder, {:add_context, context})

    if test.trace[:mode] != :off do
      step("start tracing", fn -> start_tracing(context, BrowserContext.tracing(context), test) end)
      request = BrowserContext.request(context)

      if :ets.insert_new(Results.table(), {{:request, request.guid}, recorder}),
        do: start_request_tracing(request, test)
    end

    if test.video[:mode] != :off, do: step("follow the context's pages", fn -> follow_pages(context, recorder) end)
    if test.video[:show][:test], do: step("show the test's title", fn -> install_title_updater(context, recorder) end)
  end

  # `installScreencastTitleUpdater`, of every context of the test (there are no context
  # fixtures): the recorder serializes the updates (`lastUpdate`).
  defp install_title_updater(context, recorder) do
    BrowserContext.on(context, :page, fn _page -> GenServer.cast(recorder, :update_overlay) end)
    call(recorder, {:title_context, context})
  end

  @doc """
  `testInfo._onUserStepBegin(title)` (`{:begin, title}`) or `_onUserStepEnd()` (`:end`) of the
  test `test_pid`: the title overlay of its videos' `show.test`, if any.
  """
  def on_user_step(test_pid, message) do
    with %{video: video} <- registration(test_pid),
         %{} <- video[:show][:test],
         recorder when is_pid(recorder) <- Results.recorder(test_pid),
         do: call(recorder, {:user_step, message})

    :ok
  end

  # `doUpdateOverlay`: each page's overlay replaced by the test's title and steps.
  defp update_overlay(state) do
    show = state.opts.video[:show][:test]
    level = show[:level] || "step"
    test_title = if level == "file", do: [hd(state.opts.title_path)], else: state.opts.title_path
    parts = if level == "step", do: test_title ++ state.step_stack, else: test_title
    html = create_test_overlay(parts, show[:position] || "top-left", show[:fontSize] || 14)

    pages =
      for context <- state.title_contexts,
          context.guid not in state.closed,
          page <- step("list the pages", fn -> BrowserContext.pages(context) end) || [],
          do: page

    overlays =
      Map.new(pages, fn page ->
        hide_overlay(state.overlays[page.guid])
        {page.guid, step("show the test's title", fn -> Screencast.show_overlay!(Page.screencast(page), html) end)}
      end)

    %{state | overlays: overlays}
  end

  defp hide_overlay(nil), do: nil
  defp hide_overlay(overlay), do: step("hide the test's title", fn -> Disposable.dispose!(overlay) end)

  @overlay_positions %{
    "top-left" => "top: 6px; left: 6px;",
    "top" => "top: 6px; left: 50%; transform: translateX(-50%);",
    "top-right" => "top: 6px; right: 6px;",
    "bottom-left" => "bottom: 6px; left: 6px;",
    "bottom" => "bottom: 6px; left: 50%; transform: translateX(-50%);",
    "bottom-right" => "bottom: 6px; right: 6px;"
  }

  # `createTestOverlay`.
  defp create_test_overlay(parts, position, font_size) do
    pos_style = @overlay_positions[position] || @overlay_positions["top-left"]

    """
    <div style="white-space: nowrap; font-size: #{font_size}px; padding: 3px 6px; background: rgba(0,0,0,0.5); color: white; border-radius: 4px; position: absolute; #{pos_style}">
        #{Enum.map_join(parts, "", &"<div>#{StringUtils.escape_html(&1)}</div>")}
      </div>\
    """
  end

  # `_startTraceChunkOnContextCreation`: `tracing.start({ ...options, title, name })`, an internal
  # call of the context or request context `owner`, as all the recording's tracing calls: no
  # stack, no action of the test.
  defp start_tracing(owner, tracing, opts) do
    ChannelOwner._wrap_api_call(
      owner,
      fn _api_zone ->
        Tracing.start!(
          tracing,
          Keyword.drop(opts.trace, [:mode, :attachments]) ++
            [title: opts.title, name: "playwright_ex-#{System.unique_integer([:positive])}"]
        )
      end,
      %{internal: true}
    )
  end

  @doc false
  # `runAfterCreateRequestContext` (`didCreateRequestContext`): a request context of
  # `APIRequest.new_context/2` in the test, kept to dispose of at its end, and its trace chunk.
  def after_create_request_context(request) do
    with %{} = test <- registration(),
         recorder when is_pid(recorder) <- Results.recorder(test.test_pid),
         true <- :ets.insert_new(Results.table(), {{:request, request.guid}, recorder}) do
      call(recorder, {:add_request, request})

      if test.trace[:mode] != :off, do: start_request_tracing(request, test)
    end

    nil
  end

  @doc false
  # `runBeforeCloseRequestContext` (`willCloseRequestContext`): the trace chunk of a request
  # context, also a browser context's `request` (its close disposes it first).
  def before_close_request_context(request) do
    with [{_key, recorder}] <- :ets.take(Results.table(), {:request, request.guid}),
         %{} = state <- call(recorder, {:fields, [:opts]}) do
      call(recorder, {:request_closed, request.guid})

      if state.opts.trace[:mode] != :off, do: stop_request_tracing(request, recorder, state)
    end

    nil
  end

  defp start_request_tracing(request, test),
    do: step("start tracing", fn -> start_tracing(request, APIRequestContext.tracing(request), test) end)

  defp stop_request_tracing(request, recorder, state),
    do: step("save the trace", fn -> stop_tracing(request, APIRequestContext.tracing(request), recorder, state) end)

  defp follow_pages(context, recorder) do
    BrowserContext.on(context, :page, &GenServer.cast(recorder, {:add_page, context.guid, &1}))
    for page <- BrowserContext.pages(context), do: GenServer.cast(recorder, {:add_page, context.guid, page})
  end

  @doc false
  # `runBeforeCloseBrowserContext` (`willCloseBrowserContext`): the trace chunk, the screenshots
  # (`captureTemporary`), then the page snapshot (`_takePageSnapshot`). Taking the row makes it
  # once per context, also when closes race.
  def before_close_browser_context(context) do
    with [{_key, recorder}] <- :ets.take(Results.table(), {:context, context.guid}),
         %{} = state <- call(recorder, {:fields, [:opts, :timed_out, :test_pid]}) do
      call(recorder, {:closed, context.guid})
      collect(context, recorder, state)
    end

    nil
  end

  defp collect(context, recorder, %{opts: opts} = state) do
    if opts.trace[:mode] != :off,
      do: step("save the trace", fn -> stop_tracing(context, BrowserContext.tracing(context), recorder, state) end)

    if capture_temporary?(opts.screenshot[:mode], opts.retry), do: screenshots(context, recorder, opts)
    step("take a page snapshot", fn -> page_snapshot(context, recorder, state) end)
  end

  # `_takePageSnapshot`: once per test, of the first page, when the test has errors (upstream's
  # `testInfo.errors`: while it runs its soft ones, then its failures) without a matcher's
  # snapshot, or timed out (its close is the timeout's).
  defp page_snapshot(context, recorder, state) do
    with true <- state.timed_out or errors_without_snapshot?(state.test_pid),
         %{page_snapshot: nil} <- call(recorder, {:fields, [:page_snapshot]}),
         [page | _] <- BrowserContext.pages(context),
         # The snapshot may fail: ignored, as upstream's. An internal call of the page.
         {:ok, snapshot} <-
           ChannelOwner._wrap_api_call(page, fn _api_zone -> Page.aria_snapshot(page, mode: :ai, timeout: 5000) end, %{
             internal: true
           }),
         do: call(recorder, {:page_snapshot, snapshot})
  end

  defp errors_without_snapshot?(test_pid) do
    errors =
      if Process.alive?(test_pid) do
        TestInfo.errors(test_pid)
      else
        case Results.result(test_pid, 5000) do
          {:failed, failures} -> failures
          _ -> []
        end
      end

    errors != [] and not Enum.any?(errors, &ErrorContext.error(&1).error_context)
  end

  # `_stopTracing`: the chunk, or none once the test abandons its trace (a passed test's under
  # `retain_on_failure`), which `stopChunk` discards without saving it.
  defp stop_tracing(owner, tracing, recorder, %{opts: opts}) do
    ChannelOwner._wrap_api_call(
      owner,
      fn _api_zone ->
        tracing_flags = GenServer.call(recorder, :tracing_flags, :infinity)

        path =
          TestTracing.maybe_generate_next_trace_recording_path(tracing_flags, opts.trace[:mode], opts.retry, opts.tmp)

        Tracing.stop_chunk!(tracing, path: path)
        if path, do: call(recorder, {:add_chunk, path})
      end,
      %{internal: true}
    )
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

  # `page.screenshot({ ...screenshotOptions, timeout: 5000, path, caret: 'initial' })`, an internal
  # call of the page (`ArtifactsRecorder`'s screenshot recorder).
  defp screenshot(page, path, opts) do
    File.mkdir_p!(Path.dirname(path))

    ChannelOwner._wrap_api_call(
      page,
      fn _api_zone ->
        Page.screenshot!(page, Keyword.delete(opts.screenshot, :mode) ++ [timeout: 5000, path: path, caret: :initial])
      end,
      %{internal: true}
    )
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
  (`PlaywrightEx.Test.Results.result/2`): within `budget` ms (ExUnit's `on_exit` shares the test's
  timeout), closes its contexts still open, then keeps the videos, trace and screenshots as the
  modes and the result say and writes `error-context.md` of a failure. Then, whatever happened,
  stops the recorder: past the budget in the background, after closing the contexts left, and
  by itself when the caller is killed. Returns the path of the trace it kept, or `nil`.
  """
  def finish(pid, result, budget) do
    # Killed past ExUnit's timeout, the caller doesn't stop it: it stops itself.
    GenServer.cast(pid, {:finisher, self()})
    task = Task.async(fn -> step("finish the recording", fn -> collect_all(pid, result) end) end)

    case Task.yield(task, budget) do
      {:ok, trace} ->
        forget_rows(pid)
        step("stop the recorder", fn -> GenServer.stop(pid) end)
        trace

      nil ->
        Task.shutdown(task, :brutal_kill)
        forget_rows(pid)
        log("finish the recording", "it took over #{budget} ms")

        # The recorder may be blocked (that's what took so long): in the background.
        Task.start(fn -> abandon(pid) end)
        nil
    end
  end

  defp abandon(pid) do
    fields = [:contexts, :closed, :requests]
    step("close the contexts left", fn -> close_leftovers(GenServer.call(pid, {:fields, fields}, :infinity)) end)
    step("stop the recorder", fn -> GenServer.stop(pid) end)
  end

  # The contexts' rows: a close from now on has no artifact steps.
  defp forget_rows(pid) do
    :ets.match_delete(Results.table(), {{:context, :_}, pid})
    :ets.match_delete(Results.table(), {{:request, :_}, pid})
  end

  defp collect_all(pid, {verdict, failures}) do
    state = GenServer.call(pid, {:fields, [:closing, :opts, :contexts, :closed, :requests]}, :infinity)
    # The test timeout's closes, with their artifact steps.
    if state.closing, do: await_exit(state.closing)
    # A test of another macro (a doctest) has no result: kept as a failure's.
    failed? = verdict != :passed
    GenServer.call(pid, {:did_finish_test_function_and_after_each_hooks, failed?}, :infinity)

    # `didFinishTest`: the open pages' screenshots, then the leftover contexts. A pooled browser
    # outlives the test.
    if should_capture_upon_finish(state.opts.screenshot[:mode], failed?, state.opts.retry), do: capture(pid, failed?)

    for %{guid: guid, context: context} <- state.contexts,
        guid not in state.closed,
        do: step("close a context", fn -> BrowserContext.close!(context, reason: "Test ended.") end)

    # The leftover request contexts too, as upstream's `request` fixture is disposed.
    for request <- state.requests,
        do: step("dispose a request context", fn -> APIRequestContext.dispose!(request, reason: "Test ended.") end)

    # All of it, the trace events too, once.
    state = GenServer.call(pid, :state, :infinity)
    save_videos(state, failed?)
    trace = save_trace(state, failed?)
    persist_screenshots(state, failed?)

    if verdict == :failed,
      do: step("write error-context.md", fn -> ErrorContext.write(state.opts, failures, state.page_snapshot) end)

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

  @doc """
  The video options of a test of `retry` (its registration's): mode `:off` unless upstream's
  `shouldCaptureVideo` (`captureVideo`, which `preserveVideo` requires too).
  """
  def capture_video([{:mode, mode} | options] = video, retry) do
    capture? =
      mode in [:on, :retain_on_failure, :retain_on_failure_and_retries] or
        (mode == :on_first_retry and retry == 1) or (mode == :on_all_retries and retry > 0) or
        (mode == :retain_on_first_failure and retry == 0)

    if capture?, do: video, else: [{:mode, :off} | options]
  end

  # `shouldPreserveVideo`.
  defp should_preserve_video(mode, _failed?, _retry) when mode in [:on, :on_first_retry, :on_all_retries], do: true

  defp should_preserve_video(mode, failed?, _retry) when mode in [:retain_on_failure, :retain_on_first_failure],
    do: failed?

  defp should_preserve_video(:retain_on_failure_and_retries, failed?, retry), do: failed? or retry > 0
  defp should_preserve_video(_mode, _failed?, _retry), do: false

  # `_contextFactory`'s close (`preserveVideo`): `video.webm`, `video-1.webm`, ... in the
  # order the contexts closed. The artifact options have their `mode` first.
  defp save_videos(%{opts: %{video: [{:mode, video} | _]} = opts} = state, failed?) do
    if should_preserve_video(video, failed?, opts.retry), do: do_save_videos(state)
  end

  defp do_save_videos(state) do
    by_guid = Map.new(state.contexts, &{&1.guid, &1})
    open = for %{guid: guid} <- state.contexts, guid not in state.closed, do: guid
    pages = for guid <- state.closed ++ open, page <- by_guid[guid].pages, do: page
    videos = for page <- pages, video = step("find a video", fn -> Page.video(page) end), video != nil, do: video

    for {video, i} <- Enum.with_index(videos) do
      path = Path.join(state.opts.output_dir, if(i == 0, do: "video.webm", else: "video-#{i}.webm"))
      step("save a video", fn -> save_video(video, path) end)
    end
  end

  defp save_video(video, path) do
    File.mkdir_p!(Path.dirname(path))
    Video.save_as!(video, path)
  end

  # `testTracing`'s `stopIfNeeded`: the test's `test.trace` and its contexts' chunks. The path,
  # when kept.
  defp save_trace(state, failed?),
    do: step("merge the traces", fn -> TestTracing.stop_if_needed(state.tracing, state.opts, state.chunks, failed?) end)

  @doc "`SnapshotRecorder.shouldCaptureUponFinish`, by the screenshot `mode` and the test's result and `retry`."
  def should_capture_upon_finish(mode, failed?, retry),
    do: mode == :on or (mode == :only_on_failure and failed?) or (mode == :on_first_failure and failed? and retry == 0)

  # `SnapshotRecorder.captureTemporary`'s condition.
  defp capture_temporary?(mode, retry),
    do: mode == :on or mode == :only_on_failure or (mode == :on_first_failure and retry == 0)

  # `SnapshotRecorder.persistTemporary`: `test-failed-N.png` of a failed test, else
  # `test-finished-N.png` (`on` only), in capture order, numbered after those taken at the end.
  defp persist_screenshots(state, failed?) do
    for {file, ordinal} <- Enum.with_index(state.screenshots, state.ordinal),
        should_capture_upon_finish(state.opts.screenshot[:mode], failed?, state.opts.retry),
        path = attachment_path(state.opts.output_dir, failed?, ordinal),
        do: step("save a screenshot", fn -> save_screenshot(file, path) end)
  end

  defp save_screenshot(file, path) do
    File.mkdir_p!(Path.dirname(path))
    File.cp!(file, path)
  end

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
