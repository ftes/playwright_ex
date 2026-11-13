defmodule PlaywrightEx.Test.ConnectTest do
  # `connect_options`: pooled browsers on a `run-server` (Playwright Test's `connectOptions`), on
  # fake tests as in `PlaywrightEx.Test.ArtifactsTest`.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.RemoteServer.RunServer
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.TestServer

  @moduletag timeout: 60_000

  setup_all do
    # Owned by the `setup_all` process: it runs until the module ends.
    server = RunServer.start()
    on_exit(fn -> RunServer.close(server) end)
    %{ws_endpoint: RunServer.ws_endpoint(server)}
  end

  @doc false
  def on_start(playwright, pid), do: send(pid, {:on_start, playwright})

  # A registered test with `tags` (the modes), in a process of its own; `run.(fun)` runs `fun`
  # in a process with it in `$callers`.
  defp fake_test(tags) do
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
            playwright_ex: :marked
          })

        send(parent, {:registered, PlaywrightEx.Test.__register__(context)})

        receive do
          :end ->
            Pool.notify({:passed, self()})
            exit(:shutdown)
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

    %{pid: pid, dir: test.dir, run: run}
  end

  defp finish(test) do
    ref = Process.monitor(test.pid)
    send(test.pid, :end)
    assert_receive {:DOWN, ^ref, :process, _, _}
    capture_io(fn -> PlaywrightEx.Test.__finish__(test.pid, 10_000) end)
  end

  test "a connected browser: on_start on the driver, connected again if lost, the context defaults and the recording",
       %{ws_endpoint: ws_endpoint} do
    opts = [connect_options: [ws_endpoint: ws_endpoint], on_start: {__MODULE__, :on_start, [self()]}]
    test = fake_test(%{trace: :on, screenshot: :on})

    lost = test.run.(fn -> BrowserPool.browser(opts) end)

    assert_receive {:on_start, playwright}
    assert BrowserPool.playwright(lost) == playwright
    # A connection of its own.
    assert lost.conn != playwright.conn

    # A lost one is connected again by the scope's next call.
    Browser.close!(lost)
    browser = test.run.(fn -> BrowserPool.browser(opts) end)
    assert browser != lost and Browser.is_connected(browser)
    assert test.run.(fn -> BrowserPool.browser(opts) end) == browser
    refute_received {:on_start, _}

    test.run.(fn ->
      page = BrowserContext.new_page!(Browser.new_context!(browser))
      Page.set_content!(page, "<h1>REMOTE</h1>")
      assert Page.evaluate!(page, "[navigator.language, innerWidth, innerHeight]") == ["en-US", 1280, 720]
    end)

    finish(test)
    assert Enum.sort(File.ls!(test.dir)) == ["test-finished-1.png", "trace.zip"]
    trace = PlaywrightEx.Utils.parse_trace_raw(Path.join(test.dir, "trace.zip"), browser)
    assert Enum.any?(trace.events, &(JSON.encode!(&1) =~ "REMOTE"))
  end

  test "each driver connects a browser of its own", %{ws_endpoint: ws_endpoint} do
    opts = [connect_options: [ws_endpoint: ws_endpoint]]
    test = fake_test(%{})

    # Another driver key: a scope that holds one driver takes it over `workers`.
    {a, b} =
      test.run.(fn ->
        {BrowserPool.browser(opts), BrowserPool.browser(opts ++ [driver: [env: [{"PW_CONNECT_TEST", "1"}]]])}
      end)

    assert a.conn != b.conn
    assert BrowserPool.playwright(a) != BrowserPool.playwright(b)
    page = test.run.(fn -> BrowserContext.new_page!(Browser.new_context!(b)) end)
    assert Page.evaluate!(page, "navigator.language") == "en-US"
    finish(test)
  end

  test "the launch options go in x-playwright-launch-options, ASCII only; the caller's headers win" do
    server = TestServer.server(start_supervised!({TestServer, dir_path: System.tmp_dir!()}))
    ws_endpoint = "ws://localhost:#{server.port}/ws"
    launch_options = [headless: true, slow_mo: 1, env: %{"NAME" => "Zoë 😀"}, timeout: :infinity]

    request = TestServer.wait_for_web_socket_connection_request(server)
    connect_options = [ws_endpoint: ws_endpoint, timeout: 100, headers: %{"foo" => "bar"}]
    assert_connect_timeout(fn -> browser(launch_options, connect_options) end)
    request = Task.await(request, :infinity)
    [header] = Plug.Conn.get_req_header(request, "x-playwright-launch-options")
    assert Plug.Conn.get_req_header(request, "foo") == ["bar"]
    assert header =~ ~S(Zo\u00eb \ud83d\ude00)
    assert JSON.decode!(header) == %{"headless" => true, "slowMo" => 1, "env" => %{"NAME" => "Zoë 😀"}, "timeout" => 0}

    request = TestServer.wait_for_web_socket_connection_request(server)
    headers = %{"x-playwright-launch-options" => "{}"}

    assert_connect_timeout(fn -> browser(launch_options, Keyword.put(connect_options, :headers, headers)) end)

    assert Plug.Conn.get_req_header(Task.await(request, :infinity), "x-playwright-launch-options") == ["{}"]
  end

  # The client's deadline (an Error) races the driver's own connect timeout (a TimeoutError), as upstream's.
  defp assert_connect_timeout(fun), do: assert(Exception.message(catch_error(fun.())) =~ "Timeout 100ms exceeded")

  defp browser(launch_options, connect_options),
    do: BrowserPool.browser(launch_options: launch_options, connect_options: connect_options)
end
