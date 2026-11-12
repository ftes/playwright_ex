defmodule PlaywrightEx.Test.ArtifactsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.VideoPlayer

  setup_all :browser

  defp dir(ctx), do: Recorder.output_dir(ctx)

  defp trace(dir, handle), do: PlaywrightEx.Utils.parse_trace_raw(Path.join(dir, "trace.zip"), handle)

  defp traced?(trace, text), do: Enum.any?(trace.events, &(JSON.encode!(&1) =~ text))

  defp page(context, marker) do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<h1>#{marker}</h1>")
    page
  end

  # A recorder of a test process of its own (watched as the `test` macro's), which ends when sent
  # `{:end, messages, reason}`: `messages` of its pid (`&{:passed, &1}`), then exit `reason`.
  defp fake_test(ctx, modes, marked \\ Pool.outside()) do
    token = Pool.start_module()
    on_exit(fn -> Pool.module_finished(token) end)

    pid =
      spawn(fn ->
        receive do
          {:end, messages, reason} ->
            for message <- messages, do: Pool.notify(message.(self()))
            exit(reason)
        end
      end)

    Pool.watch(pid, token, marked)
    dir = Path.join(System.tmp_dir!(), "playwright_ex-artifacts-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    recorder =
      Recorder.start(
        pid,
        Options.artifacts(Map.to_list(modes))
        |> Map.merge(%{dir: dir, title: "t", title_path: ["x_test.exs", "t"], location: {__ENV__.file, 1}})
      )

    Recorder.ensure_listener(recorder, Heap.get(ctx.browser, :_instrumentation))

    %{
      pid: pid,
      recorder: recorder,
      dir: dir,
      context: fn -> Recorder.with_identity(pid, fn -> Browser.new_context!(ctx.browser) end) end
    }
  end

  defp end_test(%{pid: pid}, messages, reason) do
    ref = Process.monitor(pid)
    send(pid, {:end, messages, reason})
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  @tag :tmp_dir
  test "records every context of the test, and no other", %{browser: browser, tmp_dir: own_videos} = ctx do
    dir = dir(ctx)
    test_pid = self()

    # Registered first: runs after the recording's `on_exit`.
    on_exit(fn ->
      files = File.ls!(dir)

      assert Enum.sort(Enum.filter(files, &(&1 =~ ~r/\.webm$/))) ==
               ~w(video-1.webm video-2.webm video-3.webm video.webm)

      assert Enum.sort(Enum.filter(files, &(&1 =~ ~r/\.png$/))) == for(n <- 1..4, do: "test-finished-#{n}.png")
      assert [_] = File.ls!(own_videos)

      trace = trace(dir, browser)
      assert trace.resources |> Map.keys() |> Enum.count(&(&1 =~ ~r/^\d-trace\.trace$/)) == 4

      for marker <- ~w(ALICE BOB PLAIN TASK), do: assert(traced?(trace, marker), "#{marker} not in the trace")
      refute traced?(trace, "OTHER")
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, trace: :on, screenshot: :on, video: :on)

    # Another module's context: a process that is not the test's.
    spawn(fn ->
      context = Browser.new_context!(browser)
      page(context, "OTHER")
      send(test_pid, {:other, context})
    end)

    %{context: alice} = new_context(ctx)
    %{context: bob} = new_context(ctx, context_options: [record_video: %{dir: own_videos}])
    plain = Browser.new_context!(browser)
    page(alice, "ALICE")
    page(bob, "BOB")
    page(plain, "PLAIN")

    Task.async(fn ->
      context = Browser.new_context!(browser)
      page(context, "TASK")
      BrowserContext.close!(context)
    end)
    |> Task.await()

    assert_receive {:other, other}
    BrowserContext.close!(other)
  end

  test "a context a GenServer creates for the test is recorded", ctx do
    dir = dir(ctx)

    on_exit(fn ->
      assert traced?(trace(dir, ctx.browser), "SERVER")
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, trace: :on)
    {:ok, server} = GenServer.start_link(PlaywrightEx.Test.ArtifactsTest.Server, ctx)
    assert GenServer.call(server, :visit) == :ok
  end

  test "a failing artifact step is logged and the test's result stands", ctx do
    on_exit(fn -> File.rm_rf!(dir(ctx)) end)
    record_artifacts(ctx, trace: :on)
    %{context: context} = new_context(ctx)
    page(context, "STOPPED")
    # The test stops the trace the recorder started: its `stop_chunk` fails.
    Tracing.stop!(BrowserContext.tracing(context))
    log = capture_log(fn -> assert BrowserContext.close(context) == :ok end)
    assert log =~ "PlaywrightEx.Test could not save the trace"
  end

  test "finish is bounded: past its budget it logs, closes the contexts left and stops the recorder", ctx do
    opts = Map.merge(Options.artifacts(trace: :on), %{dir: dir(ctx), title: "bounded"})
    recorder = Recorder.start(self(), opts)
    Recorder.ensure_listener(recorder, PlaywrightEx.Runtime.Heap.get(ctx.browser, :_instrumentation))
    context = Browser.new_context!(ctx.browser)
    test_pid = self()
    BrowserContext.on(context, :close, fn _ -> send(test_pid, :closed) end)
    tmp = :sys.get_state(recorder).opts.tmp

    # Its artifact work blocks on the suspended recorder past the 50 ms budget.
    :sys.suspend(recorder)
    spawn(fn -> Process.sleep(500) && :sys.resume(recorder) end)

    log = capture_log(fn -> assert Recorder.finish(recorder, 50) == :ok end)
    assert log =~ "PlaywrightEx.Test could not finish the recording: it took over 50 ms"
    refute Process.alive?(recorder)
    assert Recorder.lookup(self()) == nil
    refute File.exists?(tmp)
    assert_receive :closed, 10_000
  end

  test "the end of the body with a recorder gone leaves the test's result as is" do
    Process.put({PlaywrightEx.Test, :recording}, {spawn(fn -> :ok end), :on})
    assert PlaywrightEx.Test.__passed__() == :ok
    Process.delete({PlaywrightEx.Test, :recording})
  end

  test "finish logs nothing for a listener whose driver closed", ctx do
    name = :"#{inspect(__MODULE__)}.closed"
    start_supervised!({PlaywrightEx.Supervisor, name: name})
    instrumentation = PlaywrightEx.Runtime.Heap.get(PlaywrightEx.playwright(name), :_instrumentation)

    # A test that ended unwatched: no result to wait for.
    test_pid = spawn(fn -> :ok end)
    recorder = Recorder.start(test_pid, Map.merge(Options.artifacts(trace: :on), %{dir: dir(ctx), title: "closed"}))
    Recorder.ensure_listener(recorder, instrumentation)
    stop_supervised!(name)

    # Other tests log meanwhile.
    refute capture_log(fn -> assert Recorder.finish(recorder, 5000) == :ok end) =~ "could not remove the listener"
  end

  # `didFinishTestFunction`: the open pages at the end of the body, before `on_exit` closes them;
  # then (`persistTemporary`) those of the contexts closed in the body.
  test "screenshots at the end of the body, then of the contexts closed in it", ctx do
    dir = dir(ctx)

    on_exit(fn ->
      assert Enum.sort(File.ls!(dir)) == ["test-finished-1.png", "test-finished-2.png"]
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, screenshot: :on)
    %{context: closed} = new_context(ctx)
    page(closed, "CLOSED")
    BrowserContext.close!(closed)
    %{context: open} = new_context(ctx)
    page = page(open, "OPEN")
    on_exit(fn -> Page.close!(page) end)
  end

  @tag skip: PlaywrightEx.TestBrowser.other_skip_reason()
  test "a plain context of another browser type is recorded: one driver hosts them all", ctx do
    dir = dir(ctx)

    on_exit(fn ->
      trace = trace(dir, ctx.browser)
      assert traced?(trace, "OWN") and traced?(trace, "OTHER-TYPE")
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, trace: :on)
    %{browser: browser} = browser(browser_name: PlaywrightEx.TestBrowser.other_name())
    page(Browser.new_context!(ctx.browser), "OWN")
    page(Browser.new_context!(browser), "OTHER-TYPE")
  end

  @tag :tmp_dir
  test "a trace keeps only its own stacks and sources while another test traces on the driver",
       %{browser: browser, tmp_dir: tmp} = ctx do
    dir = dir(ctx)
    # The other test's calls come from a file of their own.
    other_file = Path.join(tmp, "other_calls.ex")

    File.write!(
      other_file,
      "defmodule #{inspect(__MODULE__)}.OtherCalls, do: def(visit(page), do: PlaywrightEx.Page.set_content!(page, \"x\"))"
    )

    [{other, _}] = Code.compile_file(other_file)
    source = &"src/#{:crypto.hash(:sha, &1) |> Base.encode16(case: :lower)}#{Path.extname(&1)}"

    on_exit(fn ->
      {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "trace.zip")), [:memory])
      files = Map.new(files, fn {name, data} -> {to_string(name), data} end)
      # The context's chunk is the first of two, `test.trace`'s the second.
      %{"files" => paths, "stacks" => stacks} = JSON.decode!(files["0-trace.stacks"])
      call_ids = for %{"type" => "before", "callId" => id} <- trace(dir, browser).events, do: id

      # Every stack is one of the trace's actions', every frame's file is in `files`.
      assert stacks != []
      for [id, frames] <- stacks, do: assert(id in call_ids and Enum.all?(frames, &(hd(&1) < length(paths))))
      assert Enum.uniq(paths) == paths
      assert __ENV__.file in paths
      refute other_file in paths

      sources = for "src/" <> _ = name <- Map.keys(files), do: name
      assert source.(__ENV__.file) in sources
      assert sources -- Enum.map(paths, source) == []
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, trace: :on)
    %{context: context} = new_context(ctx)
    page = page(context, "OWN")
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
    Page.set_content!(page, "<h1>AFTER</h1>")
  end

  test "the trace's options go to Tracing.start", ctx do
    dir = dir(ctx)

    on_exit(fn ->
      trace = trace(dir, ctx.browser)
      assert traced?(trace, "UNSNAPSHOTTED")
      refute Enum.any?(trace.events, &(&1["type"] in ["frame-snapshot", "screencast-frame"]))
      refute Enum.any?(Map.keys(trace.resources), &String.starts_with?(&1, "src/"))
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, trace: [mode: :on, snapshots: false, screenshots: false, sources: false])
    %{context: context} = new_context(ctx)
    page(context, "UNSNAPSHOTTED")
  end

  test "the screenshot's options go to Page.screenshot", ctx do
    dir = dir(ctx)

    on_exit(fn ->
      # The PNG's IHDR: the full page, past the 720 px viewport.
      <<_::binary-size(16), _width::32, height::32, _::binary>> = File.read!(Path.join(dir, "test-finished-1.png"))
      assert height > 2000
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, screenshot: [mode: :on, full_page: true])
    %{context: context} = new_context(ctx)
    Page.set_content!(BrowserContext.new_page!(context), ~s(<div style="height: 2000px">TALL</div>))
  end

  @tag skip: VideoPlayer.skip_reason()
  test "the video's size goes to record_video", ctx do
    dir = dir(ctx)

    on_exit(fn ->
      player = VideoPlayer.new(Path.join(dir, "video.webm"))
      assert {player.videoWidth, player.videoHeight} == {320, 240}
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, video: [mode: :on, size: %{width: 320, height: 240}])
    %{context: context} = new_context(ctx)
    page(context, "SMALL")
  end

  test "a failed test keeps its screenshots and gets error-context.md, with a snapshot of a page closed after it failed",
       ctx do
    test = fake_test(ctx, %{screenshot: :only_on_failure})
    [running, first, second] = for marker <- ~w(RUNNING FIRST SECOND), do: tap(test.context.(), &page(&1, marker))

    # Closed while the test runs: no errors yet, as upstream.
    BrowserContext.close!(running)
    end_test(test, [&{:failed, &1, {:error, %RuntimeError{message: "on purpose"}, []}}], :shutdown)
    BrowserContext.close!(first)
    BrowserContext.close!(second)
    Recorder.finish(test.recorder, 5000)

    assert Enum.sort(File.ls!(test.dir)) == ~w(error-context.md test-failed-1.png test-failed-2.png test-failed-3.png)
    error_context = File.read!(Path.join(test.dir, "error-context.md"))
    assert error_context =~ "```\nRuntimeError: on purpose\n```"
    assert error_context =~ ~s(heading "FIRST")
    refute error_context =~ "RUNNING" or error_context =~ "SECOND"
  end

  test "a passed test keeps nothing of the on_failure modes", ctx do
    test = fake_test(ctx, %{trace: :retain_on_failure, screenshot: :only_on_failure, video: :retain_on_failure})
    page(test.context.(), "PASSED")
    end_test(test, [&{:passed, &1}], :shutdown)
    Recorder.finish(test.recorder, 5000)
    refute File.exists?(test.dir)
  end

  test "a test of another macro (a doctest) keeps them, as a failure's, without error-context.md", ctx do
    test = fake_test(ctx, %{trace: :retain_on_failure, screenshot: :only_on_failure, video: :retain_on_failure}, false)
    page(test.context.(), "UNKNOWN")
    end_test(test, [], :shutdown)
    Recorder.finish(test.recorder, 5000)
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

  test "a test's dir is not emptied: a rerun keeps the first run's other files", ctx do
    dir = dir(ctx)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "test-failed-2.png"), "first run")

    on_exit(fn ->
      assert Enum.sort(File.ls!(dir)) == ["test-failed-2.png", "trace.zip"]
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, trace: :on)
    %{context: context} = new_context(ctx)
    page(context, "RERUN")
  end
end

defmodule PlaywrightEx.Test.ArtifactsTest.Server do
  # A GenServer that creates contexts for a test (a session process): started with `start_link`,
  # so it has `$ancestors` but no `$callers`.
  use GenServer

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page

  def init(identity), do: {:ok, identity}

  def handle_call(:visit, _from, identity) do
    nil = Process.get(:"$callers")
    %{context: context} = PlaywrightEx.Test.new_context(identity)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<h1>SERVER</h1>")
    BrowserContext.close!(context)
    {:reply, :ok, identity}
  end
end
