defmodule PlaywrightEx.Library.BrowsercontextRouteTest do
  @upstream "tests/library/browsercontext-route.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  # tests/config/browserTest.ts defaultSameSiteCookieValue
  defp default_same_site_cookie_value("chromium"), do: "Lax"
  defp default_same_site_cookie_value("webkit"), do: if(match?({:unix, :linux}, :os.type()), do: "Lax", else: "None")
  defp default_same_site_cookie_value("firefox"), do: "None"

  # `const intercepted = []; ... intercepted.push(x)`: the handlers send to the test process.
  defp received(acc \\ []) do
    receive do
      {:intercepted, x} -> received([x | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "should intercept", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    me = self()

    BrowserContext.route!(context, "**/empty.html", fn route ->
      request = Route.request(route)
      send(me, {:intercepted, {request, Frame.url(Request.frame(request))}})
      Route.continue(route)
    end)

    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.empty_page)
    assert Response.ok(response) == true
    # The handler's assertions, in the test process.
    assert [{request, frame_url}] = received()
    assert Request.url(request) =~ "empty.html"
    assert Request.headers(request)["user-agent"]
    assert Request.method(request) == "GET"
    assert Request.post_data(request) == nil
    assert Request.is_navigation_request(request) == true
    assert Request.resource_type(request) == "document"
    assert Request.frame(request) == Page.main_frame(page)
    assert frame_url == "about:blank"
    BrowserContext.close!(context)
  end

  test "should unroute", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    me = self()

    BrowserContext.route!(context, "**/*", fn route ->
      send(me, {:intercepted, 1})
      Route.fallback(route)
    end)

    BrowserContext.route!(context, "**/empty.html", fn route ->
      send(me, {:intercepted, 2})
      Route.fallback(route)
    end)

    BrowserContext.route!(context, "**/empty.html", fn route ->
      send(me, {:intercepted, 3})
      Route.fallback(route)
    end)

    handler4 = fn route ->
      send(me, {:intercepted, 4})
      Route.fallback(route)
    end

    BrowserContext.route!(context, ~r/empty.html/, handler4)
    Page.goto!(page, server.empty_page)
    assert received() == [4, 3, 2, 1]

    BrowserContext.unroute!(context, ~r/empty.html/, handler4)
    Page.goto!(page, server.empty_page)
    assert received() == [3, 2, 1]

    BrowserContext.unroute!(context, "**/empty.html")
    Page.goto!(page, server.empty_page)
    assert received() == [1]

    BrowserContext.close!(context)
  end

  test "should yield to page.route", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    BrowserContext.route!(context, "**/empty.html", &Route.fulfill(&1, status: 200, body: "context"))
    page = BrowserContext.new_page!(context)
    Page.route!(page, "**/empty.html", &Route.fulfill(&1, status: 200, body: "page"))
    response = Page.goto!(page, server.empty_page)
    assert Response.ok(response) == true
    assert Response.text!(response) == "page"
    BrowserContext.close!(context)
  end

  test "should fall back to context.route", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    BrowserContext.route!(context, "**/empty.html", &Route.fulfill(&1, status: 200, body: "context"))
    page = BrowserContext.new_page!(context)
    Page.route!(page, "**/non-empty.html", &Route.fulfill(&1, status: 200, body: "page"))
    response = Page.goto!(page, server.empty_page)
    assert Response.ok(response) == true
    assert Response.text!(response) == "context"
    BrowserContext.close!(context)
  end

  test "should support Set-Cookie header", %{context_factory: context_factory, browser_name: browser_name} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)

    Page.route!(page, "https://example.com/", fn route, _request ->
      Route.fulfill(route,
        headers: %{"Set-Cookie" => "name=value; domain=.example.com; Path=/"},
        content_type: "text/html",
        body: "done"
      )
    end)

    Page.goto!(page, "https://example.com")

    assert BrowserContext.cookies!(context) == [
             %{
               sameSite: default_same_site_cookie_value(browser_name),
               name: "name",
               value: "value",
               domain: ".example.com",
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: false
             }
           ]
  end

  test "should ignore secure Set-Cookie header for insecure requests", %{context_factory: context_factory} do
    # it.fixme(browserName === 'webkit' && !isMac);  -- we run chromium
    context = context_factory.([])
    page = BrowserContext.new_page!(context)

    Page.route!(page, "http://example.com/", fn route, _request ->
      Route.fulfill(route,
        headers: %{"Set-Cookie" => "name=value; domain=.example.com; Path=/; Secure"},
        content_type: "text/html",
        body: "done"
      )
    end)

    Page.goto!(page, "http://example.com")
    assert BrowserContext.cookies!(context) == []
  end

  test "should use Set-Cookie header in future requests",
       %{context_factory: context_factory, server: server, browser_name: browser_name} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)

    Page.route!(page, server.empty_page, fn route, _request ->
      Route.fulfill(route, headers: %{"Set-Cookie" => "name=value"}, content_type: "text/html", body: "done")
    end)

    Page.goto!(page, server.empty_page)

    assert BrowserContext.cookies!(context) == [
             %{
               sameSite: default_same_site_cookie_value(browser_name),
               name: "name",
               value: "value",
               domain: server.hostname,
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: false
             }
           ]

    me = self()

    TestServer.set_route(server, "/foo.html", fn conn ->
      send(me, {:cookie, conn |> Plug.Conn.get_req_header("cookie") |> List.first()})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.goto!(page, server.prefix <> "/foo.html")
    assert_received {:cookie, "name=value"}
  end

  test "should work with ignoreHTTPSErrors", %{browser: browser, https_server: https_server} do
    context = Browser.new_context!(browser, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)

    Page.route!(page, "**/*", &Route.continue/1)
    response = Page.goto!(page, https_server.empty_page)
    assert Response.status(response) == 200
    BrowserContext.close!(context)
  end

  @tag :page
  test "should support the times parameter with route matching", %{context: context, page: page, server: server} do
    me = self()

    BrowserContext.route!(
      context,
      "**/empty.html",
      fn route ->
        send(me, {:intercepted, 1})
        Route.continue(route)
      end,
      times: 1
    )

    Page.goto!(page, server.empty_page)
    Page.goto!(page, server.empty_page)
    Page.goto!(page, server.empty_page)
    assert length(received()) == 1
  end

  @tag :page
  test "should work if handler with times parameter was removed from another handler",
       %{context: context, page: page, server: server} do
    me = self()

    handler = fn route ->
      send(me, {:intercepted, "first"})
      Route.continue(route)
    end

    BrowserContext.route!(context, "**/*", handler, times: 1)

    BrowserContext.route!(context, "**/*", fn route ->
      send(me, {:intercepted, "second"})
      BrowserContext.unroute!(context, "**/*", handler)
      Route.fallback!(route)
    end)

    Page.goto!(page, server.empty_page)
    assert received() == ["second"]
    Page.goto!(page, server.empty_page)
    assert received() == ["second"]
  end

  @tag skip: "not ported: expect"
  test "should support async handler w/ times"

  @tag :page
  test "should overwrite post body with empty string", %{context: context, server: server, page: page} do
    BrowserContext.route!(context, "**/empty.html", &Route.continue(&1, post_data: ""))

    req = TestServer.wait_for_request(server, "/empty.html")

    Page.set_content!(page, """
    <script>
      (async () => {
          await fetch('#{server.empty_page}', {
            method: 'POST',
            body: 'original',
          });
      })()
    </script>
    """)

    body = Task.await(req).assigns.post_body
    assert body == ""
  end

  @tag :page
  test "should chain fallback", %{context: context, page: page, server: server} do
    me = self()

    for i <- 1..3 do
      BrowserContext.route!(context, "**/empty.html", fn route ->
        send(me, {:intercepted, i})
        Route.fallback(route)
      end)
    end

    Page.goto!(page, server.empty_page)
    assert received() == [3, 2, 1]
  end

  @tag :page
  test "should chain fallback w/ dynamic URL", %{context: context, page: page, server: server} do
    me = self()

    BrowserContext.route!(context, "**/bar", fn route ->
      send(me, {:intercepted, 1})
      Route.fallback(route, url: server.empty_page)
    end)

    BrowserContext.route!(context, "**/foo", fn route ->
      send(me, {:intercepted, 2})
      Route.fallback(route, url: "http://localhost/bar")
    end)

    BrowserContext.route!(context, "**/empty.html", fn route ->
      send(me, {:intercepted, 3})
      Route.fallback(route, url: "http://localhost/foo")
    end)

    Page.goto!(page, server.empty_page)
    assert received() == [3, 2, 1]
  end

  @tag :page
  test "should not chain fulfill", %{context: context, page: page, server: server} do
    me = self()
    BrowserContext.route!(context, "**/empty.html", fn _route -> send(me, :failed) end)
    BrowserContext.route!(context, "**/empty.html", &Route.fulfill(&1, status: 200, body: "fulfilled"))
    BrowserContext.route!(context, "**/empty.html", &Route.fallback/1)
    response = Page.goto!(page, server.empty_page)
    body = Response.body!(response)
    assert body == "fulfilled"
    refute_received :failed
  end

  @tag :page
  test "should not chain abort", %{context: context, page: page, server: server} do
    me = self()
    BrowserContext.route!(context, "**/empty.html", fn _route -> send(me, :failed) end)
    BrowserContext.route!(context, "**/empty.html", &Route.abort/1)
    BrowserContext.route!(context, "**/empty.html", &Route.fallback/1)
    assert {:error, e} = Page.goto(page, server.empty_page)
    assert e
    refute_received :failed
  end

  @tag :page
  test "should chain fallback into page", %{context: context, page: page, server: server} do
    me = self()

    for i <- 1..3 do
      BrowserContext.route!(context, "**/empty.html", fn route ->
        send(me, {:intercepted, i})
        Route.fallback(route)
      end)
    end

    for i <- 4..6 do
      Page.route!(page, "**/empty.html", fn route ->
        send(me, {:intercepted, i})
        Route.fallback(route)
      end)
    end

    Page.goto!(page, server.empty_page)
    assert received() == [6, 5, 4, 3, 2, 1]
  end

  @tag :page
  test "should fall back async", %{page: page, context: context, server: server} do
    me = self()

    for i <- 1..3 do
      BrowserContext.route!(context, "**/empty.html", fn route ->
        send(me, {:intercepted, i})
        Page.wait_for_timeout!(page, 100)
        Route.fallback(route)
      end)
    end

    Page.goto!(page, server.empty_page)
    assert received() == [3, 2, 1]
  end

  @tag :page
  test "should bypass disk cache when context interception is enabled", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/30000
    BrowserContext.route!(Page.context(page), "**/api*", &Route.continue/1)
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    me = self()

    TestServer.set_route(server, "/api", fn conn ->
      send(me, {:intercepted, conn})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=31536000")
      |> Plug.Conn.send_resp(200, "Hello")
    end)

    Enum.reduce(0..2, 0, fn i, requests ->
      # main frame iteration #{i}
      resp_promise = Page.wait_for_response(page, "**/api")

      Page.evaluate!(page, """
      async () => {
        const response = await fetch('/api');
        return response.status;
      }
      """)

      response = PlaywrightEx.Promise.await!(resp_promise)
      assert Response.status(response) == 200
      requests = requests + length(received())
      assert requests == i + 1
      requests
    end)
  end

  @tag skip: "not ported: fetch, expect"
  test "should fulfill popup main request using alias"

  @tag skip: "not ported: URLPattern"
  test "should respect URLPattern ignoreCase"
end
