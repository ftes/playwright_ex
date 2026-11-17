defmodule Playwright.Test.SetupAllTest do
  # The contexts of a module's `setup_all`, as upstream's `browser.newContext()` in `beforeAll`,
  # which gets the `all-hooks-included` fixtures: the context defaults, the config's
  # `context_options` and timeouts, merged under the call's options. Sync, so the config's
  # `base_url` here reaches no other module.
  use ExUnit.Case, async: false

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.APIResponse
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.Test.BrowserPool
  alias Playwright.TestServer

  # Before `use Playwright.Test`, whose `setup_all` reads the config.
  setup_all do
    server = TestServer.server(start_supervised!({TestServer, dir_path: System.tmp_dir!()}))
    TestServer.set_content(server, "/", "<p>home</p>", "text/html")
    TestServer.set_content(server, "/api", ~s({"ok": true}), "application/json")

    config = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, config) end)

    Application.put_env(
      :playwright,
      :test,
      Keyword.merge(config,
        context_options: [base_url: server.prefix, locale: "de-DE"],
        action_timeout: 4321,
        navigation_timeout: 5432
      )
    )

    %{server: server}
  end

  use Playwright.Test

  setup_all do
    browser = BrowserPool.browser()
    playwright = BrowserPool.playwright(browser)

    open = fn options ->
      context = Browser.new_context!(browser, options)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, "/")
      %{context: context, page: page}
    end

    shared = open.([])
    own = open.(locale: "fr-FR")
    # A process of the `setup_all`'s, through `$callers`.
    spawned = Task.await(Task.async(fn -> open.([]) end))

    request = APIRequest.new_context!(Playwright.request(playwright))

    on_exit(fn ->
      for %{context: context} <- [shared, own, spawned], do: BrowserContext.close!(context)
      APIRequestContext.dispose!(request)
    end)

    %{shared: shared, own: own, spawned: spawned, request: request}
  end

  defp language(%{page: page}), do: Page.evaluate!(page, "navigator.language")

  defp timeouts(owner) do
    settings = Heap.get(owner, :_timeoutSettings)
    {Heap.get(settings, :_defaultTimeout), Heap.get(settings, :_defaultNavigationTimeout)}
  end

  test "a context of setup_all gets the defaults and the config's context_options, base_url too", ctx do
    assert Page.url(ctx.shared.page) == ctx.server.prefix <> "/"
    assert Page.text_content!(ctx.shared.page, "p") == "home"
    assert language(ctx.shared) == "de-DE"
    assert Page.viewport_size(ctx.shared.page) == %{width: 1280, height: 720}
  end

  test "an option the call gives wins", ctx do
    assert language(ctx.own) == "fr-FR"
    assert Page.url(ctx.own.page) == ctx.server.prefix <> "/"
  end

  test "a context of a process of setup_all's ($callers) gets them too", ctx do
    assert language(ctx.spawned) == "de-DE"
    assert Page.url(ctx.spawned.page) == ctx.server.prefix <> "/"
  end

  test "a request context of setup_all gets the base_url and the action timeout", ctx do
    assert APIResponse.status(APIRequestContext.get!(ctx.request, "/api")) == 200
    assert {4321, nil} = timeouts(ctx.request)
  end

  test "a context of setup_all gets the config's timeouts", ctx do
    assert timeouts(ctx.shared.context) == {4321, 5432}
  end
end

defmodule Playwright.Test.SetupAllTest.RecordingTest do
  # A test records the contexts of its module's `setup_all` still open, as upstream's
  # `willStartTest` does the worker's existing contexts, but leaves them open. On fake tests and a
  # fake module, as `Playwright.Test.ArtifactsTest`'s: the `setup_all` process and the tests are
  # spawned by one process, their ExUnit runner (here the test process).
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Page
  alias Playwright.Test.BrowserPool
  alias Playwright.Test.Pool
  alias Playwright.Test.Recorder
  alias Playwright.Test.Results
  alias Playwright.TestServer

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  setup do
    server = TestServer.server(start_supervised!({TestServer, dir_path: System.tmp_dir!()}))
    TestServer.set_content(server, "/api", ~s({"ok": true}), "application/json")
    %{server: server}
  end

  # A module's `setup_all` process, registered as `use Playwright.Test`'s `setup_all` does, alive
  # until the test ends; `fun` runs in it.
  defp fake_module(fun) do
    parent = self()

    pid =
      spawn(fn ->
        Playwright.Test.__setup_all__(%{module: __MODULE__})
        send(parent, {:module, fun.()})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:module, result}, 30_000
    result
  end

  # A registered test with `tags`, spawned by `spawn` (by default by this process, the fake
  # module's runner), ended by `finish/1`; its `run.(fun)` runs `fun` in a process with it in
  # `$callers`.
  defp fake_test(tags, spawn \\ &spawn/1) do
    parent = self()
    name = "t#{System.unique_integer([:positive])}"

    spawn.(fn ->
      context =
        Map.merge(tags, %{
          test_pid: self(),
          module: __MODULE__,
          test: :"test #{name}",
          file: __ENV__.file,
          line: 1,
          playwright_test: :marked
        })

      send(parent, {:registered, self(), Playwright.Test.__register__(context)})

      receive do
        :end ->
          Results.notify({:passed, self()})
          exit(:shutdown)
      end
    end)

    assert_receive {:registered, pid, test}
    on_exit(fn -> File.rm_rf!(test.output_dir) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      Pool.release(pid)
    end)

    run = fn fun ->
      Task.await(
        Task.async(fn ->
          Process.put(:"$callers", [pid])
          fun.()
        end),
        30_000
      )
    end

    %{pid: pid, dir: test.output_dir, run: run}
  end

  defp finish(test) do
    ref = Process.monitor(test.pid)
    send(test.pid, :end)
    assert_receive {:DOWN, ^ref, :process, _, _}
    capture_io(fn -> Playwright.Test.__finish__(test.pid, 10_000) end)
  end

  defp traced?(dir, browser, text) do
    trace = Playwright.Utils.parse_trace_raw(Path.join(dir, "trace.zip"), browser)
    Enum.any?(trace.events, &(JSON.encode!(&1) =~ text))
  end

  defp show(page, marker), do: Page.set_content!(page, "<h1>#{marker}</h1>")

  test "each test records the module's open contexts in its own trace and screenshots, and leaves them open",
       %{browser: browser, server: server} do
    %{context: context, page: page, request: request} =
      fake_module(fn ->
        context = Browser.new_context!(browser)
        page = BrowserContext.new_page!(context)
        show(page, "SETUP")
        request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
        %{context: context, page: page, request: request}
      end)

    first = fake_test(%{trace: :on, screenshot: :on})
    assert [%{guid: guid, shared: true}] = :sys.get_state(Recorder.lookup(first.pid)).contexts
    assert guid == context.guid

    first.run.(fn ->
      show(page, "FIRST")
      APIRequestContext.get!(request, server.prefix <> "/api?first")
    end)

    finish(first)
    assert traced?(first.dir, browser, "FIRST")
    assert traced?(first.dir, browser, "/api?first")
    assert File.exists?(Path.join(first.dir, "test-finished-1.png"))

    # Still open, and the next test's trace is a chunk of its own: no call of the first (its
    # DOM snapshots do show the page as the first left it).
    second = fake_test(%{trace: :on})
    second.run.(fn -> show(page, "SECOND") end)
    finish(second)
    assert traced?(second.dir, browser, "SECOND")
    refute traced?(second.dir, browser, "<h1>FIRST")

    # A test that doesn't trace stops the tracing; the one after starts it again.
    third = fake_test(%{})
    third.run.(fn -> show(page, "THIRD") end)
    finish(third)
    refute File.exists?(Path.join(third.dir, "trace.zip"))

    fourth = fake_test(%{trace: :on})
    fourth.run.(fn -> show(page, "FOURTH") end)
    finish(fourth)
    assert traced?(fourth.dir, browser, "FOURTH")
    refute traced?(fourth.dir, browser, "<h1>THIRD")

    assert Page.text_content!(page, "h1") == "FOURTH"
    BrowserContext.close!(context)
    APIRequestContext.dispose!(request)
  end

  test "a module context a test closes is collected in that test, and its next tests don't record it", %{
    browser: browser
  } do
    %{context: context, page: page} =
      fake_module(fn ->
        context = Browser.new_context!(browser)
        %{context: context, page: BrowserContext.new_page!(context)}
      end)

    test = fake_test(%{trace: :on})

    test.run.(fn ->
      show(page, "CLOSED")
      BrowserContext.close!(context)
    end)

    finish(test)
    assert traced?(test.dir, browser, "CLOSED")

    next = fake_test(%{trace: :on})
    assert :sys.get_state(Recorder.lookup(next.pid)).contexts == []
    finish(next)
  end

  test "a test of another module (another runner) records none of the module's contexts", %{browser: browser} do
    %{context: context} =
      fake_module(fn ->
        context = Browser.new_context!(browser)
        %{context: context}
      end)

    # Spawned by another process than the module's `setup_all`.
    other = fake_test(%{trace: :on}, fn fun -> Task.await(Task.async(fn -> spawn(fun) end)) end)
    assert :sys.get_state(Recorder.lookup(other.pid)).contexts == []

    # Its own context is its own.
    other.run.(fn -> Browser.new_context!(browser) end)
    assert [entry] = :sys.get_state(Recorder.lookup(other.pid)).contexts
    refute entry[:shared]
    finish(other)
    BrowserContext.close!(context)
  end
end
