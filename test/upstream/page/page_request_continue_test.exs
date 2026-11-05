defmodule PlaywrightEx.Page.PageRequestContinueTest do
  @upstream "tests/page/page-request-continue.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

  # `request.headers[name]` of a server-side request.
  defp req_header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  # `new URL(url).host`
  defp url_host(url) do
    uri = URI.parse(url)
    "#{uri.host}:#{uri.port}"
  end

  # Messages `{tag, x}` sent so far, in order (`intercepted.push(x)`).
  defp received(tag, acc \\ []) do
    receive do
      {^tag, x} -> received(tag, [x | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # `server.setRoute('/something', ...)` answering CORS preflights, resolving with the request.
  defp set_cors_route(server, allow_headers, response_headers) do
    me = self()

    TestServer.set_route(server, "/something", fn conn ->
      if conn.method == "OPTIONS" do
        conn
        |> Plug.Conn.put_resp_header("access-control-allow-origin", server.prefix)
        |> Plug.Conn.put_resp_header("access-control-allow-credentials", "true")
        |> Plug.Conn.put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS, DELETE")
        |> Plug.Conn.put_resp_header("access-control-allow-headers", allow_headers)
        |> Plug.Conn.send_resp(204, "")
      else
        send(me, {:server_request, conn})

        conn
        |> Plug.Conn.merge_resp_headers(response_headers)
        |> Plug.Conn.send_resp(200, "done")
      end
    end)
  end

  @fetch_with_credentials """
  async url => {
    const data = await fetch(url, {
      headers: {
        authorization: 'credentials',
        custom: 'foo'
      },
      credentials: 'include',
    });
    return data.text();
  }
  """

  test "should work", %{page: page, server: server} do
    Page.route!(page, "**/*", &Route.continue/1)
    Page.goto!(page, server.empty_page)
  end

  test "should amend HTTP headers", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      headers = Map.put(Request.headers(Route.request(route)), "FOO", "bar")
      Route.continue(route, headers: headers)
    end)

    Page.goto!(page, server.empty_page)
    request = TestServer.wait_for_request(server, "/sleep.zzz")
    Page.evaluate!(page, "() => fetch('/sleep.zzz')")
    assert req_header(Task.await(request, :infinity), "foo") == "bar"
  end

  test "should not allow to override unsafe HTTP headers", %{page: page, server: server} do
    me = self()
    Page.route!(page, "**/*", fn route -> send(me, {:route, route}) end)
    server_request_promise = TestServer.wait_for_request(server, "/empty.html")
    goto = Task.async(fn -> Page.goto(page, server.empty_page) end)
    assert_receive {:route, route}, 5000

    Route.continue!(route,
      headers: Map.merge(Request.headers(Route.request(route)), %{"host" => "bar", "trailer" => "baz"})
    )

    server_request = Task.await(server_request_promise, :infinity)
    assert req_header(server_request, "trailer") == nil
    assert req_header(server_request, "host") == url_host(server.empty_page)
    Task.await(goto, :infinity)
  end

  test "should delete header with undefined value", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")

    TestServer.set_route(server, "/something", fn conn ->
      conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(200, "done")
    end)

    me = self()

    Page.route!(page, server.prefix <> "/something", fn route, request ->
      send(me, {:intercepted_request, request})
      headers = Request.all_headers!(request)
      Route.continue(route, headers: Map.put(headers, "foo", nil))
    end)

    server_request = TestServer.wait_for_request(server, "/something")

    text =
      Page.evaluate!(
        page,
        """
        async url => {
          const data = await fetch(url, {
            headers: {
              foo: 'a',
              bar: 'b',
            }
          });
          return data.text();
        }
        """,
        server.prefix <> "/something"
      )

    server_request = Task.await(server_request, :infinity)
    assert text == "done"
    assert_received {:intercepted_request, intercepted_request}
    assert Request.headers(intercepted_request)["foo"] == nil
    refute req_header(server_request, "foo")
    assert req_header(server_request, "bar") == "b"
  end

  test "should amend method", %{page: page, server: server} do
    s_request = TestServer.wait_for_request(server, "/sleep.zzz")
    Page.goto!(page, server.empty_page)
    Page.route!(page, "**/*", &Route.continue(&1, method: "POST"))
    request = TestServer.wait_for_request(server, "/sleep.zzz")
    Page.evaluate!(page, "() => fetch('/sleep.zzz')")
    assert Task.await(request, :infinity).method == "POST"
    assert Task.await(s_request, :infinity).method == "POST"
  end

  test "should override request url", %{page: page, server: server} do
    server_request = TestServer.wait_for_request(server, "/global-var.html")
    Page.route!(page, "**/foo", &Route.continue(&1, url: server.prefix <> "/global-var.html"))
    response = Page.goto!(page, server.prefix <> "/foo")
    assert Request.url(Response.request(response)) == server.prefix <> "/global-var.html"
    assert Response.url(response) == server.prefix <> "/global-var.html"
    assert Page.evaluate!(page, "() => window['globalVar']") == 123
    assert Task.await(server_request, :infinity).method == "GET"
  end

  test "should not allow changing protocol when overriding url", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      case Route.continue(route, url: "file:///tmp/foo") do
        :ok -> send(me, {:error, nil})
        {:error, e} -> send(me, {:error, e})
      end
    end)

    # `page.goto(...).catch(() => {})`: never settles, ends when the context closes.
    spawn(fn -> Page.goto(page, server.empty_page) end)
    assert_receive {:error, error}, 5000
    assert error
    assert Exception.message(error) =~ "New URL must have same protocol as overridden URL"
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
    assert Request.failure(cancelled_request).errorText =~ ~r/cancelled|aborted/i
    # Should not throw.
    Route.continue!(route)
    Task.await(fetch, :infinity)
  end

  test "should override method along with url", %{page: page, server: server} do
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.route!(page, "**/foo", &Route.continue(&1, url: server.empty_page, method: "POST"))
    Page.goto!(page, server.prefix <> "/foo")
    assert Task.await(request, :infinity).method == "POST"
  end

  test "should amend method on main request", %{page: page, server: server} do
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.route!(page, "**/*", &Route.continue(&1, method: "POST"))
    Page.goto!(page, server.empty_page)
    assert Task.await(request, :infinity).method == "POST"
  end

  describe "post data" do
    test "should amend post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      Page.route!(page, "**/*", &Route.continue(&1, post_data: "doggo"))
      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'POST', body: 'birdy' })")
      assert Task.await(server_request, :infinity).assigns.post_body == "doggo"
    end

    test "should compute content-length from post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      data = String.duplicate("a", 7500)

      Page.route!(page, "**/*", fn route ->
        headers = Map.put(Request.headers(Route.request(route)), "content-type", "application/json")
        Route.continue(route, post_data: data, headers: headers)
      end)

      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'PATCH', body: 'birdy' })")
      server_request = Task.await(server_request, :infinity)
      assert server_request.assigns.post_body == data
      assert req_header(server_request, "content-length") == to_string(String.length(data))
      assert req_header(server_request, "content-type") == "application/json"
    end

    test "should amend method and post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      Page.route!(page, "**/*", &Route.continue(&1, method: "POST", post_data: "doggo"))
      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'GET' })")
      server_request = Task.await(server_request, :infinity)
      assert server_request.method == "POST"
      assert server_request.assigns.post_body == "doggo"
    end

    test "should amend utf8 post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      Page.route!(page, "**/*", &Route.continue(&1, post_data: "пушкин"))
      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'POST', body: 'birdy' })")
      server_request = Task.await(server_request, :infinity)
      assert server_request.method == "POST"
      assert server_request.assigns.post_body == "пушкин"
    end

    test "should amend longer post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      Page.route!(page, "**/*", &Route.continue(&1, post_data: "doggo-is-longer-than-birdy"))
      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'POST', body: 'birdy' })")
      server_request = Task.await(server_request, :infinity)
      assert server_request.method == "POST"
      assert server_request.assigns.post_body == "doggo-is-longer-than-birdy"
    end

    test "should amend binary post data", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      arr = :binary.list_to_bin(Enum.to_list(0..255))
      Page.route!(page, "**/*", &Route.continue(&1, post_data: {:binary, arr}))
      server_request = TestServer.wait_for_request(server, "/sleep.zzz")
      Page.evaluate!(page, "() => fetch('/sleep.zzz', { method: 'POST', body: 'birdy' })")
      server_request = Task.await(server_request, :infinity)
      assert server_request.method == "POST"
      buffer = server_request.assigns.post_body
      assert byte_size(buffer) == byte_size(arr)
      assert buffer == arr
    end

    test "should use content-type from original request", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      Page.route!(page, "#{server.prefix}/title.html", &Route.continue(&1, post_data: ~s({"b":2})))
      request = TestServer.wait_for_request(server, "/title.html")

      Page.evaluate!(
        page,
        """
        async url => {
          await fetch(url, {
            method: 'POST',
            body: '{"a":1}',
            headers: { 'content-type': 'application/json' },
          });
        }
        """,
        "#{server.prefix}/title.html"
      )

      request = Task.await(request, :infinity)
      assert req_header(request, "content-type") == "application/json"
      assert request.assigns.post_body == ~s({"b":2})
    end
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream fail: https://github.com/microsoft/playwright/issues/8796")
  test "should work with Cross-Origin-Opener-Policy", %{page: page, server: server, browser_name: browser_name} do
    me = self()

    TestServer.set_route(server, "/empty.html", fn conn ->
      send(me, {:server_request, {conn.request_path, conn.req_headers}})

      # Note: without 'onload', Firefox sometimes does not fire the load event
      # over the protocol. The reason is unclear.
      conn
      |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
      |> Plug.Conn.send_resp(200, """

        <div>Hello there!</div>
        <script>window.onload = () => console.log('onload')</script>
      """)
    end)

    Page.route!(page, "**/*", fn route, req ->
      send(me, {:intercepted, Request.url(req)})
      Route.continue(route, headers: %{"foo" => "bar"})
    end)

    Page.on(page, :request, fn r -> send(me, {:event, {"request", r}}) end)
    Page.on(page, :request_failed, fn r -> send(me, {:event, {"requestfailed", r}}) end)
    Page.on(page, :request_finished, fn r -> send(me, {:event, {"requestfinished", r}}) end)
    Page.on(page, :response, fn r -> send(me, {:event, {"response", Response.request(r)}}) end)
    response = Page.goto!(page, server.empty_page)
    assert received(:intercepted) == [server.empty_page]
    server_requests = received(:server_request)
    # There should be only one request to the server.
    if browser_name == "webkit",
      do: assert(Enum.map(server_requests, &elem(&1, 0)) == ["/empty.html", "/empty.html"]),
      else: assert(Enum.map(server_requests, &elem(&1, 0)) == ["/empty.html"])

    {_, server_headers} = hd(server_requests)
    assert :proplists.get_value("foo", server_headers) == "bar"
    assert Page.url(page) == server.empty_page
    Response.finished!(response)
    events = received(:event)
    assert Enum.map(events, &elem(&1, 0)) == ["request", "response", "requestfinished"]
    assert events |> MapSet.new(&elem(&1, 1)) |> MapSet.size() == 1
    assert Request.failure(Response.request(response)) == nil
  end

  test "should not delete the origin header", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")

    TestServer.set_route(server, "/something", fn conn ->
      conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(200, "done")
    end)

    me = self()

    Page.route!(page, server.cross_process_prefix <> "/something", fn route, request ->
      headers = Request.all_headers!(request)
      send(me, {:intercepted_origin, headers["origin"]})
      Route.continue(route, headers: Map.delete(headers, "origin"))
    end)

    server_request = TestServer.wait_for_request(server, "/something")

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

    server_request = Task.await(server_request, :infinity)
    assert text == "done"
    assert_received {:intercepted_origin, intercepted_origin}
    assert intercepted_origin == server.prefix
    assert req_header(server_request, "origin") == server.prefix
  end

  test "should continue preload link requests", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/one-style.css", fn route ->
      send(me, :intercepted)
      Route.continue(route, headers: Map.put(Request.headers(Route.request(route)), "custom", "value"))
    end)

    server_request = TestServer.wait_for_request(server, "/one-style.css")
    Page.goto!(page, server.prefix <> "/preload.html")
    server_request = Task.await(server_request, :infinity)
    assert req_header(server_request, "custom") == "value"
    Page.wait_for_function!(page, "() => window.preloadedStyles")
    assert_received :intercepted
    color = Page.evaluate!(page, "() => window.getComputedStyle(document.body).backgroundColor")
    assert color == "rgb(255, 192, 203)"
  end

  test "should respect set-cookie in redirect response", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a href="/set-cookie-redirect">Set cookie</a>))

    TestServer.set_route(server, "/set-cookie-redirect", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "foo=bar;  max-age=36000")
      |> Plug.Conn.put_resp_header("location", "/empty.html")
      |> Plug.Conn.send_resp(302, "")
    end)

    Page.route!(page, "**/set-cookie-redirect", fn route ->
      Route.continue(route, headers: Request.headers(Route.request(route)))
    end)

    server_request_promise = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.prefix <> "/set-cookie-redirect")
    server_request = Task.await(server_request_promise, :infinity)
    assert req_header(server_request, "cookie") == "foo=bar"
    assert Page.evaluate!(page, "() => document.cookie") == "foo=bar"
  end

  test "continue should not propagate cookie override to redirects", %{page: page, server: server} do
    TestServer.set_route(server, "/set-cookie", fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", "foo=bar;") |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.prefix <> "/set-cookie")
    assert Page.evaluate!(page, "() => document.cookie") == "foo=bar"
    TestServer.set_redirect(server, "/redirect", server.prefix <> "/empty.html")

    Page.route!(page, "**/redirect", fn route ->
      Route.continue(route, headers: Map.put(Request.headers(Route.request(route)), "cookie", "override"))
    end)

    server_request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.prefix <> "/redirect")
    assert req_header(Task.await(server_request, :infinity), "cookie") == "foo=bar"
  end

  test "continue should not override cookie", %{page: page, server: server} do
    TestServer.set_route(server, "/set-cookie", fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", "foo=bar;") |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.prefix <> "/set-cookie")
    assert Page.evaluate!(page, "() => document.cookie") == "foo=bar"

    Page.route!(page, "**", fn route ->
      headers = Map.merge(Request.headers(Route.request(route)), %{"cookie" => "override", "custom" => "value"})
      Route.continue(route, headers: headers)
    end)

    server_request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    server_request = Task.await(server_request, :infinity)
    # Original cookie from the browser's cookie jar should be sent.
    assert req_header(server_request, "cookie") == "foo=bar"
    assert req_header(server_request, "custom") == "value"
  end

  test "continue with headers should send fresh cookie from the browser cookie store", %{
    page: page,
    server: server
  } do
    TestServer.set_route(server, "/set-cookie", fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", "foo=v1;") |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.prefix <> "/set-cookie")
    assert Page.evaluate!(page, "() => document.cookie") == "foo=v1"

    Page.route!(page, "**/empty.html", fn route ->
      # Cookie store changes between interception and continuation.
      BrowserContext.add_cookies!(Page.context(page), [%{name: "foo", value: "v2", url: server.prefix}])
      Route.continue!(route, headers: Request.headers(Route.request(route)))
    end)

    server_request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    # The fresh cookie from the browser cookie store should be sent, not the stale captured value.
    assert req_header(Task.await(server_request, :infinity), "cookie") == "foo=v2"
  end

  test "continue with headers should send fresh cookie after a redirect", %{page: page, server: server} do
    TestServer.set_route(server, "/set-cookie", fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", "foo=v1;") |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.prefix <> "/set-cookie")
    assert Page.evaluate!(page, "() => document.cookie") == "foo=v1"

    # The redirect updates the cookie before bouncing to the final destination.
    TestServer.set_route(server, "/redirect", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "foo=v2;")
      |> Plug.Conn.put_resp_header("location", server.prefix <> "/empty.html")
      |> Plug.Conn.send_resp(302, "")
    end)

    Page.route!(page, "**/redirect", fn route ->
      Route.continue(route, headers: Request.headers(Route.request(route)))
    end)

    server_request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.prefix <> "/redirect")
    # The redirected request should carry the cookie updated by the redirect, not the stale captured value.
    assert req_header(Task.await(server_request, :infinity), "cookie") == "foo=v2"
  end

  test "redirect after continue should be able to delete cookie", %{page: page, server: server} do
    TestServer.set_route(server, "/set-cookie", fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", "foo=bar;") |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.prefix <> "/set-cookie")
    assert Page.evaluate!(page, "() => document.cookie") == "foo=bar"

    TestServer.set_route(server, "/delete-cookie", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "foo=bar; expires=Thu, 01 Jan 1970 00:00:00 GMT")
      |> Plug.Conn.send_resp(200, "")
    end)

    TestServer.set_redirect(server, "/redirect", "/delete-cookie")

    Page.route!(page, "**/redirect", fn route ->
      Route.continue(route, headers: Request.headers(Route.request(route)))
    end)

    Page.goto!(page, server.prefix <> "/redirect")
    server_request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    refute req_header(Task.await(server_request, :infinity), "cookie")
  end

  test "continue should propagate headers to redirects", %{page: page, server: server} do
    TestServer.set_redirect(server, "/redirect", "/empty.html")

    Page.route!(page, "**/redirect", fn route ->
      Route.continue(route, headers: Map.put(Request.headers(Route.request(route)), "custom", "value"))
    end)

    server_request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.prefix <> "/redirect")
    assert req_header(Task.await(server_request, :infinity), "custom") == "value"
  end

  test "continue should drop content-length on redirects", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_redirect(server, "/redirect", "/empty.html")

    Page.route!(page, "**/redirect", fn route ->
      Route.continue(route, headers: Map.put(Request.headers(Route.request(route)), "custom", "value"))
    end)

    server_request = TestServer.wait_for_request(server, "/empty.html")
    Page.evaluate!(page, "url => fetch(url, { method: 'POST', body: 'foo' })", server.prefix <> "/redirect")
    server_request = Task.await(server_request, :infinity)
    assert server_request.method == "GET"
    assert req_header(server_request, "content-length") == nil
    assert req_header(server_request, "content-type") == nil
    assert req_header(server_request, "custom") == "value"
  end

  test "redirected requests should report overridden headers", %{page: page, server: server} do
    TestServer.set_redirect(server, "/redirect", "/empty.html")

    Page.route!(page, "**/redirect", fn route ->
      headers = Map.put(Request.headers(Route.request(route)), "custom", "value")
      Route.fallback(route, headers: headers)
    end)

    server_request = TestServer.wait_for_request(server, "/empty.html")
    response = Page.goto!(page, server.prefix <> "/redirect")
    assert req_header(Task.await(server_request, :infinity), "custom") == "value"
    assert Request.url(Response.request(response)) == server.empty_page
    assert Request.headers(Response.request(response))["custom"] == "value"
    assert Request.all_headers!(Response.request(response))["custom"] == "value"
  end

  test "continue should delete headers on redirects", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")

    TestServer.set_route(server, "/something", fn conn ->
      conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(200, "done")
    end)

    TestServer.set_redirect(server, "/redirect", "/something")

    Page.route!(page, "**/redirect", fn route ->
      Route.continue(route, headers: Map.put(Request.headers(Route.request(route)), "foo", nil))
    end)

    server_request = TestServer.wait_for_request(server, "/something")

    text =
      Page.evaluate!(
        page,
        """
        async url => {
          const data = await fetch(url, {
            headers: {
              foo: 'a',
            }
          });
          return data.text();
        }
        """,
        server.prefix <> "/redirect"
      )

    assert text == "done"
    refute req_header(Task.await(server_request, :infinity), "foo")
  end

  test "propagate headers same origin redirect", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")
    set_cors_route(server, "authorization,cookie,custom", [])
    TestServer.set_redirect(server, "/redirect", "/something")
    Page.evaluate!(page, "() => document.cookie = 'a=b'")
    text = Page.evaluate!(page, @fetch_with_credentials, server.prefix <> "/redirect")
    assert text == "done"
    assert_receive {:server_request, server_request}
    assert req_header(server_request, "authorization") == "credentials"
    assert req_header(server_request, "cookie") == "a=b"
    assert req_header(server_request, "custom") == "foo"
  end

  test "propagate headers cross origin", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")

    set_cors_route(server, "authorization,custom", [
      {"access-control-allow-origin", server.prefix},
      {"access-control-allow-credentials", "true"}
    ])

    text = Page.evaluate!(page, @fetch_with_credentials, server.cross_process_prefix <> "/something")
    assert text == "done"
    assert_receive {:server_request, server_request}
    assert req_header(server_request, "authorization") == "credentials"
    assert req_header(server_request, "custom") == "foo"
  end

  test "propagate headers cross origin redirect", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")

    set_cors_route(server, "authorization,cookie,custom", [
      {"access-control-allow-origin", server.prefix},
      {"access-control-allow-credentials", "true"}
    ])

    TestServer.set_route(server, "/redirect", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "#{server.cross_process_prefix}/something")
      |> Plug.Conn.send_resp(301, "")
    end)

    Page.evaluate!(page, "() => document.cookie = 'a=b'")
    text = Page.evaluate!(page, @fetch_with_credentials, server.prefix <> "/redirect")
    assert text == "done"
    assert_receive {:server_request, server_request}
    # Authorization header not propagated to cross-origin redirect.
    refute req_header(server_request, "authorization")
    refute req_header(server_request, "cookie")
    assert req_header(server_request, "custom") == "foo"
  end

  test "propagate headers cross origin redirect after interception", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    Page.goto!(page, server.prefix <> "/empty.html")

    set_cors_route(server, "authorization,cookie,custom", [
      {"access-control-allow-origin", server.prefix},
      {"access-control-allow-credentials", "true"}
    ])

    TestServer.set_route(server, "/redirect", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "#{server.cross_process_prefix}/something")
      |> Plug.Conn.send_resp(301, "")
    end)

    Page.evaluate!(page, "() => document.cookie = 'a=b'")

    Page.route!(page, "**/redirect", fn route ->
      headers =
        Map.merge(Request.headers(Route.request(route)), %{"authorization" => "credentials", "custom" => "foo"})

      Route.continue!(route, headers: headers)
    end)

    text =
      Page.evaluate!(
        page,
        """
        async url => {
          const data = await fetch(url, {
            headers: {
              authorization: 'none',
            },
            credentials: 'include',
          });
          return data.text();
        }
        """,
        server.prefix <> "/redirect"
      )

    assert text == "done"
    assert_receive {:server_request, server_request}

    if browser_name == "webkit",
      do: refute(req_header(server_request, "authorization")),
      else: assert(req_header(server_request, "authorization") == "credentials")

    refute req_header(server_request, "cookie")
    assert req_header(server_request, "custom") == "foo"
  end

  test "continue should pass on 307 cross-origin redirect", %{page: page, server: server} do
    TestServer.set_route(server, "/final", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<!doctype html><title>final</title><p>ok</p>")
    end)

    # Cross-origin 307 redirect that preserves the POST method.
    TestServer.set_route(server, "/redirect307", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "#{server.prefix}/final") |> Plug.Conn.send_resp(307, "")
    end)

    Page.goto!(page, server.prefix <> "/empty.html")

    Page.set_content!(page, """
      <form id="f" method="POST" action="#{server.cross_process_prefix}/redirect307">
        <input type="submit">
      </form>
    """)

    Page.route!(page, "**/*", &Route.continue/1)
    url = Task.async(fn -> Page.wait_for_url!(page, "#{server.prefix}/final") end)
    Locator.click!(Page.locator(page, "input"))
    Task.await(url, :infinity)
    Expect.to_have_text!(Page.locator(page, "p"), "ok")
  end

  test "should intercept css variable with background url", %{page: page, server: server} do
    TestServer.set_route(server, "/test.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """

          <style>
            @keyframes JNDzq {
              0% { background-position: 0 0 }
              to { background-position: 100 0 }
            }
            div {
              --background: url(/pptr.png);
              background-image: var(--background);
              animation: JNDzq 1s linear infinite;
            }
          </style>
          <div>Yo!</div>
      """)
    end)

    me = self()

    Page.route!(page, server.prefix <> "/pptr.png", fn route, _request ->
      send(me, {:intercepted, 1})
      Route.continue(route)
    end)

    Page.goto!(page, server.prefix <> "/test.html")
    assert Locator.text_content!(Page.locator(page, "div")) == "Yo!"
    assert_receive {:intercepted, 1}, 5000
    Page.wait_for_timeout!(page, 1000)
    assert length([1 | received(:intercepted)]) == 1
  end

  defp send_form_data(page, server) do
    req_promise = TestServer.wait_for_request(server, "/upload")

    status =
      Page.evaluate!(page, """
      async () => {
        const newFile = new File(['file content'], 'file.txt');
        const formData = new FormData();
        formData.append('file', newFile);
        const response = await fetch('/upload', {
          method: 'POST',
          credentials: 'include',
          body: formData,
        });
        return response.status;
      }
      """)

    req = Task.await(req_promise, :infinity)
    assert status == 200
    req
  end

  test "continue should not change multipart/form-data body", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    TestServer.set_route(server, "/upload", fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_resp(200, "done")
    end)

    req_before = send_form_data(page, server)
    Page.route!(page, "**/*", &Route.continue!/1)
    req_after = send_form_data(page, server)

    file_content =
      Enum.join(
        [
          ~s(Content-Disposition: form-data; name="file"; filename="file.txt"),
          "Content-Type: application/octet-stream",
          "",
          "file content",
          "------"
        ],
        "\r\n"
      )

    assert req_before.assigns.post_body =~ file_content
    assert req_after.assigns.post_body =~ file_content
  end

  test "should not forward Host header on cross-origin redirect", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    redirect_target_path = "/final"
    redirect_source_path = "/redirect"
    me = self()

    TestServer.set_route(server, redirect_target_path, fn conn ->
      send(me, {:redirected_host, req_header(conn, "host")})
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    TestServer.set_route(server, redirect_source_path, fn conn ->
      send(me, {:first_host, req_header(conn, "host")})

      conn
      |> Plug.Conn.put_resp_header("location", "#{server.cross_process_prefix}#{redirect_target_path}")
      |> Plug.Conn.send_resp(302, "")
    end)

    Page.route!(page, "**/*", fn route ->
      headers = Request.headers(Route.request(route))
      send(me, {:has_host, Map.has_key?(headers, "host")})
      Route.continue!(route, headers: headers)
    end)

    response = Page.goto!(page, server.prefix <> redirect_source_path)

    for has_host <- received(:has_host) do
      if browser_name == "firefox", do: assert(has_host), else: refute(has_host)
    end

    assert Response.status(response) == 200
    assert_received {:first_host, first_host}
    assert first_host == url_host(server.prefix)
    assert_received {:redirected_host, redirected_host}
    assert redirected_host == url_host(server.cross_process_prefix)
  end

  test "postData should return empty string when overriding body with empty string", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.route!(page, "**/*", &Route.continue(&1, post_data: ""))

    request =
      Page.expect_request!(page, "**", fn ->
        Page.evaluate!(page, "({ url }) => fetch(url, { method: 'POST', body: 'original' })", %{
          url: server.prefix <> "/sleep.zzz"
        })
      end)

    assert Request.post_data(request) == ""
  end
end
