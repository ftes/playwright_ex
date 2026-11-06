defmodule PlaywrightEx.Guides.NetworkTest do
  # The snippets of `guides/network.md`, against `PlaywrightEx.TestServer`.
  use ExUnit.Case, async: true

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.TestServer

  @moduletag :tmp_dir

  @home """
  <title>Home</title>
  <button onclick="fetch('/api/users')">Reload</button>
  """

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    dir = Path.join(System.tmp_dir!(), "guide-network-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    server = TestServer.server(start_supervised!({TestServer, dir_path: dir}))
    TestServer.set_content(server, "/", @home, "text/html")
    browser = PlaywrightEx.playwright(__MODULE__) |> TestBrowser.browser_type() |> BrowserType.launch!()
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
    BrowserContext.route!(context, &String.ends_with?(&1, "/api/users"), &Route.fulfill(&1, json: "context"))
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

  test "API testing", %{server: server, base_url: base_url} do
    token = "secret"

    TestServer.set_route(server, "/api/issues", fn conn ->
      ["Bearer secret"] = Plug.Conn.get_req_header(conn, "authorization")
      json(conn, JSON.decode!(conn.assigns.post_body))
    end)

    request =
      PlaywrightEx.playwright(__MODULE__)
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
