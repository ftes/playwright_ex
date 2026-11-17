defmodule Playwright.Guides.NetworkTest do
  # The snippets of `guides/network.md`, against `Playwright.TestServer`.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.APIResponse
  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.BrowserType
  alias Playwright.Expect
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Request
  alias Playwright.Response
  alias Playwright.Route
  alias Playwright.TestBrowser
  alias Playwright.TestServer
  alias Playwright.Tracing
  alias Playwright.Utils
  alias Playwright.WebSocket
  alias Playwright.WebSocketRoute

  require Logger

  @moduletag :tmp_dir

  @home """
  <title>Home</title>
  <button onclick="fetch('/api/users')">Reload</button>
  """

  setup_all do
    start_supervised!({Playwright.Supervisor, name: __MODULE__})
    dir = Path.join(System.tmp_dir!(), "guide-network-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    server = TestServer.server(start_supervised!({TestServer, dir_path: dir}))
    TestServer.set_content(server, "/", @home, "text/html")
    browser = Playwright.instance(__MODULE__) |> TestBrowser.browser_type() |> BrowserType.launch!()
    %{browser: browser, server: server, base_url: server.prefix}
  end

  setup %{browser: browser, server: server, base_url: base_url} do
    TestServer.set_route(server, "/api/users", &json(&1, [%{name: "Ada"}]))
    context = Browser.new_context!(browser, base_url: base_url)
    BrowserContext.set_default_timeout(context, 5_000)
    on_exit(fn -> BrowserContext.close(context) end)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    %{context: context, page: page}
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.send_resp(200, JSON.encode!(body))
  end

  defp fetch_json(page, url, method \\ "GET") do
    Page.evaluate!(page, "([url, method]) => fetch(url, { method }).then(r => r.json())", [url, method])
  end

  test "fulfill and abort", %{page: page} do
    Page.route!(page, "**/api/users", &Route.fulfill(&1, json: [%{name: "Grace"}]))
    Page.route!(page, "**/*.{png,jpg}", &Route.abort/1)

    assert fetch_json(page, "/api/users") == [%{"name" => "Grace"}]
    assert {:error, _} = Page.evaluate(page, "() => fetch('/logo.png')")
  end

  test "a handler with the request", %{page: page, server: server} do
    TestServer.set_route(server, "/api/echo", &json(&1, %{header: Plug.Conn.get_req_header(&1, "x-test")}))

    Page.route!(page, "**/api/**", fn route, request ->
      case Request.method(request) do
        "DELETE" -> Route.fulfill(route, status: 403, json: %{error: "forbidden"})
        _ -> Route.continue(route, headers: Map.put(Request.headers(request), "x-test", "1"))
      end
    end)

    assert fetch_json(page, "/api/users/1", "DELETE") == %{"error" => "forbidden"}
    assert fetch_json(page, "/api/echo") == %{"header" => ["1"]}
  end

  test "change a real response", %{page: page} do
    Page.route!(page, "**/api/users", fn route ->
      response = Route.fetch!(route)
      users = APIResponse.json!(response)
      Route.fulfill(route, response: response, json: users ++ [%{name: "Grace"}])
    end)

    assert fetch_json(page, "/api/users") == [%{"name" => "Ada"}, %{"name" => "Grace"}]
  end

  test "patterns, fallback, times, unroute", %{page: page} do
    Page.route!(page, "/api/users", &Route.fulfill(&1, json: "first"))
    Page.route!(page, "/api/users", &Route.fallback/1)
    assert fetch_json(page, "/api/users") == "first"

    Page.route!(page, ~r"/api/users$", &Route.fulfill(&1, json: "once"), times: 1)
    assert fetch_json(page, "/api/users") == "once"
    assert fetch_json(page, "/api/users") == "first"

    Page.unroute!(page, "/api/users")
    assert fetch_json(page, "/api/users") == [%{"name" => "Ada"}]
  end

  test "context routes", %{context: context} do
    BrowserContext.route!(context, &(&1.path == "/api/users"), &Route.fulfill(&1, json: "context"))
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    assert fetch_json(page, "/api/users") == "context"
  end

  test "replaying a HAR", %{browser: browser, base_url: base_url, server: server, tmp_dir: tmp_dir} do
    har = Path.join(tmp_dir, "api.har")

    context = Browser.new_context!(browser, base_url: base_url)
    BrowserContext.route_from_har!(context, har, url: "**/api/**", update: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    assert fetch_json(page, "/api/users") == [%{"name" => "Ada"}]
    BrowserContext.close!(context)

    # The backend changed; the HAR still answers as recorded.
    TestServer.set_route(server, "/api/users", &json(&1, [%{name: "Changed"}]))
    context = Browser.new_context!(browser, base_url: base_url)
    BrowserContext.route_from_har!(context, har, url: "**/api/**")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    assert fetch_json(page, "/api/users") == [%{"name" => "Ada"}]
    assert {:error, _} = Page.evaluate(page, "() => fetch('/api/missing')")

    BrowserContext.close!(context)

    context = Browser.new_context!(browser, base_url: base_url)
    BrowserContext.route_from_har!(context, har, url: "**/api/**", not_found: :fallback)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    assert fetch_json(page, "/api/users") == [%{"name" => "Ada"}]
    assert Page.evaluate!(page, "() => fetch('/api/missing').then(r => r.status)") == 404
    BrowserContext.close!(context)
  end

  test "waiting for requests and responses", %{page: page} do
    response =
      Page.expect_response!(page, "**/api/users", fn ->
        Page.get_by_role(page, :button, name: "Reload") |> Locator.click!()
      end)

    assert Response.status(response) == 200
    assert [%{"name" => _} | _] = Response.json!(response)

    request =
      Page.expect_request!(page, "**/api/users", fn ->
        Page.get_by_role(page, :button, name: "Reload") |> Locator.click!()
      end)

    assert Request.method(request) == "GET"

    response =
      Page.expect_response!(page, &(Response.url(&1) =~ "/api/" and Response.status(&1) >= 400), fn ->
        Page.evaluate!(page, "() => fetch('/api/nope')")
      end)

    assert Response.status(response) == 404
  end

  # A page's socket to the server's `/ws` that logs the frames it gets.
  defp open_web_socket(page) do
    Page.evaluate!(page, """
    () => {
      window.log = [];
      window.ws = new WebSocket('ws://' + location.host + '/ws');
      window.ws.addEventListener('message', event => window.log.push(event.data));
      return new Promise(f => window.ws.addEventListener('open', f));
    }
    """)
  end

  test "WebSockets: delay the server's frames, watch them on the wire", %{
    context: context,
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    tracing = BrowserContext.tracing(context)
    # The network log needs the snapshots (upstream's `tracing.ts` starts its `HarTracer` with them).
    Tracing.start!(tracing, snapshots: true)

    Page.route_web_socket!(page, "**/ws", fn ws ->
      server = WebSocketRoute.connect_to_server(ws)

      WebSocketRoute.on_message(server, fn message ->
        Task.start(fn ->
          Process.sleep(500)
          WebSocketRoute.send(ws, message)
        end)
      end)
    end)

    test_pid = self()

    log =
      capture_log(fn ->
        Page.on(page, :web_socket, fn ws ->
          Logger.info("WebSocket opened: #{WebSocket.url(ws)}")
          WebSocket.on(ws, :frame_sent, &Logger.info("sent: #{inspect(&1.payload)}"))
          WebSocket.on(ws, :frame_received, &Logger.info("received: #{inspect(&1.payload)}"))
          WebSocket.on(ws, :close, fn _ -> Logger.info("WebSocket closed") end)
        end)

        # What the page has as the frame comes over the wire: the handler holds it back.
        Page.on(page, :web_socket, fn ws ->
          WebSocket.on(ws, :frame_received, fn %{payload: "hello"} ->
            send(test_pid, {:on_the_wire, Page.evaluate!(page, "() => window.log")})
          end)

          WebSocket.on(ws, :close, fn _ -> send(test_pid, :closed) end)
        end)

        Page.goto!(page, "/")
        server_ws = TestServer.wait_for_web_socket(server)
        open_web_socket(page)
        server_ws = Task.await(server_ws)

        sent = System.monotonic_time(:millisecond)
        TestServer.WebSocket.send(server_ws, "hello")
        assert_receive {:on_the_wire, []}, 5000
        Expect.poll!(fn -> Page.evaluate!(page, "() => window.log") end, &assert(&1 == ["hello"]))
        assert System.monotonic_time(:millisecond) - sent >= 500

        # The page's frames go on to the server, unhandled.
        TestServer.WebSocket.once(server_ws, :message, &send(test_pid, {:message, &1}))
        Page.evaluate!(page, "() => window.ws.send('hi')")
        assert_receive {:message, "hi"}, 5000

        Page.evaluate!(page, "() => window.ws.close()")
        assert_receive :closed, 5000
        Tracing.stop!(tracing, path: Path.join(tmp_dir, "trace.zip"))
        # No listener logs after the capture.
        BrowserContext.close!(context)
        Logger.flush()
      end)

    assert log =~ "WebSocket opened: ws://#{server.host}/ws"
    assert log =~ ~s(received: "hello")
    assert log =~ ~s(sent: "hi")

    # The socket in the network log, its frames in a resource.
    %{events: events, resources: resources} = Utils.parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    assert [socket] = web_sockets(events)
    assert socket["request"]["url"] == "ws://#{server.host}/ws"
    frames = resources[socket["response"]["content"]["_file"]]
    frames = for line <- String.split(frames, "\n", trim: true), do: JSON.decode!(line)
    assert %{"type" => "receive", "data" => "hello"} in Enum.map(frames, &Map.take(&1, ["type", "data"]))
    assert %{"type" => "send", "data" => "hi"} in Enum.map(frames, &Map.take(&1, ["type", "data"]))
  end

  test "WebSockets: a socket mocked without connect_to_server never reaches the wire", %{
    context: context,
    page: page,
    tmp_dir: tmp_dir
  } do
    tracing = BrowserContext.tracing(context)
    # The network log needs the snapshots (upstream's `tracing.ts` starts its `HarTracer` with them).
    Tracing.start!(tracing, snapshots: true)
    test_pid = self()
    Page.on(page, :web_socket, &send(test_pid, {:web_socket, &1}))

    Page.route_web_socket!(page, "**/ws", fn ws ->
      WebSocketRoute.on_message(ws, fn "ping" -> WebSocketRoute.send(ws, "pong") end)
    end)

    Page.goto!(page, "/")
    open_web_socket(page)
    Page.evaluate!(page, "() => window.ws.send('ping')")
    Expect.poll!(fn -> Page.evaluate!(page, "() => window.log") end, &assert(&1 == ["pong"]))

    Tracing.stop!(tracing, path: Path.join(tmp_dir, "trace.zip"))
    # After the stop's round trip: the page's events came before its reply.
    refute_received {:web_socket, _}
    %{events: events} = Utils.parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    assert web_sockets(events) == []
  end

  # The trace's network entries of WebSockets.
  defp web_sockets(events) do
    for %{"type" => "resource-snapshot", "snapshot" => %{"_resourceType" => "websocket"} = entry} <- events, do: entry
  end

  test "API testing", %{server: server, base_url: base_url} do
    token = "secret"

    TestServer.set_route(server, "/api/issues", fn conn ->
      ["Bearer secret"] = Plug.Conn.get_req_header(conn, "authorization")
      json(conn, JSON.decode!(conn.assigns.post_body))
    end)

    request =
      Playwright.instance(__MODULE__)
      |> Playwright.request()
      |> APIRequest.new_context!(
        base_url: base_url,
        extra_http_headers: %{"authorization" => "Bearer #{token}"}
      )

    response = APIRequestContext.post!(request, "/api/issues", data: %{title: "Broken link"})
    Expect.to_be_ok!(response)
    assert %{"title" => "Broken link"} = APIResponse.json!(response)

    APIRequestContext.dispose!(request)
  end

  test "the context's request shares cookies", %{context: context, page: page, server: server} do
    TestServer.set_route(server, "/api/login", fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", "session=ada; Path=/") |> json(%{})
    end)

    APIRequestContext.post!(BrowserContext.request(context), "/api/login")
    assert Page.evaluate!(page, "document.cookie") == "session=ada"
    assert Page.request(page) == BrowserContext.request(context)
  end
end
