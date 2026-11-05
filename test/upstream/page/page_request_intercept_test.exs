defmodule PlaywrightEx.Page.PageRequestInterceptTest do
  @upstream "tests/page/page-request-intercept.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  # rewriteAndroidLoopbackURL  -- not ported: no Android

  test "should fulfill intercepted response", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      response = APIRequestContext.fetch!(Page.request(page), Route.request(route))

      Route.fulfill!(route,
        response: response,
        status: 201,
        headers: %{"foo" => "bar"},
        content_type: "text/plain",
        body: "Yo, page!"
      )
    end)

    response = Page.goto!(page, server.prefix <> "/empty.html")
    assert Response.status(response) == 201
    assert Response.headers(response)["foo"] == "bar"
    assert Response.headers(response)["content-type"] == "text/plain"
    assert Page.evaluate!(page, "() => document.body.textContent") == "Yo, page!"
  end

  test "should fulfill response with empty body", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      response = APIRequestContext.fetch!(Page.request(page), Route.request(route))
      Route.fulfill!(route, response: response, headers: %{"content-length" => "0"}, status: 201, body: "")
    end)

    response = Page.goto!(page, server.prefix <> "/title.html")
    assert Response.status(response) == 201
    assert Response.text!(response) == ""
  end

  test "should override with defaults when intercepted response not provided", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn |> Plug.Conn.put_resp_header("foo", "bar") |> Plug.Conn.send_resp(200, "my content")
    end)

    Page.route!(page, "**/*", fn route ->
      APIRequestContext.fetch!(Page.request(page), Route.request(route))
      Route.fulfill!(route, status: 201)
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 201
    assert Response.text!(response) == ""

    if browser_name == "webkit",
      do: assert(Response.headers(response) == %{"content-type" => "text/plain"}),
      else: assert(Response.headers(response) == %{})
  end

  test "should fulfill with any response", %{page: page, server: server} do
    TestServer.set_route(server, "/sample", fn conn ->
      conn |> Plug.Conn.put_resp_header("foo", "bar") |> Plug.Conn.send_resp(200, "Woo-hoo")
    end)

    sample_response = APIRequestContext.get!(Page.request(page), "#{server.prefix}/sample")

    Page.route!(page, "**/*", fn route ->
      Route.fulfill!(route, response: sample_response, status: 201, content_type: "text/plain")
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 201
    assert Response.text!(response) == "Woo-hoo"
    assert Response.headers(response)["foo"] == "bar"
  end

  test "should support fulfill after intercept", %{page: page, server: server, asset: asset} do
    request_promise = TestServer.wait_for_request(server, "/title.html")

    Page.route!(page, "**", fn route ->
      response = APIRequestContext.fetch!(Page.request(page), Route.request(route))
      Route.fulfill!(route, response: response)
    end)

    response = Page.goto!(page, server.prefix <> "/title.html")
    request = Task.await(request_promise)
    assert request.request_path == "/title.html"
    original = File.read!(asset.("title.html"))
    assert Response.text!(response) == original
  end

  test "should give access to the intercepted response", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    me = self()
    Page.route!(page, "**/title.html", fn route -> send(me, {:route, route}) end)

    eval_promise = Task.async(fn -> Page.evaluate!(page, "url => fetch(url)", server.prefix <> "/title.html") end)

    assert_receive {:route, route}, 5000
    response = APIRequestContext.fetch!(Page.request(page), Route.request(route))

    assert APIResponse.status(response) == 200
    assert APIResponse.status_text(response) == "OK"
    assert APIResponse.ok(response)
    assert String.ends_with?(APIResponse.url(response), "/title.html")
    assert APIResponse.headers(response)["content-type"] == "text/html; charset=utf-8"

    # Plug sends lowercase header names (upstream: `Content-Type`).
    assert Enum.filter(APIResponse.headers_array(response), &(String.downcase(&1.name) == "content-type")) == [
             %{name: "content-type", value: "text/html; charset=utf-8"}
           ]

    Route.fulfill!(route, response: response)
    Task.await(eval_promise)
  end

  test "should give access to the intercepted response body", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    me = self()
    Page.route!(page, "**/simple.json", fn route -> send(me, {:route, route}) end)

    eval_promise = Task.async(fn -> Page.evaluate(page, "url => fetch(url)", server.prefix <> "/simple.json") end)

    assert_receive {:route, route}, 5000
    response = APIRequestContext.fetch!(Page.request(page), Route.request(route))

    assert APIResponse.text!(response) == ~s({"foo": "bar"}\n)

    Route.fulfill!(route, response: response)
    Task.await(eval_promise)
  end

  # it.fixme(browserName !== 'firefox')
  # issue: https://github.com/microsoft/playwright/issues/14624
  @tag skip: if(@browser_name != "firefox", do: "upstream fixme: not firefox (#14624)")
  test "should intercept multipart/form-data request body", %{page: page, server: server, asset: asset} do
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    file_path = Path.relative_to_cwd(asset.("file-to-upload.txt"))
    Locator.set_input_files!(Page.locator(page, "input[type=file]"), file_path)
    test = self()
    Page.route!(page, "**/upload", fn route -> send(test, {:request, Route.request(route)}) end)
    Page.click!(page, "input[type=submit]", no_wait_after: true)
    assert_receive {:request, request}
    assert Request.method(request) == "POST"
    assert Request.post_data(request) =~ File.read!(file_path)
  end

  test "should fulfill intercepted response using alias", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      response = Route.fetch!(route)
      Route.fulfill!(route, response: response)
    end)

    response = Page.goto!(page, server.prefix <> "/empty.html")
    assert Response.status(response) == 200
    assert Response.headers(response)["content-type"] =~ "text/html"
  end

  test "should support timeout option in route.fetch", %{page: page, server: server} do
    TestServer.set_route(server, "/slow", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-length", "4096")
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.send_chunked(200)

      # No body: the response never ends.
      Process.sleep(:infinity)
      conn
    end)

    me = self()

    Page.route!(page, "**/*", fn route ->
      {:error, error} = Route.fetch(route, timeout: 1000)
      send(me, {:fetch_error, error})
    end)

    {:error, error} = Page.goto(page, server.prefix <> "/slow", timeout: 2000)
    assert Exception.message(error) =~ "Timeout 2000ms exceeded"
    assert_receive {:fetch_error, fetch_error}, 5000
    assert Exception.message(fetch_error) =~ "route.fetch: Timeout 1000ms exceeded"
  end

  test "should not follow redirects when maxRedirects is set to 0 in route.fetch", %{page: page, server: server} do
    TestServer.set_redirect(server, "/foo", "/empty.html")
    me = self()

    Page.route!(page, "**/*", fn route ->
      response = Route.fetch!(route, max_redirects: 0)
      send(me, {:fetched, APIResponse.headers(response)["location"], APIResponse.status(response)})
      Route.fulfill!(route, body: "hello")
    end)

    Page.goto!(page, server.prefix <> "/foo")
    assert_received {:fetched, "/empty.html", 302}
    assert Page.content!(page) =~ "hello"
  end

  test "should intercept with url override", %{page: page, server: server} do
    Page.route!(page, "**/*.html", fn route ->
      response = Route.fetch!(route, url: server.prefix <> "/one-style.html")
      Route.fulfill!(route, response: response)
    end)

    response = Page.goto!(page, server.prefix <> "/empty.html")
    assert Response.status(response) == 200
    assert Response.body!(response) =~ "one-style.css"
  end

  test "should intercept with post data override", %{page: page, server: server} do
    request_promise = TestServer.wait_for_request(server, "/empty.html")

    Page.route!(page, "**/*.html", fn route ->
      response = Route.fetch!(route, post_data: %{"foo" => "bar"})
      Route.fulfill!(route, response: response)
    end)

    Page.goto!(page, server.prefix <> "/empty.html")
    request = Task.await(request_promise)
    assert request.assigns.post_body == JSON.encode!(%{"foo" => "bar"})
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream fixme: The body is empty in WebKit when intercepting")
  test "request.postData is not null when fetching FormData with a Blob", %{
    page: page,
    server: server
  } do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """

    <script>
      function doStuff() {
        const formData = new FormData();
        formData.append('file', new Blob(["hello"], { type: "text/plain" }));
        fetch('/upload', {
          method: 'POST',
          body: formData
        });
      }
    </script>
    <body>
    <button onclick="doStuff()" data-testid="click-me">Click me!</button>
    </body>
    """)

    me = self()

    Page.route!(page, server.prefix <> "/upload", fn route, request ->
      send(me, {:method, Request.method(request)})
      send(me, {:post_data, Request.post_data(request)})
      Route.fulfill!(route, status: 200, body: "ok")
    end)

    page |> Page.get_by_test_id("click-me") |> Locator.click!()
    assert_receive {:post_data, post_data}, 5000
    assert_received {:method, "POST"}
    assert post_data =~ ~s(Content-Disposition: form-data; name="file"; filename="blob")
    assert post_data =~ "\r\nhello\r\n"
  end

  test "should abort favicon requests if interception is enabled", %{page: page, server: server} do
    me = self()

    TestServer.set_route(server, "/favicon.ico", fn conn ->
      send(me, :favicon_request)
      conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_resp(200, "my content")
    end)

    # Intercept all requests.
    Page.route!(page, "**/*", &Route.fulfill!(&1, status: 200, body: "Hello, world!"))
    Page.goto!(page, server.empty_page)
    response = Page.evaluate!(page, "() => fetch('/favicon.ico').then(r => r.text()).catch(e => 'load failed')")
    assert response == "load failed"
    # Browsers can send favicon requests in the background.
    Process.sleep(1000)
    refute_received :favicon_request
  end
end
