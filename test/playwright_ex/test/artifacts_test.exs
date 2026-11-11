defmodule PlaywrightEx.Test.ArtifactsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Tracing

  setup_all :browser

  defp dir(ctx), do: Recorder.output_dir(ctx)

  defp trace(dir, handle), do: PlaywrightEx.Utils.parse_trace_raw(Path.join(dir, "trace.zip"), handle)

  defp traced?(trace, text), do: Enum.any?(trace.events, &(JSON.encode!(&1) =~ text))

  defp page(context, marker) do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<h1>#{marker}</h1>")
    page
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
    opts = %{
      trace: :on,
      screenshot: :off,
      video: :off,
      error_context: false,
      dir: dir(ctx),
      title: "bounded",
      test_key: :bounded
    }

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
      %{"files" => paths, "stacks" => stacks} = JSON.decode!(files["trace.stacks"])
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

  @tag skip: if(!PlaywrightEx.Test.Options.error_context?(), do: "env: PLAYWRIGHT_NO_COPY_PROMPT")
  test "a test takes one page snapshot for error-context.md, of the first closed context's first page", ctx do
    %{context: one} = new_context(ctx)
    %{context: two} = new_context(ctx)
    page(one, "FIRST")
    page(two, "SECOND")
    BrowserContext.close!(one)
    BrowserContext.close!(two)
    assert GenServer.call(Recorder.lookup(self()), :state).page_snapshot =~ ~s(heading "FIRST")
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
  # A GenServer that creates contexts for a test, as Fluffy's sessions do: started with
  # `start_link`, so it has `$ancestors` but no `$callers`.
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
