defmodule PlaywrightEx.Page.PageRequestFulfillTest do
  @upstream "tests/page/page-request-fulfill.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  # rewriteAndroidLoopbackURL  -- not ported: no Android

  test "should work", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      Route.fulfill(route, status: 201, headers: %{"foo" => "bar"}, content_type: "text/html", body: "Yo, page!")
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 201
    assert Response.headers(response)["foo"] == "bar"
    assert Page.evaluate!(page, "() => document.body.textContent") == "Yo, page!"
  end

  test "should work with buffer as body", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      Route.fulfill(route, status: 200, content_type: "text/plain", body: {:binary, "Yo, page!"})
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    assert Page.evaluate!(page, "() => document.body.textContent") == "Yo, page!"
  end

  test "should work with status code 422", %{page: page, server: server} do
    Page.route!(page, "**/*", &Route.fulfill(&1, status: 422, body: "Yo, page!"))
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 422
    assert Response.status_text(response) == "Unprocessable Entity"
    assert Page.evaluate!(page, "() => document.body.textContent") == "Yo, page!"
  end

  test "should fulfill with unuassigned status codes", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/data.json", fn route ->
      case Route.fulfill(route, status: 430, body: "Yo, page!") do
        :ok -> send(me, {:fulfill, nil})
        {:error, e} -> send(me, {:fulfill, e})
      end
    end)

    Page.goto!(page, server.empty_page)

    response =
      Page.evaluate!(
        page,
        """
        async url => {
          const { status, statusText } = await fetch(url);
          return { status, statusText };
        }
        """,
        server.prefix <> "/data.json"
      )

    assert_receive {:fulfill, error}, 5000
    assert error == nil
    assert response["status"] == 430
    assert response["statusText"] == "Unknown"
  end

  test "should not throw if request was cancelled by the page", %{page: page, server: server} do
    me = self()
    Page.route!(page, "**/data.json", fn route -> send(me, {:route, route}) end)
    Page.goto!(page, server.empty_page)

    fetch =
      Task.async(fn ->
        Page.evaluate(
          page,
          """
          url => {
            globalThis.controller = new AbortController();
            return fetch(url, { signal: globalThis.controller.signal });
          }
          """,
          server.prefix <> "/data.json"
        )
      end)

    assert_receive {:route, route}, 5000
    failure_promise = Page.wait_for_event(page, :request_failed)
    Page.evaluate!(page, "() => globalThis.controller.abort()")
    cancelled_request = Promise.await!(failure_promise)
    assert Request.failure(cancelled_request)
    assert Request.failure(cancelled_request).errorText =~ ~r/cancelled|aborted/i
    # Should not throw.
    Route.fulfill!(route, status: 200)
    Task.await(fetch)
  end

  @tag skip: "not ported: toMatchSnapshot"
  test "should allow mocking binary responses"

  @tag skip: "not ported: toMatchSnapshot"
  test "should allow mocking svg with charset"

  @tag skip: "not ported: toMatchSnapshot"
  test "should work with file path"

  test "should stringify intercepted request response headers", %{page: page, server: server} do
    Page.route!(page, "**/*", &Route.fulfill(&1, status: 200, headers: %{"foo" => "true"}, body: "Yo, page!"))
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    headers = Response.headers(response)
    assert headers["foo"] == "true"
    assert Page.evaluate!(page, "() => document.body.textContent") == "Yo, page!"
  end

  test "should not modify the headers sent to the server", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")
    me = self()

    # this is just to enable request interception, which disables caching in chromium
    Page.route!(page, server.prefix <> "/unused", fn _route -> nil end)

    TestServer.set_route(server, "/something", fn conn ->
      send(me, {:intercepted_request, conn})
      conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(200, "done")
    end)

    fetch = """
    async url => {
      const data = await fetch(url);
      return data.text();
    }
    """

    text = Page.evaluate!(page, fetch, server.cross_process_prefix <> "/something")
    assert text == "done"

    Page.route!(page, server.cross_process_prefix <> "/something", fn route, request ->
      Route.continue(route, headers: Request.headers(request))
    end)

    text_after_route = Page.evaluate!(page, fetch, server.cross_process_prefix <> "/something")
    assert text_after_route == "done"

    assert_received {:intercepted_request, first}
    assert_received {:intercepted_request, second}
    refute_received {:intercepted_request, _}
    assert Enum.sort(second.req_headers) == Enum.sort(first.req_headers)
  end

  test "should include the origin header", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")
    me = self()

    Page.route!(page, server.cross_process_prefix <> "/something", fn route, request ->
      send(me, {:intercepted_request, request})

      Route.fulfill(route,
        headers: %{"Access-Control-Allow-Origin" => "*"},
        content_type: "text/plain",
        body: "done"
      )
    end)

    text =
      Page.evaluate!(
        page,
        """
        async url => {
          const data = await fetch(url);
          return data.text();
        }
        """,
        server.cross_process_prefix <> "/something"
      )

    assert text == "done"
    assert_received {:intercepted_request, intercepted_request}
    assert Request.headers(intercepted_request)["origin"] == server.prefix
  end

  test "should fulfill with global fetch result", %{playwright: playwright, page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      request = APIRequest.new_context!(Playwright.request(playwright))
      response = APIRequestContext.get!(request, server.prefix <> "/simple.json")
      Route.fulfill(route, response: response)
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    assert Response.json!(response) == %{"foo" => "bar"}
  end

  test "should fulfill with fetch result", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      response = APIRequestContext.get!(Page.request(page), server.prefix <> "/simple.json")
      Route.fulfill(route, response: response)
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    assert Response.json!(response) == %{"foo" => "bar"}
  end

  test "should fulfill with fetch result and overrides", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      response = APIRequestContext.get!(Page.request(page), server.prefix <> "/simple.json")

      Route.fulfill(route,
        response: response,
        status: 201,
        headers: %{
          # Case matters for the tested behavior
          "Content-Type" => "application/json",
          "foo" => "bar"
        }
      )
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 201
    assert Response.all_headers!(response)["foo"] == "bar"
    assert Response.json!(response) == %{"foo" => "bar"}
  end

  test "should fetch original request and fulfill", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      response = APIRequestContext.fetch!(Page.request(page), Route.request(route))
      Route.fulfill(route, response: response)
    end)

    response = Page.goto!(page, server.prefix <> "/title.html")
    assert Response.status(response) == 200
    assert Page.title!(page) == "Woof-Woof"
  end

  test "should fulfill with multiple set-cookie", %{page: page, server: server} do
    cookies = ["a=b", "c=d"]

    Page.route!(page, "**/multiple-set-cookie.html", fn route ->
      Route.fulfill(route,
        status: 200,
        headers: %{"X-Header-1" => "v1", "Set-Cookie" => Enum.join(cookies, "\n"), "X-Header-2" => "v2"},
        body: ""
      )
    end)

    response = Page.goto!(page, server.prefix <> "/multiple-set-cookie.html")
    cookie = Page.evaluate!(page, "() => document.cookie")
    assert cookie |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.sort() == cookies
    assert Response.header_value!(response, "X-Header-1") == "v1"
    assert Response.header_value!(response, "X-Header-2") == "v2"
  end

  test "should fulfill with fetch response that has multiple set-cookie", %{
    playwright: playwright,
    page: page,
    server: server
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.prepend_resp_headers([{"set-cookie", "a=b"}, {"set-cookie", "c=d"}])
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.route!(page, "**/empty.html", fn route ->
      request = APIRequest.new_context!(Playwright.request(playwright))
      response = APIRequestContext.fetch!(request, Route.request(route))
      Route.fulfill(route, response: response)
    end)

    Page.goto!(page, server.empty_page)
    cookie = Page.evaluate!(page, "() => document.cookie")
    assert cookie |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.sort() == ["a=b", "c=d"]
  end

  test "headerValue should return set-cookie from intercepted response", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    if browser_name != "webkit" do
      Page.route!(page, "**/empty.html", &Route.fulfill(&1, status: 200, headers: %{"Set-Cookie" => "a=b"}, body: ""))
      response = Page.goto!(page, server.empty_page)

      # it.fail(browserName === 'chromium', 'Set-Cookie is missing in response after interception')
      if browser_name == "chromium",
        do: refute(Response.header_value!(response, "Set-Cookie") == "a=b"),
        else: assert(Response.header_value!(response, "Set-Cookie") == "a=b")
    end
  end

  test "should fulfill with har response", %{page: page, asset: asset} do
    har_path = asset.("har-fulfill.har")
    har = JSON.decode!(File.read!(har_path))

    Page.route!(page, "**/*", fn route ->
      response = find_response(har, Request.url(Route.request(route)))
      headers = Map.new(response["headers"], &{&1["name"], &1["value"]})
      text = response["content"]["text"] || ""

      Route.fulfill!(route,
        status: response["status"],
        headers: headers,
        body: if(response["content"]["encoding"] == "base64", do: Base.decode64!(text), else: text)
      )
    end)

    Page.goto!(page, "http://no.playwright/")
    # HAR contains a redirect for the script.
    assert Page.evaluate!(page, "window.value") == "foo"
    # HAR contains a POST for the css file but we match ignoring the method, so the file should be served.
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(0, 255, 255)")
  end

  defp find_response(har, url, entry \\ nil, original_url \\ nil)

  defp find_response(har, url, entry, original_url) do
    original_url = original_url || url

    if is_binary(url) and String.trim(url) != "" do
      entry = Enum.find(har["log"]["entries"], &(&1["request"]["url"] == url))
      find_response(har, entry && entry["response"]["redirectURL"], entry, original_url)
    else
      assert entry, original_url
      entry["response"]
    end
  end

  test "should fulfill preload link requests", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/one-style.css", fn route ->
      send(me, :intercepted)

      Route.fulfill(route,
        status: 200,
        headers: %{
          "content-type" => "text/css; charset=utf-8",
          "cache-control" => "no-cache, no-store",
          "custom" => "value"
        },
        body: "body { background-color: green; }"
      )
    end)

    response_promise = Page.wait_for_response(page, "**/one-style.css")
    Page.goto!(page, server.prefix <> "/preload.html")
    response = Promise.await!(response_promise)
    assert Response.header_value!(response, "custom") == "value"
    Page.wait_for_function!(page, "() => window.preloadedStyles")
    assert_received :intercepted
    color = Page.evaluate!(page, "() => window.getComputedStyle(document.body).backgroundColor")
    assert color == "rgb(0, 128, 0)"
  end

  test "should fulfill json", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/data.json", fn route ->
      Route.fulfill(route, status: 201, headers: %{"foo" => "bar"}, json: %{bar: "baz"})
    end)

    response_promise = Page.wait_for_response(page, "**/*")
    body = Page.evaluate!(page, "() => fetch('./data.json').then(r => r.text())")
    response = Promise.await!(response_promise)
    assert Response.status(response) == 201
    assert Response.headers(response)["content-type"] == "application/json"
    assert body == ~s({"bar":"baz"})
  end

  test "should fulfill with gzip and readback", %{page: page, server: server} do
    TestServer.enable_gzip(server, "/one-style.html")

    Page.route!(page, "**/one-style.html", fn route ->
      response = Route.fetch!(route)
      assert APIResponse.headers(response)["content-encoding"] == "gzip"
      Route.fulfill!(route, response: response)
    end)

    response = Page.goto!(page, server.prefix <> "/one-style.html")
    Expect.to_have_text!(Page.locator(page, "div"), "hello, world!")
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(255, 192, 203)")
    assert Response.text!(response) =~ "<div>hello, world!</div>"
  end

  test "should not go to the network for fulfilled requests body", %{page: page, server: server} do
    Page.route!(page, "**/one-style.css", fn route ->
      Route.fulfill(route, status: 404, content_type: "text/plain", body: "Not Found! (mocked)")
    end)

    me = self()

    TestServer.set_route(server, "/one-style.css", fn conn ->
      send(me, :server_hit)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.send_resp(200, "body { background-color: green; }")
    end)

    response_promise = Page.wait_for_response(page, "**/one-style.css")
    Page.goto!(page, server.prefix <> "/one-style.html")
    response = Promise.await!(response_promise)
    body = Response.body!(response)
    assert body == "Not Found! (mocked)"
    refute_received :server_hit
  end

  test "should return body for fulfilled responses", %{page: page, server: server} do
    for status <- [100, 200, 404, 500] do
      # it.step(`status ${status}`, ...)
      body_override = "Custom body #{status}"

      Page.route!(page, "**/one-style.css", fn route ->
        Route.fulfill(route, status: status, content_type: "text/plain", body: body_override)
      end)

      response_promise = Page.wait_for_response(page, "**/one-style.css")
      Page.goto!(page, server.prefix <> "/one-style.html")
      response = Promise.await!(response_promise)
      body = Response.body!(response)
      assert body == body_override, "status #{status}"
      Page.unroute_all!(page)
    end
  end
end
