defmodule PlaywrightEx.Test.ArtifactsTest do
  # The recording of a registered test, on fake tests: a process of its own registered as
  # `use PlaywrightEx.Test`'s setup does (`__register__/1`), whose contexts are made in processes
  # with it in `$callers`, and whose end (`__finish__/2`, its `on_exit`) runs here.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.VideoPlayer

  import PlaywrightEx.Runtime.Heap, only: [get: 2, put: 3]

  require PlaywrightEx.Test

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  defp trace(dir, handle), do: PlaywrightEx.Utils.parse_trace_raw(Path.join(dir, "trace.zip"), handle)

  defp traced?(trace, text), do: Enum.any?(trace.events, &(JSON.encode!(&1) =~ text))

  defp page(context, marker) do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<h1>#{marker}</h1>")
    page
  end

  # A registered test with `tags` (the modes), in a process of its own, which ends when sent
  # `{:end, messages, reason}`: `messages` of its pid (`&{:passed, &1}`), then exit `reason`.
  # Its `run.(fun)` runs `fun` in a process with it in `$callers`.
  defp fake_test(tags, marked? \\ true) do
    parent = self()
    name = "t#{System.unique_integer([:positive])}"

    pid =
      spawn(fn ->
        context =
          Map.merge(tags, %{
            test_pid: self(),
            module: __MODULE__,
            test: :"test #{name}",
            file: __ENV__.file,
            line: 1,
            playwright_ex: if(marked?, do: :marked)
          })

        send(parent, {:registered, PlaywrightEx.Test.__register__(context)})

        receive do
          {:end, messages, reason} ->
            for message <- messages, do: Pool.notify(message.(self()))
            exit(reason)
        end
      end)

    assert_receive {:registered, test}
    on_exit(fn -> File.rm_rf!(test.dir) end)

    run = fn fun ->
      Task.await(
        Task.async(fn ->
          Process.put(:"$callers", [pid])
          fun.()
        end),
        30_000
      )
    end

    %{pid: pid, dir: test.dir, tmp: test.tmp, run: run}
  end

  # Ends the fake test, then runs its `on_exit`: what it printed.
  defp finish(test, messages, reason, budget \\ 10_000) do
    ref = Process.monitor(test.pid)
    send(test.pid, {:end, messages, reason})
    assert_receive {:DOWN, ^ref, :process, _, _}
    capture_io(fn -> PlaywrightEx.Test.__finish__(test.pid, budget) end)
  end

  defp passed, do: &{:passed, &1}
  defp failed, do: &{:failed, &1, {:error, %RuntimeError{message: "on purpose"}, []}}

  @tag :tmp_dir
  test "records every context of the test, and no other", %{browser: browser, tmp_dir: own_videos} do
    test = fake_test(%{trace: :on, screenshot: :on, video: :on})
    test_pid = self()

    # Another test's context: a process that is not the test's.
    spawn(fn ->
      context = Browser.new_context!(browser)
      page(context, "OTHER")
      send(test_pid, {:other, context})
    end)

    test.run.(fn ->
      alice = Browser.new_context!(browser)
      bob = Browser.new_context!(browser, record_video: %{dir: own_videos})
      page(alice, "ALICE")
      page(bob, "BOB")

      Task.async(fn ->
        context = Browser.new_context!(browser)
        page(context, "TASK")
        BrowserContext.close!(context)
        context = Browser.new_context!(browser)
        page(context, "TASK-NEW")
        BrowserContext.close!(context)
      end)
      |> Task.await()
    end)

    assert_receive {:other, other}
    BrowserContext.close!(other)
    finish(test, [passed()], :shutdown)

    files = File.ls!(test.dir)
    assert Enum.sort(Enum.filter(files, &(&1 =~ ~r/\.webm$/))) == ~w(video-1.webm video-2.webm video-3.webm video.webm)
    # The pages of the contexts closed in the body (taken at their close; no body end here).
    assert Enum.sort(Enum.filter(files, &(&1 =~ ~r/\.png$/))) == for(n <- 1..4, do: "test-finished-#{n}.png")
    assert [_] = File.ls!(own_videos)

    trace = trace(test.dir, browser)
    # A chunk per context and one per context's `request`.
    assert trace.resources |> Map.keys() |> Enum.count(&(&1 =~ ~r/^\d-trace\.trace$/)) == 8

    for marker <- ~w(ALICE BOB TASK TASK-NEW), do: assert(traced?(trace, marker), "#{marker} not in the trace")
    refute traced?(trace, "OTHER")
  end

  test "a context of another worker's browser is recorded", %{browser: browser} do
    test = fake_test(%{trace: :on})
    other = BrowserPool.browser(launch_options: [slow_mo: 1])
    assert BrowserPool.playwright(other) != BrowserPool.playwright(browser)

    test.run.(fn ->
      page(Browser.new_context!(browser), "OWN")
      page(Browser.new_context!(other), "OTHER-BROWSER")
    end)

    finish(test, [passed()], :shutdown)
    trace = trace(test.dir, browser)
    assert traced?(trace, "OWN") and traced?(trace, "OTHER-BROWSER")
  end

  test "a context closed early keeps its artifacts; the ones left are closed at the end", %{browser: browser} do
    test = fake_test(%{trace: :on})

    {early, left} =
      test.run.(fn ->
        early = Browser.new_context!(browser)
        page(early, "EARLY")
        left = Browser.new_context!(browser)
        page(left, "LEFT")
        {early, left}
      end)

    BrowserContext.close!(early)
    test_pid = self()
    BrowserContext.on(left, :close, fn _ -> send(test_pid, :closed) end)
    finish(test, [passed()], :shutdown)
    assert_received :closed
    trace = trace(test.dir, browser)
    assert traced?(trace, "EARLY") and traced?(trace, "LEFT")
  end

  test "a failing artifact step is logged and the test's result stands", %{browser: browser} do
    test = fake_test(%{trace: :on})

    log =
      capture_log(fn ->
        test.run.(fn ->
          context = Browser.new_context!(browser)
          page(context, "STOPPED")
          # The test stops the trace the recorder started: its `stop_chunk` fails.
          Tracing.stop!(BrowserContext.tracing(context))
          assert BrowserContext.close(context) == :ok
        end)
      end)

    assert log =~ "PlaywrightEx.Test could not save the trace"
    finish(test, [passed()], :shutdown)
  end

  test "finish is bounded: past its budget it logs, closes the contexts left and stops the recorder", %{
    browser: browser
  } do
    test = fake_test(%{trace: :on})
    context = test.run.(fn -> Browser.new_context!(browser) end)
    test_pid = self()
    BrowserContext.on(context, :close, fn _ -> send(test_pid, :closed) end)
    recorder = Recorder.lookup(test.pid)
    tmp = :sys.get_state(recorder).opts.tmp

    # Its artifact work blocks on the suspended recorder past the 50 ms budget.
    :sys.suspend(recorder)
    spawn(fn -> Process.sleep(500) && :sys.resume(recorder) end)

    log = capture_log(fn -> finish(test, [passed()], :shutdown, 50) end)
    assert log =~ "PlaywrightEx.Test could not finish the recording: it took over 50 ms"
    refute Process.alive?(recorder)
    assert Recorder.lookup(test.pid) == nil
    refute File.exists?(tmp)
    assert_receive :closed, 10_000
  end

  @tag screenshot: :on
  test "the end of the body with a recorder gone leaves the test's result as is" do
    :ets.insert(Pool.table(), {{:recorder, self()}, spawn(fn -> :ok end)})
    assert PlaywrightEx.Test.__passed__() == :ok
    :ets.delete(Pool.table(), {:recorder, self()})
  end

  # `didFinishTestFunction`: the open pages at the end of the body, before `on_exit` closes them;
  # then (`persistTemporary`) those of the contexts closed in the body.
  test "screenshots at the end of the body, then of the contexts closed in it", %{browser: browser} do
    test = fake_test(%{screenshot: :on})

    test.run.(fn ->
      closed = Browser.new_context!(browser)
      page(closed, "CLOSED")
      BrowserContext.close!(closed)
      page(Browser.new_context!(browser), "OPEN")
    end)

    Recorder.capture(Recorder.lookup(test.pid), false)
    finish(test, [passed()], :shutdown)
    assert Enum.sort(File.ls!(test.dir)) == ["test-finished-1.png", "test-finished-2.png"]
  end

  @tag :tmp_dir
  test "a trace keeps only its own stacks and sources while another test traces on the driver",
       %{browser: browser, tmp_dir: tmp} do
    test = fake_test(%{trace: :on})
    # The other test's calls come from a file of their own.
    other_file = Path.join(tmp, "other_calls.ex")

    File.write!(
      other_file,
      "defmodule #{inspect(__MODULE__)}.OtherCalls, do: def(visit(page), do: PlaywrightEx.Page.set_content!(page, \"x\"))"
    )

    [{other, _}] = Code.compile_file(other_file)
    source = &"src/#{:crypto.hash(:sha, &1) |> Base.encode16(case: :lower)}#{Path.extname(&1)}"
    page = test.run.(fn -> page(Browser.new_context!(browser), "OWN") end)
    test_pid = self()

    # Another test (a process that is not this test's) traces with sources meanwhile.
    spawn(fn ->
      context = Browser.new_context!(browser)
      tracing = BrowserContext.tracing(context)
      Tracing.start!(tracing, sources: true)
      other.visit(BrowserContext.new_page!(context))
      Tracing.stop!(tracing)
      BrowserContext.close!(context)
      send(test_pid, :other_done)
    end)

    assert_receive :other_done, 10_000
    test.run.(fn -> Page.set_content!(page, "<h1>AFTER</h1>") end)
    finish(test, [passed()], :shutdown)

    {:ok, files} = :zip.unzip(String.to_charlist(Path.join(test.dir, "trace.zip")), [:memory])
    files = Map.new(files, fn {name, data} -> {to_string(name), data} end)
    # The context's chunk is the second of three: its `request`'s is first (disposed as the
    # context closes), `test.trace`'s last.
    %{"files" => paths, "stacks" => stacks} = JSON.decode!(files["1-trace.stacks"])
    call_ids = for %{"type" => "before", "callId" => id} <- trace(test.dir, browser).events, do: id

    # Every stack is one of the trace's actions', every frame's file is in `files`.
    assert stacks != []
    for [id, frames] <- stacks, do: assert(id in call_ids and Enum.all?(frames, &(hd(&1) < length(paths))))
    assert Enum.uniq(paths) == paths
    assert __ENV__.file in paths
    refute other_file in paths

    sources = for "src/" <> _ = name <- Map.keys(files), do: name
    assert source.(__ENV__.file) in sources
    assert sources -- Enum.map(paths, source) == []
  end

  test "the trace's options go to Tracing.start", %{browser: browser} do
    test = fake_test(%{trace: [mode: :on, snapshots: false, screenshots: false, sources: false]})
    test.run.(fn -> page(Browser.new_context!(browser), "UNSNAPSHOTTED") end)
    finish(test, [passed()], :shutdown)

    trace = trace(test.dir, browser)
    assert traced?(trace, "UNSNAPSHOTTED")
    refute Enum.any?(trace.events, &(&1["type"] in ["frame-snapshot", "screencast-frame"]))
    refute Enum.any?(Map.keys(trace.resources), &String.starts_with?(&1, "src/"))
  end

  test "the screenshot's options go to Page.screenshot", %{browser: browser} do
    test = fake_test(%{screenshot: [mode: :on, full_page: true]})

    test.run.(fn ->
      Page.set_content!(
        BrowserContext.new_page!(Browser.new_context!(browser)),
        ~s(<div style="height: 2000px">TALL</div>)
      )
    end)

    finish(test, [passed()], :shutdown)
    # The PNG's IHDR: the full page, past the 720 px viewport.
    <<_::binary-size(16), _width::32, height::32, _::binary>> = File.read!(Path.join(test.dir, "test-finished-1.png"))
    assert height > 2000
  end

  @tag skip: VideoPlayer.skip_reason()
  test "the video's size goes to record_video", %{browser: browser} do
    test = fake_test(%{video: [mode: :on, size: %{width: 320, height: 240}]})
    test.run.(fn -> page(Browser.new_context!(browser), "SMALL") end)
    finish(test, [passed()], :shutdown)
    player = VideoPlayer.new(Path.join(test.dir, "video.webm"))
    assert {player.videoWidth, player.videoHeight} == {320, 240}
  end

  test "the video's fps and show.actions go to record_video" do
    show = %{actions: %{position: "top-left"}, test: %{level: "title"}}
    test = fake_test(%{video: [mode: :on, fps: 5, show: show]})

    assert %{recordVideo: %{fps: 5, showActions: %{position: "top-left"}, dir: _}} =
             test.run.(fn -> Recorder.before_create_browser_context(%{}) end)

    finish(test, [passed()], :shutdown)
  end

  # The overlay's shadow root is closed outside upstream's test mode: its calls are in the trace.
  test "the video's show.test: the test's title and its steps over each page", %{browser: browser} do
    test = fake_test(%{trace: :on, video: [mode: :on, show: %{test: %{position: "bottom"}}]})

    test.run.(fn ->
      page = page(Browser.new_context!(browser), "TITLED")

      PlaywrightEx.Test.step "outer <step>" do
        BrowserContext.new_page!(Page.context(page))
        PlaywrightEx.Test.step("inner", fn -> :ok end)
      end
    end)

    finish(test, [passed()], :shutdown)

    htmls =
      for %{"method" => "screencastShowOverlay", "params" => %{"html" => html}} <- trace(test.dir, browser).events,
          do: html

    assert hd(htmls) =~ "bottom: 6px; left: 50%"
    overlays = for html <- htmls, do: html |> String.split(~r/<[^>]+>|\s+/, trim: true) |> Enum.join("|")

    assert [title | _] = overlays
    assert title =~ ~r/^test\/playwright_ex\/test\/artifacts_test\.exs\|t\d+$/
    # Each step's begin and end, on each page (the second opens in the step).
    assert overlays |> Enum.map(&String.replace_prefix(&1, title, "")) |> Enum.dedup() ==
             ["", "|outer|&lt;step>", "|outer|&lt;step>|inner", "|outer|&lt;step>", ""]
  end

  test "a failed test keeps its screenshots and gets error-context.md, with a snapshot of a page closed after it failed, and the trace hint",
       %{browser: browser} do
    test = fake_test(%{screenshot: :only_on_failure, trace: :retain_on_failure})

    [running, first, second] =
      test.run.(fn ->
        for marker <- ~w(RUNNING FIRST SECOND), do: tap(Browser.new_context!(browser), &page(&1, marker))
      end)

    # Closed while the test runs: no errors yet, as upstream.
    BrowserContext.close!(running)
    ref = Process.monitor(test.pid)
    send(test.pid, {:end, [failed()], :shutdown})
    assert_receive {:DOWN, ^ref, :process, _, _}
    BrowserContext.close!(first)
    BrowserContext.close!(second)
    output = capture_io(fn -> PlaywrightEx.Test.__finish__(test.pid, 10_000) end)

    assert Enum.sort(File.ls!(test.dir)) ==
             ~w(error-context.md test-failed-1.png test-failed-2.png test-failed-3.png trace.zip)

    error_context = File.read!(Path.join(test.dir, "error-context.md"))
    assert error_context =~ "```\nRuntimeError: on purpose\n```"
    assert error_context =~ ~s(heading "FIRST")
    refute error_context =~ "RUNNING" or error_context =~ "SECOND"
    assert output =~ "mix playwright_ex.cli show-trace #{Path.relative_to_cwd(Path.join(test.dir, "trace.zip"))}"
    assert length(String.split(output, "show-trace")) == 2
  end

  test "a failed test without a context gets error-context.md, with no recorder" do
    test = fake_test(%{})
    assert Recorder.lookup(test.pid) == nil
    assert finish(test, [failed()], :shutdown) == ""
    assert File.ls!(test.dir) == ["error-context.md"]
    assert File.read!(Path.join(test.dir, "error-context.md")) =~ "```\nRuntimeError: on purpose\n```"
  end

  test "a passed test keeps nothing of the on_failure modes", %{browser: browser} do
    test = fake_test(%{trace: :retain_on_failure, screenshot: :only_on_failure, video: :retain_on_failure})
    test.run.(fn -> page(Browser.new_context!(browser), "PASSED") end)
    assert finish(test, [passed()], :shutdown) == ""
    refute File.exists?(test.dir)
  end

  # Upstream's `maybeGenerateNextTraceRecordingPath`: once the test ended and passed, a context's
  # chunk under `retain_on_failure` is discarded by the driver, not zipped and deleted.
  test "a passed test's chunks under retain_on_failure are discarded, not zipped, once it ended", %{browser: browser} do
    test = fake_test(%{trace: :retain_on_failure})
    zips = record_zips(browser, test.tmp)
    early = test.run.(fn -> Browser.new_context!(browser) end)
    test.run.(fn -> page(Browser.new_context!(browser), "LATE") end)
    # Closed while the test runs: zipped, as upstream (its result is not known yet).
    test.run.(fn -> BrowserContext.close!(early) end)
    assert length(zips.()) == 2
    # The one left, closed at the end: discarded.
    finish(test, [passed()], :shutdown)
    assert length(zips.()) == 2
    refute File.exists?(test.dir)
  end

  test "a failed test's chunks under retain_on_failure are zipped and kept", %{browser: browser} do
    test = fake_test(%{trace: :retain_on_failure})
    zips = record_zips(browser, test.tmp)
    test.run.(fn -> page(Browser.new_context!(browser), "FAILED") end)
    finish(test, [failed()], :shutdown)
    # The context's chunk and its `request`'s.
    assert length(zips.()) == 2
    assert traced?(trace(test.dir, browser), "FAILED")
  end

  # Upstream's `_startTraceChunkOnContextCreation` and `_stopTracing` run as internal calls: no
  # stacks sent, no actions in the trace.
  test "the recording's tracing calls are internal", %{browser: browser} do
    test = fake_test(%{trace: :on})
    methods = ~w(tracingStart tracingStartChunk tracingStopChunk addStackToTracingNoReply)
    sent = record_sent(browser, &(to_string(&1.method) in methods))
    context = test.run.(fn -> Browser.new_context!(browser) end)
    guids = [BrowserContext.tracing(context).guid, APIRequestContext.tracing(BrowserContext.request(context)).guid]
    finish(test, [passed()], :shutdown)

    {tracing, stacks} = Enum.split_with(sent.(), &(&1.guid in guids))
    # `start` (tracingStart, tracingStartChunk) and `stopChunk` of the context and its `request`.
    assert length(tracing) == 6
    assert Enum.all?(tracing, & &1.metadata.internal)
    ids = Enum.map(tracing, & &1.id)
    refute Enum.any?(stacks, &(&1.params.callData.id in ids))
  end

  # Upstream's screenshot recorder and `_takePageSnapshot` run as internal calls too.
  test "the end-of-body screenshot is internal: no stack, no action in the trace", %{browser: browser} do
    test = fake_test(%{trace: :on, screenshot: :on})
    sent = record_sent(browser, &(to_string(&1.method) in ~w(screenshot addStackToTracingNoReply)))
    page = test.run.(fn -> page(Browser.new_context!(browser), "SHOT") end)
    finish(test, [passed()], :shutdown)

    assert [screenshot] = Enum.filter(sent.(), &(&1.guid == page.guid))
    assert screenshot.metadata.internal

    refute Enum.any?(
             sent.(),
             &(to_string(&1.method) == "addStackToTracingNoReply" and &1.params.callData.id == screenshot.id)
           )

    assert File.exists?(Path.join(test.dir, "test-finished-1.png"))
    refute Enum.any?(trace(test.dir, browser).events, &(&1["type"] == "before" and &1["method"] == "screenshot"))
  end

  # The `localUtils.zip` calls of chunks under `tmp` (the test's), on the shared connection.
  defp record_zips(browser, tmp),
    do: record_sent(browser, &(to_string(&1.method) == "zip" and String.starts_with?(&1.params.zipFile, tmp)))

  # The messages `filter` keeps, sent on the shared connection while the test runs.
  defp record_sent(browser, filter) do
    connection = get(BrowserPool.playwright(browser), :_connection)
    onmessage = get(connection, :onmessage)
    {:ok, sent} = Agent.start_link(fn -> [] end)

    put(connection, :onmessage, fn message ->
      if filter.(message), do: Agent.update(sent, &[message | &1])
      onmessage.(message)
    end)

    on_exit(fn -> put(connection, :onmessage, onmessage) end)
    fn -> Agent.get(sent, &Enum.reverse/1) end
  end

  test "a test of another macro (a doctest) keeps them, as a failure's, without error-context.md", %{browser: browser} do
    test = fake_test(%{trace: :retain_on_failure, screenshot: :only_on_failure, video: :retain_on_failure}, false)
    test.run.(fn -> page(Browser.new_context!(browser), "UNKNOWN") end)
    finish(test, [], :shutdown)
    assert Enum.sort(File.ls!(test.dir)) == ~w(test-failed-1.png trace.zip video.webm)
  end

  @tag :tmp_dir
  test "error-context.md has the errors, the source, and the page snapshot unless a matcher has one", %{tmp_dir: dir} do
    info = %{
      dir: dir,
      title_path: ["x_test.exs", "t"],
      location: {__ENV__.file, 1},
      page_snapshot: ~s(- heading "PAGE")
    }

    stack = [{__MODULE__, :t, 1, file: __ENV__.file, line: __ENV__.line}]
    failure = {:error, %ExUnit.AssertionError{message: "on purpose"}, stack}

    read = fn -> File.read!(Path.join(dir, "error-context.md")) end

    ErrorContext.write(info, [failure])

    assert read.() =~
             "# Test info\n\n- Name: x_test.exs >> t\n- Location: test/playwright_ex/test/artifacts_test.exs:1\n"

    assert read.() =~ "```\nExUnit.AssertionError: on purpose\n```"
    assert read.() =~ ~s(# Page snapshot\n\n```yaml\n- heading "PAGE"\n```)
    assert read.() =~ ~r/^> \d+ \| +stack = .*\n +\| +\^ ExUnit.AssertionError: on purpose$/m

    matcher = %PlaywrightEx.ExpectError{message: "Expected", matcherResult: %{ariaSnapshot: ~s(- heading "OWN")}}
    ErrorContext.write(info, [{:error, matcher, []}])
    assert read.() =~ ~s(```\nPlaywrightEx.ExpectError: Expected\n```\n\n```yaml\n- heading "OWN"\n```)
    refute read.() =~ "# Page snapshot"
  end

  test "a test's dir is not emptied: a rerun keeps the first run's other files", %{browser: browser} do
    test = fake_test(%{trace: :on})
    File.mkdir_p!(test.dir)
    File.write!(Path.join(test.dir, "test-failed-2.png"), "first run")
    test.run.(fn -> page(Browser.new_context!(browser), "RERUN") end)
    finish(test, [passed()], :shutdown)
    assert Enum.sort(File.ls!(test.dir)) == ["test-failed-2.png", "trace.zip"]
  end
end

defmodule PlaywrightEx.Test.ArtifactsTest.TagsTest do
  # The modes from tags, over the config: a test's `@tag` over its `@describetag` over the
  # module's `@moduletag`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Test.Recorder

  @moduletag video: true, screenshot: [mode: :only_on_failure, full_page: true]

  defp modes, do: Map.take(Recorder.registration(self()), [:trace, :screenshot, :video])

  test "the module's tags, true as :on; the config for the rest" do
    assert modes() == %{
             trace: [mode: :off, snapshots: true, screenshots: true, sources: true, attachments: true],
             screenshot: [mode: :only_on_failure, full_page: true],
             video: [mode: :on]
           }
  end

  describe "a describe block" do
    @describetag video: false, trace: :on

    # Kept on failure only, so the passing test leaves no files.
    @tag trace: :retain_on_failure
    test "the test's over the describe's over the module's" do
      assert %{trace: [mode: :retain_on_failure] ++ _, video: [mode: :off], screenshot: [mode: :only_on_failure] ++ _} =
               modes()
    end
  end

  test "an invalid tag raises at registration, with the accepted values" do
    for {key, value} <- [trace: :on_first_retry, screenshot: :retain_on_failure, video: "on"] do
      message = assert_raise(ArgumentError, fn -> PlaywrightEx.Test.Options.artifacts(%{key => value}) end).message
      assert message =~ "invalid #{key}: #{inspect(value)}, expected one of"
      assert message =~ "true, false"
    end
  end
end
