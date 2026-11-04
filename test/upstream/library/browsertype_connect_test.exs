# The `dummyServerPort` / `ipV6ServerPort` servers: every request gets the body.
defmodule PlaywrightEx.Library.BrowsertypeConnectTest.BodyPlug do
  @moduledoc false
  @behaviour Plug
  def init(body), do: body
  def call(conn, body), do: Plug.Conn.send_resp(conn, 200, body)
end

defmodule PlaywrightEx.Library.BrowsertypeConnectTest do
  @upstream "tests/library/browsertype-connect.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [ensure_some_frames: 1, parse_trace_raw: 2]

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Download
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Promise
  alias PlaywrightEx.RemoteServer.RunServer
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime.Facade
  alias PlaywrightEx.Selectors
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Video

  # Deviations:
  #   * Only the `run-server` kind: `launchServer` is out of scope (PLAN), so the
  #     `for (const kind of ['launchServer', 'run-server'])` loop has one `describe`.
  #   * `remoteServer.close()` kills `run-server` with `kill -9` (it ignores SIGTERM).
  #   * No `ws` client: tests that open a WebSocket from the test are skipped.

  @k_target_closed_error_message "Target page, context or browser has been closed"

  # The `dummyServerPort` / `ipV6ServerPort` fixtures: every request gets `body`.
  defp body_server_port(ip, body) do
    pid =
      start_supervised!({Bandit, plug: {__MODULE__.BodyPlug, body}, ip: ip, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp dummy_server_port, do: body_server_port({127, 0, 0, 1}, "<html><body>from-dummy-server</body></html>")
  defp ipv6_server_port, do: body_server_port({0, 0, 0, 0, 0, 0, 0, 1}, "<html><body>from-ipv6-server</body></html>")

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # The `connect` fixture: connected browsers are closed after the test. Test hooks
  # (`(options as any).__testHook...`) are no API options, so with them it calls the client.
  defp connect(browser_type, ws_endpoint, options \\ [], test_options \\ []) do
    options = Map.new(options)
    {hooks, options} = Map.split(options, [:__testHookBeforeCreateBrowser])

    hooks =
      if port = test_options[:redirect_port_for_test],
        do: Map.put(hooks, :__testHookRedirectPortForwarding, port),
        else: hooks

    launch_options = Map.new(test_options[:launch_options] || [])

    options =
      Map.put(
        options,
        :headers,
        Map.merge(%{"x-playwright-launch-options" => JSON.encode!(launch_options)}, options[:headers] || %{})
      )

    result =
      if hooks == %{} do
        BrowserType.connect(browser_type, ws_endpoint, options)
      else
        params =
          for {key, js} <- [headers: :headers, timeout: :timeout, expose_network: :exposeNetwork, slow_mo: :slowMo],
              Map.has_key?(options, key),
              into: hooks,
              do: {js, options[key]}

        Facade.async("browserType.connect", browser_type, fn ->
          PlaywrightEx.Client.BrowserType.connect(browser_type, ws_endpoint, params)
        end)
      end

    with {:ok, browser} <- result, do: on_exit(fn -> Browser.close(browser) end)
    result
  end

  defp connect!(browser_type, ws_endpoint, options \\ [], test_options \\ []) do
    {:ok, browser} = connect(browser_type, ws_endpoint, options, test_options)
    browser
  end

  defp download_route(server) do
    TestServer.set_route(server, "/download", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header("content-disposition", "attachment")
      |> Plug.Conn.send_resp(200, "Hello world")
    end)
  end

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  # Keeps the response open (upstream: no `res.end()`) until the client closes the connection,
  # then the handler dies with its socket.
  defp wait_for_close(conn, on_close) do
    %Plug.Conn{adapter: {Bandit.Adapter, adapter}} = conn
    ThousandIsland.Socket.recv(adapter.transport.socket, 0, 30_000)
    on_close.()
    ThousandIsland.Socket.close(adapter.transport.socket)
    Process.exit(self(), :kill)
  end

  defp write_200mb(path) do
    str = String.duplicate("A", 4 * 1024)
    File.open!(path, [:write, :raw, :binary], fn file -> for _ <- 1..(50 * 1024), do: IO.binwrite(file, str) end)
  end

  # formidable's IncomingForm: the multipart parts by field name.
  defp parse_multipart(conn) do
    [content_type] = Plug.Conn.get_req_header(conn, "content-type")
    {:ok, "multipart", "form-data", %{"boundary" => boundary}} = Plug.Conn.Utils.content_type(content_type)

    conn.assigns.post_body
    |> :binary.split("--" <> boundary, [:global])
    |> Enum.drop(1)
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Map.new(fn "\r\n" <> part ->
      [head, content] = :binary.split(part, "\r\n\r\n")
      [_, name] = Regex.run(~r/;\s*name="([^"]*)"/, head)
      filename = with [_, filename] <- Regex.run(~r/;\s*filename="([^"]*)"/, head), do: filename
      {name, %{original_filename: filename, size: byte_size(content) - 2}}
    end)
  end

  # Reached routes report to the test (`reachedOriginalTarget = true`).
  defp reached_route(server, path, body) do
    test = self()

    TestServer.set_route(server, path, fn conn ->
      send(test, :reached_original_target)
      Plug.Conn.send_resp(conn, 200, body)
    end)
  end

  # `new Promise(f => browser.on('disconnected', f))`
  defp disconnected(browser) do
    test = self()
    ref = make_ref()
    Browser.once(browser, :disconnected, fn b -> send(test, {ref, b}) end)
    ref
  end

  describe "run-server" do
    @describetag kind: "run-server"

    @tag skip: "not ported: WebSocket client (ws)"
    test "should connect over wss"

    test "should print HTTP error", %{browser_type: browser_type, server: server} do
      {:error, error} = connect(browser_type, "ws://localhost:#{server.port}/ws-401")
      assert Exception.message(error) =~ "401"
      assert Exception.message(error) =~ "Unauthorized body"
    end

    test "should print ws error", %{browser_type: browser_type} do
      {:error, error} = connect(browser_type, "ws://does-not-exist.problem-domain:10987?secret=MYSECRET")
      assert Exception.message(error) =~ "<ws connecting> ws://does-not-exist.problem-domain:10987/"
      assert Exception.message(error) =~ "<ws error>"
      assert Exception.message(error) =~ "getaddrinfo"
      refute Exception.message(error) =~ "secret=MYSECRET"
    end

    test "should print custom ws close error", %{browser_type: browser_type, server: server} do
      TestServer.once_web_socket_connection(server, fn ws, _request ->
        TestServer.WebSocket.on(ws, :message, fn _message ->
          TestServer.WebSocket.close(ws, 4123, "Oh my!")
        end)
      end)

      {:error, error} = connect(browser_type, "ws://localhost:#{server.port}/ws")
      assert Exception.message(error) =~ "browserType.connect: Oh my!"
    end

    test "should be able to reconnect to a browser", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      browser_context = Browser.new_context!(browser)
      assert BrowserContext.pages(browser_context) == []
      page = BrowserContext.new_page!(browser_context)
      assert Page.evaluate!(page, "11 * 11") == 121
      Page.goto!(page, server.empty_page)
      Browser.close!(browser)

      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      browser_context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(browser_context)
      Page.goto!(page, server.empty_page)
      Browser.close!(browser)
    end

    @tag skip: "not ported: WebSocket client (ws)"
    test "should not crash on malformed json frame"

    test "should be able to visit ipv6", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      ipv6_server_port = ipv6_server_port()
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      ipv6_url = "http://[::1]:#{ipv6_server_port}"
      Page.goto!(page, ipv6_url)
      assert Page.content!(page) =~ "from-ipv6-server"
      Browser.close!(browser)
    end

    @tag skip: "not ported: Page.pause"
    test "should ignore page.pause when headed"

    test "should be able to visit ipv6 through localhost", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      ipv6_server_port = ipv6_server_port()
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      ipv6_url = "http://localhost:#{ipv6_server_port}"
      Page.goto!(page, ipv6_url)
      assert Page.content!(page) =~ "from-ipv6-server"
      Browser.close!(browser)
    end

    test "should be able to connect two browsers at the same time", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      browser1 = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      assert Browser.contexts(browser1) == []
      Browser.new_context!(browser1)
      assert length(Browser.contexts(browser1)) == 1

      browser2 = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      assert Browser.contexts(browser2) == []
      Browser.new_context!(browser2)
      assert length(Browser.contexts(browser2)) == 1
      assert length(Browser.contexts(browser1)) == 1

      Browser.close!(browser1)
      assert length(Browser.contexts(browser2)) == 1
      page2 = Browser.new_page!(browser2)
      # original browser should still work
      assert Page.evaluate!(page2, "() => 7 * 6") == 42

      Browser.close!(browser2)
    end

    test "should timeout in socket while connecting", %{browser_type: browser_type, server: server} do
      {:error, e} = connect(browser_type, "ws://localhost:#{server.port}/ws-slow", timeout: 1000)
      assert Exception.message(e) =~ "browserType.connect: Timeout 1000ms exceeded"
    end

    test "should timeout in connect while connecting", %{browser_type: browser_type, server: server} do
      {:error, e} = connect(browser_type, "ws://localhost:#{server.port}/ws", timeout: 100)
      assert Exception.message(e) =~ "browserType.connect: Timeout 100ms exceeded"
    end

    test "should send extra headers with connect request", %{browser_type: browser_type, server: server} do
      request = TestServer.wait_for_web_socket_connection_request(server)

      connect(browser_type, "ws://localhost:#{server.port}/ws",
        headers: %{"User-Agent" => "Playwright", "foo" => "bar"},
        timeout: 100
      )

      request = Task.await(request)
      assert header(request, "user-agent") == "Playwright"
      assert header(request, "foo") == "bar"
    end

    @tag skip: "not ported: connect(options) overload (the API docs have connect(wsEndpoint, options))"
    test "should send extra headers with connect request in object form"

    test "should send default User-Agent and X-Playwright-Browser headers with connect request", %{
      browser_type: browser_type,
      browser_name: browser_name,
      server: server
    } do
      request = TestServer.wait_for_web_socket_connection_request(server)
      connect(browser_type, "ws://localhost:#{server.port}/ws", headers: %{"foo" => "bar"}, timeout: 100)
      request = Task.await(request)
      # `getUserAgent()` of the driver (the test can't compute it): `Playwright/<version> (<os>) ...`.
      assert header(request, "user-agent") =~ ~r"^Playwright/#{PlaywrightEx.Driver.version()} \(.+\) "
      assert header(request, "x-playwright-browser") == browser_name
      assert header(request, "foo") == "bar"
    end

    test "should support slowmo option", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      browser1 = connect!(browser_type, RunServer.ws_endpoint(remote_server), slow_mo: 200)
      start = System.monotonic_time(:millisecond)
      Browser.new_context!(browser1)
      Browser.close!(browser1)
      assert System.monotonic_time(:millisecond) - start > 199
    end

    test "disconnected event should be emitted when browser is closed or server is closed", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      browser1 = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      Browser.new_page!(browser1)

      browser2 = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      Browser.new_page!(browser2)

      test = self()
      Browser.on(browser1, :disconnected, fn _ -> send(test, :disconnected1) end)
      Browser.on(browser2, :disconnected, fn _ -> send(test, :disconnected2) end)

      ref1 = disconnected(browser1)
      Browser.close!(browser1)
      assert_receive {^ref1, _}
      assert_received :disconnected1
      refute_received :disconnected2

      ref2 = disconnected(browser2)
      RunServer.close(remote_server)
      assert_receive {^ref2, _}, 10_000
      refute_received :disconnected1
      assert_received :disconnected2
    end

    test "disconnected event should have browser as argument", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      ref = disconnected(browser)
      Browser.close!(browser)
      assert_receive {^ref, disconnected}
      assert disconnected == browser
    end

    test "should handle exceptions during connect", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      test_hook_before_create_browser = fn -> raise "Dummy" end

      {:error, error} =
        connect(browser_type, RunServer.ws_endpoint(remote_server),
          __testHookBeforeCreateBrowser: test_hook_before_create_browser
        )

      assert Exception.message(error) =~ "Dummy"
    end

    test "should set the browser connected state", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      remote = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      assert Browser.is_connected(remote) == true
      Browser.close!(remote)
      assert Browser.is_connected(remote) == false
    end

    test "should throw when used after isConnected returns false", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      ref = disconnected(browser)
      RunServer.close(remote_server)
      assert_receive {^ref, _}, 10_000
      assert Browser.is_connected(browser) == false
      {:error, error} = Page.evaluate(page, "1 + 1")
      assert Exception.message(error) =~ "closed"
    end

    test "should throw when calling waitForNavigation after disconnect", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      ref = disconnected(browser)
      RunServer.close(remote_server)
      assert_receive {^ref, _}, 10_000
      assert Browser.is_connected(browser) == false
      {:error, error} = Promise.await(Page.wait_for_navigation(page))
      assert Exception.message(error) =~ @k_target_closed_error_message
    end

    test "should reject navigation when browser closes", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      TestServer.set_route(server, "/one-style.css", fn conn ->
        Process.sleep(:infinity)
        conn
      end)

      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      request = TestServer.wait_for_request(server, "/one-style.css")
      navigation = Task.async(fn -> Page.goto(page, server.prefix <> "/one-style.html", timeout: 60_000) end)
      Task.await(request)
      Browser.close!(browser)
      {:error, error} = Task.await(navigation)
      assert Exception.message(error) =~ "has been closed"
    end

    test "should reject waitForSelector when browser closes", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      TestServer.set_route(server, "/empty.html", fn conn ->
        Process.sleep(:infinity)
        conn
      end)

      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      watchdog = Task.async(fn -> Page.wait_for_selector(page, "div", state: :attached, timeout: 60_000) end)

      # Make sure the previous waitForSelector has time to make it to the browser before we disconnect.
      Page.wait_for_selector!(page, "body", state: :attached)

      Browser.close!(browser)
      {:error, error} = Task.await(watchdog)
      assert Exception.message(error) =~ "has been closed"
    end

    test "should emit close events on pages and contexts", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)
      test = self()
      Page.on(page, :close, fn _ -> send(test, :page_closed) end)
      BrowserContext.on(context, :close, fn _ -> send(test, :context_closed) end)
      RunServer.close(remote_server)
      assert_receive :context_closed, 10_000
      assert_received :page_closed
    end

    test "should terminate network waiters", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      new_page = Browser.new_page!(browser)
      request = Page.wait_for_request(new_page, server.empty_page)
      response = Page.wait_for_response(new_page, server.empty_page)
      RunServer.close(remote_server)

      for result <- [Promise.await(request), Promise.await(response)] do
        {:error, error} = result
        message = Exception.message(error)
        assert message =~ @k_target_closed_error_message
        refute message =~ "Timeout"
      end
    end

    test "should reject waitForEvent before browser.close finishes", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      new_page = Browser.new_page!(browser)
      promise = Page.wait_for_event(new_page, :download)
      Browser.close!(browser)
      # Settled when `close` returns: awaiting does not block.
      assert {:error, _} = Task.await(Task.async(fn -> Promise.await(promise) end), 100)
    end

    test "should reject waitForEvent before browser.onDisconnect fires", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      new_page = Browser.new_page!(browser)
      test = self()
      promise = Page.wait_for_event(new_page, :download)
      Task.start(fn -> send(test, {:log, elem(Promise.await(promise), 0) == :error && "rejected"}) end)
      Browser.on(browser, :disconnected, fn _ -> send(test, {:log, "disconnected"}) end)
      RunServer.close(remote_server)
      assert_receive {:log, first}, 10_000
      assert_receive {:log, second}, 10_000
      assert [first, second] == ["rejected", "disconnected"]
    end

    test "should respect selectors", %{
      playwright: playwright,
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      mycss1 = "mycss1-" <> kind
      mycss2 = "mycss2-" <> kind
      mycss3 = "mycss3-" <> kind

      # Selector engines are JS source (PLAN: no function serialization).
      mycss = """
      (() => ({
        query(root, selector) {
          return root.querySelector(selector);
        },
        queryAll(root, selector) {
          return Array.from(root.querySelectorAll(selector));
        }
      }))()
      """

      # Register one engine before connecting.
      Selectors.register!(Playwright.selectors(playwright), mycss1, mycss)

      browser1 = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      context1 = Browser.new_context!(browser1)

      # Register another engine after creating context.
      Selectors.register!(Playwright.selectors(playwright), mycss2, mycss)

      page1 = BrowserContext.new_page!(context1)
      Page.set_content!(page1, "<div>hello</div>")
      assert Page.inner_html!(page1, "css=div") == "hello"
      assert Page.inner_html!(page1, "#{mycss1}=div") == "hello"
      assert Page.inner_html!(page1, "#{mycss2}=div") == "hello"

      browser2 = connect!(browser_type, RunServer.ws_endpoint(remote_server))

      # Register third engine after second connect.
      Selectors.register!(Playwright.selectors(playwright), mycss3, mycss)

      page2 = Browser.new_page!(browser2)
      Page.set_content!(page2, "<div>hello</div>")
      assert Page.inner_html!(page2, "css=div") == "hello"
      assert Page.inner_html!(page2, "#{mycss1}=div") == "hello"
      assert Page.inner_html!(page2, "#{mycss2}=div") == "hello"
      assert Page.inner_html!(page2, "#{mycss3}=div") == "hello"

      Browser.close!(browser1)
    end

    test "should not throw on close after disconnect", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      Browser.new_page!(browser)
      ref = disconnected(browser)
      RunServer.close(remote_server)
      assert_receive {^ref, _}, 10_000
      Browser.close!(browser)
    end

    @tag :tmp_dir
    test "should saveAs videos from remote browser", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      videos_path = tmp_dir

      context =
        Browser.new_context!(browser, record_video: %{dir: videos_path, size: %{width: 320, height: 240}})

      page = BrowserContext.new_page!(context)
      Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      # https://github.com/microsoft/playwright/issues/36685
      # recordVideo.dir might be unaccessible in server mode, so /tmp/artifacts should be used
      assert File.ls!(videos_path) == []

      saved_as_path = Path.join(tmp_dir, "my-video.webm")
      Video.save_as!(Page.video(page), saved_as_path)
      assert File.exists?(saved_as_path)
    end

    @tag :tmp_dir
    test "should save videos to artifactsDir", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      artifacts_dir = Path.join(tmp_dir, "artifacts")
      remote_server = start_remote_server.(kind, %{artifactsDir: artifacts_dir})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      local_dir = Path.join(tmp_dir, "random-dir")

      context =
        Browser.new_context!(browser, record_video: %{dir: local_dir, size: %{width: 320, height: 240}})

      page = BrowserContext.new_page!(context)
      Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      saved_as_path = Path.join(tmp_dir, "my-video.webm")
      Video.save_as!(Page.video(page), saved_as_path)
      assert File.exists?(saved_as_path)
      refute File.exists?(local_dir)

      Browser.close!(browser)
    end

    @tag :tmp_dir
    test "should name video file after page guid when connecting to remote browser with artifactsDir", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      artifacts_dir = Path.join(tmp_dir, "artifacts")
      remote_server = start_remote_server.(kind, %{artifactsDir: artifacts_dir})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      context = Browser.new_context!(browser, record_video: %{size: %{width: 320, height: 240}})
      page = BrowserContext.new_page!(context)
      Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      assert File.exists?(Path.join(artifacts_dir, page.guid <> ".webm"))

      Browser.close!(browser)
    end

    if !match?({:unix, :linux}, :os.type()), do: @tag(skip: "Testing non-platform specific code")
    # `process.on('warning')`: no Node warnings to listen for here.
    test "should be able to connect 20 times to a single server without warnings", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browsers = for _ <- 1..20, do: connect!(browser_type, RunServer.ws_endpoint(remote_server))
      browsers |> Enum.map(&Task.async(fn -> Browser.close!(&1) end)) |> Task.await_many()
    end

    @tag :tmp_dir
    test "should save download", %{
      server: server,
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      download_route(server)

      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = Page.wait_for_event(page, :download)
      Page.click!(page, "a")
      download = Promise.await!(download)
      nested_path = Path.join([tmp_dir, "these", "are", "directories", "download.txt"])
      Download.save_as!(download, nested_path)
      assert File.exists?(nested_path)
      assert File.read!(nested_path) == "Hello world"
      {:error, error} = Download.path(download)

      assert Exception.message(error) =~
               "Path is not available when connecting remotely. Use saveAs() to save a local copy."

      Browser.close!(browser)
    end

    @tag :tmp_dir
    test "should error when saving download after deletion", %{
      server: server,
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      download_route(server)

      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = Page.wait_for_event(page, :download)
      Page.click!(page, "a")
      download = Promise.await!(download)
      user_path = Path.join(tmp_dir, "download.txt")
      Download.delete!(download)
      {:error, error} = Download.save_as(download, user_path)
      assert Exception.message(error) =~ "Target page, context or browser has been closed"
      Browser.close!(browser)
    end

    # `(browser as any)._connection.close()`: the client's connection.
    test "should properly disconnect when connection closes from the client side", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind
    } do
      TestServer.set_route(server, "/one-style.css", fn conn ->
        Process.sleep(:infinity)
        conn
      end)

      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      request = TestServer.wait_for_request(server, "/one-style.css")
      navigation = Task.async(fn -> Page.goto(page, server.prefix <> "/one-style.html", timeout: 60_000) end)
      wait_for_navigation = Page.wait_for_navigation(page)
      Task.await(request)

      ref = disconnected(browser)
      # This closes the websocket.
      connection = PlaywrightEx.Runtime.Heap.get(browser, :_connection)
      PlaywrightEx.Runtime.Api.call(nil, browser, fn -> PlaywrightEx.Client.Connection.close(connection) end)
      assert_receive {^ref, _}
      assert Browser.is_connected(browser) == false

      {:error, nav_error} = Task.await(navigation)
      assert Exception.message(nav_error) =~ @k_target_closed_error_message
      {:error, error} = Promise.await(wait_for_navigation)
      assert Exception.message(error) =~ @k_target_closed_error_message
      {:error, error} = Page.goto(page, server.empty_page)
      assert Exception.message(error) =~ "has been closed"
      {:error, error} = Promise.await(Page.wait_for_navigation(page))
      assert Exception.message(error) =~ @k_target_closed_error_message
    end

    test "should be able to connect when the wsEndpoint is passed as an option", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      browser =
        BrowserType.connect!(browser_type, RunServer.ws_endpoint(remote_server),
          headers: %{"x-playwright-launch-options" => JSON.encode!(%{})}
        )

      page = Browser.new_page!(browser)
      assert Page.evaluate!(page, "1 + 2") == 3
      Browser.close!(browser)
    end

    @tag :tmp_dir
    test "should save har", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      har_path = Path.join(tmp_dir, "test.har")
      context = Browser.new_context!(browser, record_har: %{path: har_path})
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      BrowserContext.close!(context)
      Browser.close!(browser)

      log = JSON.decode!(File.read!(har_path))["log"]
      assert length(log["entries"]) == 1
      [entry] = log["entries"]
      assert entry["pageref"] == hd(log["pages"])["id"]
      assert entry["request"]["url"] == server.empty_page
    end

    # `_playwright._defaultTracesDir` is no client field (any more): setting it changes nothing.
    @tag :tmp_dir
    test "should filter launch options", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      traces_dir = Path.join(tmp_dir, "traces")
      playwright = PlaywrightEx.Runtime.Heap.get(browser_type, :_playwright)
      old_traces_dir = PlaywrightEx.Runtime.Heap.get(playwright, :_defaultTracesDir)
      PlaywrightEx.Runtime.Heap.put(playwright, :_defaultTracesDir, traces_dir)
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      page = Browser.new_page!(browser)
      Page.goto!(page, server.empty_page)
      Browser.close!(browser)
      PlaywrightEx.Runtime.Heap.put(playwright, :_defaultTracesDir, old_traces_dir)
      assert File.exists?(traces_dir) == false
    end

    @tag :tmp_dir
    test "should record trace with sources", %{
      playwright: playwright,
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)

      Tracing.start!(BrowserContext.tracing(context), sources: true)
      Page.goto!(page, server.empty_page)
      Page.set_content!(page, "<button>Click</button>")
      Page.click!(page, ~s("Click"))
      Tracing.stop!(BrowserContext.tracing(context), path: Path.join(tmp_dir, "trace1.zip"))

      BrowserContext.close!(context)
      Browser.close!(browser)

      %{resources: resources} = parse_trace_raw(Path.join(tmp_dir, "trace1.zip"), playwright)
      source_names = resources |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "src/"))
      assert length(source_names) == 1
      source_file = resources[hd(source_names)]
      this_file = File.read!(__ENV__.file)
      assert source_file == this_file
    end

    test "should fulfill with global fetch result", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      playwright: playwright,
      server: server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)

      Page.route!(page, "**/*", fn route ->
        request = APIRequest.new_context!(Playwright.request(playwright))
        response = APIRequestContext.get!(request, server.prefix <> "/simple.json")
        Route.fulfill!(route, response: response)
      end)

      response = Page.goto!(page, server.empty_page)
      assert Response.status(response) == 200
      assert Response.json!(response) == %{"foo" => "bar"}
    end

    @tag :tmp_dir
    @tag timeout: 360_000
    test "should upload large file", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)

      Page.goto!(page, server.prefix <> "/input/fileupload.html")
      upload_file = Path.join(tmp_dir, "200MB.zip")
      write_200mb(upload_file)
      input = Page.locator(page, ~s(input[type="file"]))

      events =
        Locator.evaluate_handle!(input, """
        e => {
          const events = [];
          e.addEventListener('input', () => events.push('input'));
          e.addEventListener('change', () => events.push('change'));
          return events;
        }
        """)

      Locator.set_input_files!(input, upload_file)
      assert Locator.evaluate!(input, "e => e.files[0].name") == "200MB.zip"
      assert JSHandle.evaluate!(events, "e => e") == ["input", "change"]

      test = self()

      TestServer.set_route(server, "/upload", fn conn ->
        send(test, {:files, parse_multipart(conn)})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      Page.click!(page, "input[type=submit]")
      assert_receive {:files, %{"file1" => file1}}, 60_000
      assert file1.original_filename == "200MB.zip"
      assert file1.size == 200 * 1024 * 1024
    end

    @tag :tmp_dir
    test "should upload a folder", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind,
      tmp_dir: tmp_dir
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)

      Page.goto!(page, server.prefix <> "/input/folderupload.html")
      input = Page.query_selector!(page, "input")
      folder_name = "folder-upload-test"
      dir = Path.join(tmp_dir, folder_name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "file1.txt"), "file1 content")
      File.write!(Path.join(dir, "file2"), "file2 content")
      File.mkdir!(Path.join(dir, "sub-dir"))
      File.write!(Path.join([dir, "sub-dir", "really.txt"]), "sub-dir file content")
      ElementHandle.set_input_files!(input, dir)

      webkit_relative_paths = Page.evaluate!(page, "e => [...e.files].map(f => f.webkitRelativePath)", input)

      assert MapSet.new(webkit_relative_paths) ==
               MapSet.new(["#{folder_name}/file1.txt", "#{folder_name}/file2", "#{folder_name}/sub-dir/really.txt"])

      for {webkit_relative_path, i} <- Enum.with_index(webkit_relative_paths) do
        content =
          JSHandle.evaluate!(
            input,
            """
            (e, i) => {
              const reader = new FileReader();
              const promise = new Promise(fulfill => reader.onload = fulfill);
              reader.readAsText(e.files[i]);
              return promise.then(() => reader.result);
            }
            """,
            i
          )

        assert content == File.read!(Path.join([dir, "..", webkit_relative_path]))
      end
    end

    test "setInputFiles should preserve lastModified timestamp", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      asset: asset,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server))
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)

      Page.set_content!(page, "<input type=file multiple=true/>")
      input = Page.locator(page, "input")
      files = ["file-to-upload.txt", "file-to-upload-2.txt"]
      Locator.set_input_files!(input, Enum.map(files, asset))
      assert Locator.evaluate!(input, "e => [...e.files].map(f => f.name)") == files
      timestamps = Locator.evaluate!(input, "e => [...e.files].map(f => f.lastModified)")
      expected_timestamps = Enum.map(files, fn file -> File.stat!(asset.(file), time: :posix).mtime * 1000 end)
      # On Linux browser sometimes reduces the timestamp by 1ms: 1696272058110.0715  -> 1696272058109 or even
      # rounds it to seconds in WebKit: 1696272058110 -> 1696272058000.
      for {timestamp, expected} <- Enum.zip(timestamps, expected_timestamps),
          do: assert(abs(timestamp - expected) <= 1000)
    end

    test "should connect over http", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      remote_server = start_remote_server.(kind, %{})

      url = URI.parse(RunServer.ws_endpoint(remote_server))
      browser = connect!(browser_type, "http://localhost:#{url.port}")
      assert Browser.version(browser)
      Browser.close!(browser)
    end

    # test.describe('socks proxy'): ExUnit has no nested describe.

    test "should forward non-forwarded requests", %{
      server: server,
      start_remote_server: start_remote_server,
      browser_type: browser_type,
      kind: kind
    } do
      reached_route(server, "/foo.html", "<html><body>original-target</body></html>")
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server), expose_network: "*")
      page = Browser.new_page!(browser)
      Page.goto!(page, server.prefix <> "/foo.html")
      assert Page.content!(page) =~ "original-target"
      assert_received :reached_original_target
    end

    test "should proxy localhost requests @smoke", %{
      start_remote_server: start_remote_server,
      server: server,
      browser_name: browser_name,
      browser_type: browser_type,
      kind: kind
    } do
      # test.skip(browserName === 'webkit' && platform === 'darwin', 'no localhost proxying');
      if not (browser_name == "webkit" and match?({:unix, :darwin}, :os.type())) do
        dummy_server_port = dummy_server_port()
        reached_route(server, "/foo.html", "<html><body></body></html>")
        example_port = free_port()
        remote_server = start_remote_server.(kind, %{})

        browser =
          connect!(browser_type, RunServer.ws_endpoint(remote_server), [expose_network: "*"],
            redirect_port_for_test: dummy_server_port
          )

        page = Browser.new_page!(browser)
        Page.set_content!(page, "empty")
        Page.goto!(page, "http://127.0.0.1:#{example_port}/foo.html")
        assert Page.content!(page) =~ "from-dummy-server"
        refute_received :reached_original_target

        Page.set_content!(page, "empty")
        Page.goto!(page, "http://localhost:#{example_port}/foo.html")
        assert Page.content!(page) =~ "from-dummy-server"
        refute_received :reached_original_target

        assert {:error, _} = Page.goto(page, "http://[::1]:#{example_port}/foo.html")
        refute_received :reached_original_target
      end
    end

    test "should proxy ipv6 localhost requests @smoke", %{
      start_remote_server: start_remote_server,
      server: server,
      browser_name: browser_name,
      browser_type: browser_type,
      kind: kind
    } do
      if not (browser_name == "webkit" and match?({:unix, :darwin}, :os.type())) do
        ipv6_server_port = ipv6_server_port()
        reached_route(server, "/foo.html", "<html><body></body></html>")
        example_port = free_port()
        remote_server = start_remote_server.(kind, %{})

        browser =
          connect!(browser_type, RunServer.ws_endpoint(remote_server), [expose_network: "*"],
            redirect_port_for_test: ipv6_server_port
          )

        page = Browser.new_page!(browser)
        Page.set_content!(page, "empty")
        Page.goto!(page, "http://[::1]:#{example_port}/foo.html")
        assert Page.content!(page) =~ "from-ipv6-server"
        refute_received :reached_original_target

        Page.set_content!(page, "empty")
        Page.goto!(page, "http://localhost:#{example_port}/foo.html")
        assert Page.content!(page) =~ "from-ipv6-server"
        refute_received :reached_original_target

        assert {:error, _} = Page.goto(page, "http://127.0.0.1:#{example_port}/foo.html")
        refute_received :reached_original_target
      end
    end

    test "should proxy requests from fetch api", %{
      start_remote_server: start_remote_server,
      server: server,
      browser_name: browser_name,
      browser_type: browser_type,
      kind: kind
    } do
      if not (browser_name == "webkit" and match?({:unix, :darwin}, :os.type())) do
        dummy_server_port = dummy_server_port()
        reached_route(server, "/foo.html", "<html><body></body></html>")
        example_port = free_port()
        remote_server = start_remote_server.(kind, %{})

        browser =
          connect!(browser_type, RunServer.ws_endpoint(remote_server), [expose_network: "*"],
            redirect_port_for_test: dummy_server_port
          )

        page = Browser.new_page!(browser)

        response = APIRequestContext.get!(Page.request(page), "http://localhost:#{example_port}/foo.html")
        assert APIResponse.status(response) == 200
        assert APIResponse.text!(response) =~ "from-dummy-server"
        refute_received :reached_original_target

        response = APIRequestContext.get!(Page.request(page), "http://127.0.0.1:#{example_port}/foo.html")
        assert APIResponse.status(response) == 200
        assert APIResponse.text!(response) =~ "from-dummy-server"
        refute_received :reached_original_target

        assert {:error, _} = APIRequestContext.get(Page.request(page), "http://[::1]:#{example_port}/foo.html")
        refute_received :reached_original_target
      end
    end

    test "should proxy requests from fetch api over ipv6", %{
      start_remote_server: start_remote_server,
      server: server,
      browser_name: browser_name,
      browser_type: browser_type,
      kind: kind
    } do
      if not (browser_name == "webkit" and match?({:unix, :darwin}, :os.type())) do
        ipv6_server_port = ipv6_server_port()
        reached_route(server, "/foo.html", "<html><body></body></html>")
        example_port = free_port()
        remote_server = start_remote_server.(kind, %{})

        browser =
          connect!(browser_type, RunServer.ws_endpoint(remote_server), [expose_network: "*"],
            redirect_port_for_test: ipv6_server_port
          )

        page = Browser.new_page!(browser)

        response = APIRequestContext.get!(Page.request(page), "http://localhost:#{example_port}/foo.html")
        assert APIResponse.status(response) == 200
        assert APIResponse.text!(response) =~ "from-ipv6-server"
        refute_received :reached_original_target

        response = APIRequestContext.get!(Page.request(page), "http://[::1]:#{example_port}/foo.html")
        assert APIResponse.status(response) == 200
        assert APIResponse.text!(response) =~ "from-ipv6-server"
        refute_received :reached_original_target

        assert {:error, _} = APIRequestContext.get(Page.request(page), "http://127.0.0.1:#{example_port}/foo.html")
        refute_received :reached_original_target
      end
    end

    test "should proxy local.playwright requests", %{
      browser_type: browser_type,
      server: server,
      start_remote_server: start_remote_server,
      kind: kind
    } do
      dummy_server_port = dummy_server_port()
      reached_route(server, "/foo.html", "<html><body></body></html>")
      example_port = free_port()
      remote_server = start_remote_server.(kind, %{})

      browser =
        connect!(browser_type, RunServer.ws_endpoint(remote_server), [expose_network: "*"],
          redirect_port_for_test: dummy_server_port
        )

      page = Browser.new_page!(browser)
      Page.goto!(page, "http://local.playwright:#{example_port}/foo.html")
      assert Page.content!(page) =~ "from-dummy-server"
      refute_received :reached_original_target
    end

    test "should lead to the error page for forwarded requests when the connection is refused", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      browser_name: browser_name,
      kind: kind
    } do
      example_port = free_port()
      remote_server = start_remote_server.(kind, %{})
      browser = connect!(browser_type, RunServer.ws_endpoint(remote_server), expose_network: "*")
      page = Browser.new_page!(browser)
      {:error, error} = Page.goto(page, "http://127.0.0.1:#{example_port}")
      message = Exception.message(error)

      case browser_name do
        # `at http://127.0.0.1:20`: upstream's port is 20_000 + workerIndex * 3.
        "chromium" ->
          assert message =~ "net::ERR_SOCKS_CONNECTION_FAILED at http://127.0.0.1:#{example_port}"

        "webkit" ->
          assert message

        "firefox" ->
          assert message =~ "NS_ERROR_NET_RESET" or message =~ "NS_ERROR_CONNECTION_REFUSED"
      end
    end

    test "should proxy based on the pattern", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      browser_name: browser_name,
      kind: kind
    } do
      if not (browser_name == "webkit" and match?({:unix, :darwin}, :os.type())) do
        dummy_server_port = dummy_server_port()
        reached_route(server, "/foo.html", "<html><body>from-original-server</body></html>")
        example_port = free_port()
        remote_server = start_remote_server.(kind, %{})

        browser =
          connect!(browser_type, RunServer.ws_endpoint(remote_server), [expose_network: "localhost"],
            redirect_port_for_test: dummy_server_port
          )

        page = Browser.new_page!(browser)

        # localhost should be proxied.
        Page.goto!(page, "http://localhost:#{example_port}/foo.html")
        assert Page.content!(page) =~ "from-dummy-server"
        refute_received :reached_original_target

        # 127.0.0.1 should be served directly.
        Page.goto!(page, "http://127.0.0.1:#{server.port}/foo.html")
        assert Page.content!(page) =~ "from-original-server"
        assert_received :reached_original_target

        # Random domain should be served directly and fail.
        assert {:error, _} = Page.goto(page, "http://does-not-exist-bad-domain.oh-no-should-not-work")
      end
    end

    test "should check proxy pattern on the client", %{
      browser_type: browser_type,
      start_remote_server: start_remote_server,
      server: server,
      kind: kind
    } do
      dummy_server_port = dummy_server_port()
      reached_route(server, "/foo.html", "<html><body>from-original-server</body></html>")
      remote_server = start_remote_server.(kind, %{})

      browser =
        connect!(
          browser_type,
          RunServer.ws_endpoint(remote_server),
          [expose_network: "127.0.0.1", headers: %{"x-playwright-proxy" => "*"}],
          redirect_port_for_test: dummy_server_port
        )

      page = Browser.new_page!(browser)

      # local.playwright should fail on the client side.
      assert {:error, _} = Page.goto(page, "http://local.playwright:#{server.port}/foo.html")
      refute_received :reached_original_target
    end
  end

  describe "launchServer only" do
    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should work with cluster"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should properly disconnect when connection closes from the server side"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "should be able to reconnect to a browser 12 times without warnings"

    @tag skip: "not ported: launchServer (PLAN: out of scope)"
    test "cannot launch another browser"
  end

  test "should refuse connecting when versions do not match", %{browser_type: browser_type} do
    server = RunServer.start(%{mode: "default", env: %{"PW_VERSION_OVERRIDE" => "1.2.3"}})
    {:error, error} = connect(browser_type, RunServer.ws_endpoint(server))
    RunServer.close(server)
    assert Exception.message(error) =~ "Playwright version mismatch"
    assert Exception.message(error) =~ "server version: v1.2"
    [major, minor | _] = String.split(PlaywrightEx.Driver.version(), ".")
    assert Exception.message(error) =~ "client version: v#{major}.#{minor}"
  end

  # https://github.com/microsoft/playwright/issues/42394
  @tag :tmp_dir
  test "should filter local paths from unsafe launch options", %{
    playwright: playwright,
    browser_type: browser_type,
    start_remote_server: start_remote_server,
    server: server,
    tmp_dir: tmp_dir
  } do
    download_route(server)
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    downloads_path = Path.join(tmp_dir, "downloads")
    File.write!(artifacts_dir, "not a directory")
    File.write!(downloads_path, "not a directory")
    remote_server = start_remote_server.("run-server", %{unsafe: true, env: %{"PWTEST_UNDER_TEST" => nil}})

    browser =
      connect!(browser_type, RunServer.ws_endpoint(remote_server), [],
        launch_options: %{artifactsDir: artifacts_dir, downloadsPath: downloads_path}
      )

    context = Browser.new_context!(browser)
    Tracing.start!(BrowserContext.tracing(context), snapshots: true)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
    download = Page.wait_for_event(page, :download)
    Page.click!(page, "a")
    download = Promise.await!(download)
    assert Download.failure!(download) == nil
    trace_path = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(BrowserContext.tracing(context), path: trace_path)
    BrowserContext.close!(context)
    Browser.close!(browser)

    %{actions: actions} = parse_trace_raw(trace_path, playwright)
    assert "Set content" in actions
  end

  test "should timeout after redirect when connecting over http", %{browser_type: browser_type, server: server} do
    TestServer.set_redirect(server, "/connect/json", "/connect/slow")
    test = self()

    TestServer.set_route(server, "/connect/slow", fn conn ->
      # `req.socket.on('close', () => aborted = true)`
      wait_for_close(conn, fn -> send(test, :aborted) end)
    end)

    {:error, error} =
      connect(browser_type, "#{server.prefix}/connect", timeout: 2000, headers: %{"Connection" => "Close"})

    assert Exception.message(error) =~ "Timeout 2000ms exceeded."
    assert_receive :aborted, 5000
  end
end
