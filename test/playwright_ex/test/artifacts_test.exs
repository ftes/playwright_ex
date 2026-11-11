defmodule PlaywrightEx.Test.ArtifactsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Tracing

  setup_all :browser

  defp dir(ctx), do: Recorder.output_dir(Options.output_dir(), ctx.file, ctx.test)

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
    identity = Map.take(ctx, [:browser, :module, :test])
    {:ok, server} = GenServer.start_link(PlaywrightEx.Test.ArtifactsTest.Server, identity)
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

  test "retained files are deleted when the test passes", ctx do
    dir = dir(ctx)
    key = {ctx.module, ctx.test}

    on_exit(fn ->
      assert [{_, retained}] = :ets.lookup(Pool.table(), {:retained, key})
      assert retained |> Enum.map(&Path.basename/1) |> Enum.sort() == ~w(test-failed-1.png trace.zip video.webm)
      # As the formatter does for a failed test, then for a passing one.
      Recorder.test_finished(key, false)
      assert Enum.all?(retained, &File.exists?/1)
      :ets.insert(Pool.table(), {{:retained, key}, retained})
      Recorder.test_finished(key, true)
      refute File.exists?(dir)
    end)

    record_artifacts(ctx, trace: :retain_on_failure, screenshot: :only_on_failure, video: :retain_on_failure)
    %{context: context} = new_context(ctx)
    page(context, "RETAINED")
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
