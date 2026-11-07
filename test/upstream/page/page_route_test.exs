defmodule PlaywrightEx.Page.PageRouteTest do
  @upstream "tests/page/page-route.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  @moduletag :page

  # `const intercepted = []; ... intercepted.push(x)`: the handlers send to the test process.
  defp received(acc \\ []) do
    receive do
      {:intercepted, x} -> received([x | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp major_version(browser), do: browser |> Browser.version() |> String.split(".") |> hd() |> String.to_integer()

  @cars ~s(["electric","gas"])

  test "RO-001 should intercept @smoke", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/empty.html", fn route, request ->
      send(me, {:intercepted, {route, request, Frame.url(Request.frame(request))}})
      Route.continue(route)
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.ok(response) == true
    assert [{route, request, frame_url}] = received()
    assert Route.request(route) == request
    assert Request.url(request) =~ "empty.html"
    Utils.assert_truthy(Request.headers(request)["user-agent"])
    assert Request.method(request) == "GET"
    assert Request.post_data(request) == nil
    assert Request.is_navigation_request(request) == true
    assert Request.resource_type(request) == "document"
    assert Request.frame(request) == Page.main_frame(page)
    assert frame_url == "about:blank"
  end

  test "RO-002 should unroute", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, 1})
      Route.fallback(route)
    end)

    Page.route!(page, "**/empty.html", fn route ->
      send(me, {:intercepted, 2})
      Route.fallback(route)
    end)

    Page.route!(page, "**/empty.html", fn route ->
      send(me, {:intercepted, 3})
      Route.fallback(route)
    end)

    handler4 = fn route ->
      send(me, {:intercepted, 4})
      Route.fallback(route)
    end

    Page.route!(page, ~r/empty.html/, handler4)
    Page.goto!(page, server.empty_page)
    assert received() == [4, 3, 2, 1]

    Page.unroute!(page, ~r/empty.html/, handler4)
    Page.goto!(page, server.empty_page)
    assert received() == [3, 2, 1]

    Page.unroute!(page, "**/empty.html")
    Page.goto!(page, server.empty_page)
    assert received() == [1]
  end

  test "RO-003 should not support ? in glob pattern", %{page: page, server: server} do
    TestServer.set_route(server, "/index", &Plug.Conn.send_resp(&1, 200, "index-no-hello"))
    TestServer.set_route(server, "/index123hello", &Plug.Conn.send_resp(&1, 200, "index123hello"))
    TestServer.set_route(server, "/index?hello", &Plug.Conn.send_resp(&1, 200, "index?hello"))
    TestServer.set_route(server, "/index1hello", &Plug.Conn.send_resp(&1, 200, "index1hello"))

    Page.route!(page, "**/index?hello", fn route, _request ->
      Route.fulfill!(route, body: "intercepted any character")
    end)

    Page.route!(page, "**/index\\?hello", fn route, _request ->
      Route.fulfill!(route, body: "intercepted question mark")
    end)

    Page.goto!(page, server.prefix <> "/index?hello")
    assert Page.content!(page) =~ "intercepted question mark"

    Page.goto!(page, server.prefix <> "/index")
    assert Page.content!(page) =~ "index-no-hello"

    Page.goto!(page, server.prefix <> "/index1hello")
    assert Page.content!(page) =~ "index1hello"

    Page.goto!(page, server.prefix <> "/index123hello")
    assert Page.content!(page) =~ "index123hello"
  end

  test "RO-004 should work when POST is redirected with 302", %{page: page, server: server} do
    TestServer.set_redirect(server, "/rredirect", "/empty.html")
    Page.goto!(page, server.empty_page)
    Page.route!(page, "**/*", &Route.continue/1)

    Page.set_content!(page, """
    <form action='/rredirect' method='post'>
      <input type="hidden" id="foo" name="foo" value="FOOBAR">
    </form>
    """)

    Page.expect_navigation!(page, fn -> Page.eval_on_selector!(page, "form", "form => form.submit()") end)
  end

  # @see https://github.com/GoogleChrome/puppeteer/issues/3973
  test "RO-005 should work when header manipulation headers with redirect", %{page: page, server: server} do
    TestServer.set_redirect(server, "/rrredirect", "/empty.html")

    Page.route!(page, "**/*", fn route ->
      headers = Map.merge(Request.headers(Route.request(route)), %{"foo" => "bar"})
      Route.continue(route, headers: headers)
    end)

    Page.goto!(page, server.prefix <> "/rrredirect")
  end

  # @see https://github.com/GoogleChrome/puppeteer/issues/4743
  test "RO-006 should be able to remove headers", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/*", fn route ->
      headers = Map.delete(Request.headers(Route.request(route)), "foo")
      Route.continue(route, headers: headers)
    end)

    server_request = TestServer.wait_for_request(server, "/title.html")
    Page.evaluate!(page, "url => fetch(url, { headers: { foo: 'bar' } })", server.prefix <> "/title.html")
    server_request = Task.await(server_request, :infinity)
    assert Plug.Conn.get_req_header(server_request, "foo") == []
  end

  test "RO-007 should contain referer header", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Route.request(route)})
      Route.continue(route)
    end)

    Page.goto!(page, server.prefix <> "/one-style.html")
    requests = received()
    assert Request.url(Enum.at(requests, 1)) =~ "/one-style.css"
    assert Request.headers(Enum.at(requests, 1))["referer"] =~ "/one-style.html"
  end

  test "RO-008 should properly return navigation response when URL has cookies", %{page: page, server: server} do
    # Setup cookie.
    Page.goto!(page, server.empty_page)
    BrowserContext.add_cookies!(Page.context(page), [%{url: server.empty_page, name: "foo", value: "bar"}])

    # Setup request interception.
    Page.route!(page, "**/*", &Route.continue/1)
    response = Page.reload!(page)
    assert Response.status(response) == 200
  end

  test "RO-009 should not override cookie header", %{page: page, server: server, browser_name: browser_name} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/16773' });
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => document.cookie = 'original=value'")
    me = self()

    Page.route!(page, "**", fn route ->
      headers = Request.all_headers!(Route.request(route))
      send(me, {:cookie_value_in_route, headers["cookie"]})
      Route.continue(route, headers: Map.put(headers, "cookie", "overridden=value"))
    end)

    server_req = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    server_req = Task.await(server_req, :infinity)

    assert_received {:cookie_value_in_route, cookie_value_in_route}
    if browser_name != "webkit", do: assert(cookie_value_in_route == "original=value")
    assert Plug.Conn.get_req_header(server_req, "cookie") == ["original=value"]
  end

  test "RO-010 should show custom HTTP headers", %{page: page, server: server} do
    Page.set_extra_http_headers!(page, %{"foo" => "bar"})
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Request.headers(Route.request(route))["foo"]})
      Route.continue(route)
    end)

    response = Page.goto!(page, server.empty_page)
    assert Enum.all?(received(), &(&1 == "bar"))
    assert Response.ok(response) == true
  end

  # @see https://github.com/GoogleChrome/puppeteer/issues/4337
  @tag skip: if(@browser_name == "webkit", do: "upstream fixme: No Network.requestIntercepted for the request")
  test "RO-011 should work with redirect inside sync XHR", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/28461' });
    # it.fixme(browserName === 'webkit', 'No Network.requestIntercepted for the request');
    Page.goto!(page, server.empty_page)
    TestServer.set_redirect(server, "/logo.png", "/pptr.png")
    me = self()
    Page.route!(page, "**/*", fn route -> send(me, {:continue_promise, Route.continue(route)}) end)

    status =
      Page.evaluate!(page, """
      async () => {
        const request = new XMLHttpRequest();
        request.open('GET', '/logo.png', false);  // `false` makes the request synchronous
        request.send(null);
        return request.status;
      }
      """)

    assert status == 200
    assert_receive {:continue_promise, continue_promise}
    assert continue_promise == :ok
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream fixme: Redirected request is not paused in WebKit")
  test "RO-012 should pause intercepted XHR until continue", %{page: page, server: server} do
    # it.fixme(browserName === 'webkit', 'Redirected request is not paused in WebKit');
    Page.goto!(page, server.empty_page)
    me = self()
    Page.route!(page, "**/global-var.html", fn route -> send(me, {:route, route}) end)

    status_promise =
      Runtime.Promise.async(
        fn ->
          Page.evaluate!(page, """
          async () => {
            const request = new XMLHttpRequest();
            request.open('GET', '/global-var.html', false);  // `false` makes the request synchronous
            request.send(null);
            return request.status;
          }
          """)
        end,
        shared: true
      )

    assert_receive {:route, route}, 5000
    # Check that intercepted request is actually paused.
    Process.sleep(500)
    refute Runtime.Promise.settled?(status_promise)
    Route.continue!(route)
    assert Runtime.Promise.await(status_promise) == 200
  end

  test "RO-013 should pause intercepted fetch request until continue", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    me = self()
    Page.route!(page, "**/global-var.html", fn route -> send(me, {:route, route}) end)

    status_promise =
      Runtime.Promise.async(
        fn ->
          Page.evaluate!(page, """
          async () => {
            const response = await fetch('/global-var.html');
            return response.status;
          }
          """)
        end,
        shared: true
      )

    assert_receive {:route, route}, 5000
    # Check that intercepted request is actually paused.
    Process.sleep(500)
    refute Runtime.Promise.settled?(status_promise)
    Route.continue!(route)
    assert Runtime.Promise.await(status_promise) == 200
  end

  test "RO-014 should work with custom referer headers", %{
    page: page,
    server: server,
    browser_name: browser_name,
    browser: browser
  } do
    Page.set_extra_http_headers!(page, %{"referer" => server.empty_page})
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Request.headers(Route.request(route))["referer"]})
      Route.continue(route)
    end)

    response = Page.goto!(page, server.empty_page)

    for referer <- received() do
      # See https://github.com/microsoft/playwright/issues/8999
      if browser_name == "chromium" and major_version(browser) < 154,
        do: assert(referer == server.empty_page <> ", " <> server.empty_page),
        else: assert(referer == server.empty_page)
    end

    assert Response.ok(response) == true
  end

  test "RO-015 should be abortable", %{page: page, server: server} do
    Page.route!(page, ~r/\.css$/, &Route.abort/1)
    me = self()
    Page.on(page, :request_failed, fn request -> if Request.url(request) =~ ".css", do: send(me, :failed) end)
    response = Page.goto!(page, server.prefix <> "/one-style.html")
    assert Response.ok(response) == true
    assert Request.failure(Response.request(response)) == nil
    assert_receive :failed
  end

  test "RO-016 should be abortable with custom error codes", %{page: page, server: server, browser_name: browser_name} do
    Page.route!(page, "**/*", &Route.abort(&1, "internetdisconnected"))
    me = self()
    Page.on(page, :request_failed, &send(me, {:failed_request, &1}))
    Page.goto(page, server.empty_page)
    assert_receive {:failed_request, failed_request}

    cond do
      # isMac && macVersion < 11 ? 'Request intercepted'  -- not ported: no macVersion fixture
      browser_name == "webkit" -> assert Request.failure(failed_request).errorText == "Blocked by Web Inspector"
      browser_name == "firefox" -> assert Request.failure(failed_request).errorText == "NS_ERROR_OFFLINE"
      true -> assert Request.failure(failed_request).errorText == "net::ERR_INTERNET_DISCONNECTED"
    end
  end

  test "RO-017 should not throw if request was cancelled by the page", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/28490' });
    me = self()
    Page.route!(page, "**/data.json", fn route -> send(me, {:route, route}) end)
    Page.goto!(page, server.empty_page)

    Runtime.Promise.void(fn ->
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
    Route.abort!(route)
  end

  test "RO-018 should send referer", %{page: page, server: server} do
    Page.set_extra_http_headers!(page, %{"referer" => "http://google.com/"})
    Page.route!(page, "**/*", &Route.continue/1)
    request = TestServer.wait_for_request(server, "/grid.html")
    Page.goto!(page, server.prefix <> "/grid.html")
    assert Plug.Conn.get_req_header(Task.await(request, :infinity), "referer") == ["http://google.com/"]
  end

  test "RO-019 should fail navigation when aborting main resource", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    Page.route!(page, "**/*", &Route.abort/1)
    assert {:error, error} = Page.goto(page, server.empty_page)
    assert error

    cond do
      # isMac && macVersion < 11 ? 'Request intercepted'  -- not ported: no macVersion fixture
      browser_name == "webkit" -> assert Exception.message(error) =~ "Blocked by Web Inspector"
      # isBidi: 'NS_ERROR_ABORT'  -- not ported: no BiDi
      browser_name == "firefox" -> assert Exception.message(error) =~ "NS_ERROR_FAILURE"
      true -> assert Exception.message(error) =~ "net::ERR_FAILED"
    end
  end

  test "RO-020 should not work with redirects", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      Route.continue(route)
      send(me, {:intercepted, Route.request(route)})
    end)

    TestServer.set_redirect(server, "/non-existing-page.html", "/non-existing-page-2.html")
    TestServer.set_redirect(server, "/non-existing-page-2.html", "/non-existing-page-3.html")
    TestServer.set_redirect(server, "/non-existing-page-3.html", "/non-existing-page-4.html")
    TestServer.set_redirect(server, "/non-existing-page-4.html", "/empty.html")

    response = Page.goto!(page, server.prefix <> "/non-existing-page.html")
    assert Response.status(response) == 200
    assert Response.url(response) =~ "empty.html"

    intercepted = received()
    assert length(intercepted) == 1
    assert Request.resource_type(Enum.at(intercepted, 0)) == "document"
    assert Request.is_navigation_request(Enum.at(intercepted, 0)) == true
    assert Request.url(Enum.at(intercepted, 0)) =~ "/non-existing-page.html"

    chain =
      response
      |> Response.request()
      |> Stream.iterate(&Request.redirected_from/1)
      |> Enum.take_while(& &1)

    for r <- chain, do: assert(Request.is_navigation_request(r) == true)
    assert length(chain) == 5
    assert Request.url(Enum.at(chain, 0)) =~ "/empty.html"
    assert Request.url(Enum.at(chain, 1)) =~ "/non-existing-page-4.html"
    assert Request.url(Enum.at(chain, 2)) =~ "/non-existing-page-3.html"
    assert Request.url(Enum.at(chain, 3)) =~ "/non-existing-page-2.html"
    assert Request.url(Enum.at(chain, 4)) =~ "/non-existing-page.html"

    for {r, i} <- Enum.with_index(chain),
        do: assert(Request.redirected_to(r) == if(i > 0, do: Enum.at(chain, i - 1), else: nil))
  end

  test "RO-021 should chain fallback w/ dynamic URL", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/bar", fn route ->
      send(me, {:intercepted, 1})
      Route.fallback(route, url: server.empty_page)
    end)

    Page.route!(page, "**/foo", fn route ->
      send(me, {:intercepted, 2})
      Route.fallback(route, url: "http://localhost/bar")
    end)

    Page.route!(page, "**/empty.html", fn route ->
      send(me, {:intercepted, 3})
      Route.fallback(route, url: "http://localhost/foo")
    end)

    Page.goto!(page, server.empty_page)
    assert received() == [3, 2, 1]
  end

  test "RO-022 should work with redirects for subresources", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      Route.continue(route)
      send(me, {:intercepted, Route.request(route)})
    end)

    TestServer.set_redirect(server, "/one-style.css", "/two-style.css")
    TestServer.set_redirect(server, "/two-style.css", "/three-style.css")
    TestServer.set_redirect(server, "/three-style.css", "/four-style.css")
    TestServer.set_route(server, "/four-style.css", &Plug.Conn.send_resp(&1, 200, "body {box-sizing: border-box; }"))

    response = Page.goto!(page, server.prefix <> "/one-style.html")
    assert Response.status(response) == 200
    assert Response.url(response) =~ "one-style.html"

    intercepted = received()
    assert length(intercepted) == 2
    assert Request.resource_type(Enum.at(intercepted, 0)) == "document"
    assert Request.url(Enum.at(intercepted, 0)) =~ "one-style.html"

    r =
      Enum.reduce(
        ["/one-style.css", "/two-style.css", "/three-style.css", "/four-style.css"],
        Enum.at(intercepted, 1),
        fn
          url, r ->
            assert Request.resource_type(r) == "stylesheet"
            assert Request.url(r) =~ url
            Request.redirected_to(r)
        end
      )

    assert r == nil
  end

  test "RO-023 should work with equal requests", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    {:ok, response_count} = Agent.start_link(fn -> 1 end)

    TestServer.set_route(server, "/zzz", fn conn ->
      count = Agent.get_and_update(response_count, &{&1, &1 + 1})
      Plug.Conn.send_resp(conn, 200, "#{count * 11}")
    end)

    {:ok, spinner} = Agent.start_link(fn -> false end)

    # Cancel 2nd request.
    Page.route!(page, "**/*", fn route ->
      if Agent.get_and_update(spinner, &{&1, !&1}), do: Route.abort(route), else: Route.continue(route)
    end)

    results =
      for _i <- 0..2,
          do: Page.evaluate!(page, "() => fetch('/zzz').then(response => response.text()).catch(e => 'FAILED')")

    assert results == ["11", "FAILED", "22"]
  end

  test "RO-024 should navigate to dataURL and not fire dataURL requests", %{page: page} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Route.request(route)})
      Route.continue(route)
    end)

    data_url = "data:text/html,<div>yo</div>"
    response = Page.goto!(page, data_url)
    assert response == nil
    assert received() == []
  end

  test "RO-025 should be able to fetch dataURL and not fire dataURL requests", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Route.request(route)})
      Route.continue(route)
    end)

    data_url = "data:text/html,<div>yo</div>"
    text = Page.evaluate!(page, "url => fetch(url).then(r => r.text())", data_url)
    assert text == "<div>yo</div>"
    assert received() == []
  end

  test "RO-026 should navigate to URL with hash and and fire requests without hash", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Route.request(route)})
      Route.continue(route)
    end)

    response = Page.goto!(page, server.empty_page <> "#hash")
    assert Response.status(response) == 200
    assert Response.url(response) == server.empty_page
    requests = received()
    assert length(requests) == 1
    assert Request.url(Enum.at(requests, 0)) == server.empty_page
  end

  test "RO-027 should work with encoded server", %{page: page, server: server} do
    # The requestWillBeSent will report encoded URL, whereas interception will
    # report URL as-is. @see crbug.com/759388
    Page.route!(page, "**/*", &Route.continue/1)
    response = Page.goto!(page, server.prefix <> "/some nonexisting page")
    assert Response.status(response) == 404
  end

  test "RO-028 should work with badly encoded server", %{page: page, server: server} do
    TestServer.set_route(server, "/malformed?rnd=%911", &Plug.Conn.send_resp(&1, 200, ""))
    Page.route!(page, "**/*", &Route.continue/1)
    response = Page.goto!(page, server.prefix <> "/malformed?rnd=%911")
    assert Response.status(response) == 200
  end

  test "RO-029 should work with encoded server - 2", %{page: page, server: server} do
    # The requestWillBeSent will report URL as-is, whereas interception will
    # report encoded URL for stylesheet. @see crbug.com/759388
    Page.goto!(page, server.empty_page)
    me = self()

    Page.route!(page, "**/*", fn route ->
      Route.continue(route)
      send(me, {:intercepted, Route.request(route)})
    end)

    Page.set_content!(page, ~s(<link rel="stylesheet" href="#{server.prefix}/fonts?helvetica|arial"/>))
    requests = received()
    assert length(requests) == 1
    assert Response.status(Request.response!(Enum.at(requests, 0))) == 404
  end

  test "RO-030 should not throw \"Invalid Interception Id\" if the request was cancelled", %{page: page, server: server} do
    Page.set_content!(page, "<iframe></iframe>")
    me = self()
    Page.route!(page, "**/*", fn r -> send(me, {:route, r}) end)
    # Wait for request interception.
    Page.expect_event!(page, :request, fn ->
      Page.eval_on_selector!(page, "iframe", "(frame, url) => frame.src = url", server.empty_page)
    end)

    assert_receive {:route, route}, 5000
    # Delete frame to cause request to be canceled.
    Page.eval_on_selector!(page, "iframe", "frame => frame.remove()")
    assert Route.continue(route) == :ok
  end

  test "RO-031 should intercept main resource during cross-process navigation", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    me = self()

    Page.route!(page, server.cross_process_prefix <> "/empty.html", fn route ->
      send(me, :intercepted)
      Route.continue(route)
    end)

    response = Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert Response.ok(response) == true
    assert_received :intercepted
  end

  @tag skip:
         if(@browser_name == "webkit",
           do: "upstream fixme: in WebKit the redirects are handled by the network stack and we intercept before"
         )
  test "RO-032 should fulfill with redirect status", %{page: page, server: server} do
    # it.fixme(browserName === 'webkit', 'in WebKit the redirects are handled by the network stack and we intercept before');
    Page.goto!(page, server.prefix <> "/title.html")
    TestServer.set_route(server, "/final", &Plug.Conn.send_resp(&1, 200, "foo"))

    Page.route!(page, "**/*", fn route, request ->
      if Request.url(request) != server.prefix <> "/redirect_this",
        do: Route.continue(route),
        else: Route.fulfill!(route, status: 301, headers: %{"location" => "/final"})
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
        server.prefix <> "/redirect_this"
      )

    assert text == "foo"
  end

  @tag skip:
         if(@browser_name != "webkit",
           do: "upstream skip: we should support fulfill with redirect in webkit and delete this test"
         )
  test "RO-033 should not fulfill with redirect status", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")
    me = self()

    Page.route!(page, "**/*", fn route, request ->
      if Request.url(request) != server.prefix <> "/redirect_this" do
        Route.continue(route)
      else
        send(me, {:route, self()})
        status = receive do: ({:status, status} -> status)

        case Route.fulfill(route, status: status, headers: %{"location" => "/empty.html"}) do
          {:error, e} -> send(me, {:exception, e})
          _ -> send(me, {:reject, "fulfill didn't throw"})
        end
      end
    end)

    for status <- 300..309 do
      Task.start(fn -> Page.evaluate(page, "url => location.href = url", server.prefix <> "/redirect_this") end)
      assert_receive {:route, handler}
      send(handler, {:status, status})

      exception =
        receive do
          {:exception, e} -> e
          {:reject, message} -> flunk(message)
        end

      assert exception
      assert String.contains?(Exception.message(exception), "Cannot fulfill with redirect status")
    end
  end

  test "RO-034 should support cors with GET", %{page: page, server: server, browser_name: browser_name} do
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/cars*", fn route, request ->
      headers = %{
        "access-control-allow-origin" => if(String.ends_with?(Request.url(request), "allow"), do: "*", else: "none")
      }

      Route.fulfill!(route, content_type: "application/json", headers: headers, status: 200, body: @cars)
    end)

    # Should succeed
    resp =
      Page.evaluate!(page, """
      async () => {
        const response = await fetch('https://example.com/cars?allow', { mode: 'cors' });
        return response.json();
      }
      """)

    assert resp == ["electric", "gas"]

    # Should be rejected
    {:error, error} =
      Page.evaluate(page, """
      async () => {
        const response = await fetch('https://example.com/cars?reject', { mode: 'cors' });
        return response.json();
      }
      """)

    if browser_name == "chromium", do: assert(Exception.message(error) =~ "Failed")
    if browser_name == "webkit", do: assert(Exception.message(error) =~ "TypeError")
    if browser_name == "firefox", do: assert(Exception.message(error) =~ "NetworkError")
  end

  test "RO-035 should add Access-Control-Allow-Origin by default when fulfill", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/cars", fn route ->
      Route.fulfill!(route, content_type: "application/json", status: 200, body: @cars)
    end)

    response = Page.wait_for_response(page, "https://example.com/cars")

    result =
      Page.evaluate!(page, """
      async () => {
        const response = await fetch('https://example.com/cars', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          mode: 'cors',
          body: JSON.stringify({ 'number': 1 })
        });
        return response.json();
      }
      """)

    response = Promise.await!(response)
    assert result == ["electric", "gas"]
    assert Response.header_value!(response, "Access-Control-Allow-Origin") == server.prefix
  end

  test "RO-036 should allow null origin for about:blank", %{page: page, server: server} do
    Page.route!(page, "**/something", fn route ->
      Route.fulfill!(route, content_type: "text/plain", status: 200, body: "done")
    end)

    response = Page.wait_for_response(page, server.cross_process_prefix <> "/something")

    text =
      Page.evaluate!(
        page,
        """
        async url => {
          const data = await fetch(url, {
            method: 'GET',
            headers: { 'X-PINGOTHER': 'pingpong' }
          });
          return data.text();
        }
        """,
        server.cross_process_prefix <> "/something"
      )

    response = Promise.await!(response)
    assert text == "done"
    assert Response.header_value!(response, "Access-Control-Allow-Origin") == "null"
  end

  test "RO-037 should respect cors overrides", %{page: page, server: server, browser_name: browser_name} do
    # it.fail(isAndroid, 'no cors error in android emulator');
    Page.goto!(page, server.empty_page)

    TestServer.set_route(server, "/something", fn conn ->
      if conn.method == "OPTIONS" do
        conn
        |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
        |> Plug.Conn.put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS, DELETE")
        |> Plug.Conn.put_resp_header("access-control-allow-headers", "*")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.send_resp(204, "")
      else
        conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(404, "NOT FOUND")
      end
    end)

    # Fetch request should fail when CORS header doesn't include the origin.
    Page.route!(page, "**/something", fn route ->
      Route.fulfill!(route,
        content_type: "text/plain",
        status: 200,
        headers: %{"Access-Control-Allow-Origin" => "http://non-existent"},
        body: "done"
      )
    end)

    {:error, error} =
      Page.evaluate(
        page,
        """
        async url => {
          const data = await fetch(url, {
            method: 'GET',
            headers: { 'X-PINGOTHER': 'pingpong' }
          });
          return data.text();
        }
        """,
        server.cross_process_prefix <> "/something"
      )

    cond do
      browser_name == "chromium" -> assert Exception.message(error) =~ "Failed to fetch"
      browser_name == "webkit" -> assert Exception.message(error) =~ "Load failed"
      browser_name == "firefox" -> assert Exception.message(error) =~ "NetworkError when attempting to fetch resource."
    end
  end

  defp options_route(server, me) do
    TestServer.set_route(server, "/something", fn conn ->
      send(me, {:intercepted, conn.method <> ":" <> conn.request_path})

      if conn.method == "OPTIONS" do
        conn
        |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
        |> Plug.Conn.put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS, DELETE")
        |> Plug.Conn.put_resp_header("access-control-allow-headers", "*")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.send_resp(200, "Hello")
      else
        conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(200, "World")
      end
    end)
  end

  @options_fetch """
  async url => {
    const response1 = await fetch(url, { method: 'OPTIONS' });
    const text1 = await response1.text();
    const response2 = await fetch(url, { method: 'GET' });
    const text2 = await response2.text();
    return [text1, text2];
  }
  """

  test "RO-038 should not auto-intercept non-preflight OPTIONS without network interception", %{
    page: page,
    server: server
  } do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/20469' });
    Page.goto!(page, server.empty_page)
    options_route(server, self())

    # Without interception.
    [text1, text2] = Page.evaluate!(page, @options_fetch, server.cross_process_prefix <> "/something")
    assert text1 == "Hello"
    assert text2 == "World"
    # Preflight for OPTIONS, then OPTIONS, then GET without preflight.
    assert received() == ["OPTIONS:/something", "OPTIONS:/something", "GET:/something"]
  end

  # Make sure this runs in a new context as preflight results could be cached.
  test "RO-039 should not auto-intercept non-preflight OPTIONS with network interception", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/20469' });
    Page.goto!(page, server.empty_page)
    options_route(server, self())

    # With interception.
    Page.route!(page, "**/something", &Route.continue/1)

    [text1, text2] = Page.evaluate!(page, @options_fetch, server.cross_process_prefix <> "/something")
    assert text1 == "Hello"
    assert text2 == "World"
    # Preflight for OPTIONS is auto-fulfilled, then OPTIONS, then GET without preflight.
    # isBidi  -- not ported: no BiDi
    if browser_name == "chromium",
      do: assert(received() == ["OPTIONS:/something", "GET:/something"]),
      else: assert(received() == ["OPTIONS:/something", "OPTIONS:/something", "GET:/something"])
  end

  test "RO-040 should support cors with POST", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/cars", fn route ->
      Route.fulfill!(route,
        content_type: "application/json",
        headers: %{"Access-Control-Allow-Origin" => "*"},
        status: 200,
        body: @cars
      )
    end)

    resp =
      Page.evaluate!(page, """
      async () => {
        const response = await fetch('https://example.com/cars', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          mode: 'cors',
          body: JSON.stringify({ 'number': 1 })
        });
        return response.json();
      }
      """)

    assert resp == ["electric", "gas"]
  end

  test "RO-041 should support cors with credentials", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/cars", fn route ->
      Route.fulfill!(route,
        content_type: "application/json",
        headers: %{
          "Access-Control-Allow-Origin" => server.prefix,
          "Access-Control-Allow-Credentials" => "true"
        },
        status: 200,
        body: @cars
      )
    end)

    resp =
      Page.evaluate!(page, """
      async () => {
        const response = await fetch('https://example.com/cars', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          mode: 'cors',
          body: JSON.stringify({ 'number': 1 }),
          credentials: 'include'
        });
        return response.json();
      }
      """)

    assert resp == ["electric", "gas"]
  end

  # Returns `{true, conn}` when the (preflight) request was answered.
  defp allow_cors(conn) do
    origin = conn |> Plug.Conn.get_req_header("origin") |> List.first() || "*"

    conn =
      conn
      |> Plug.Conn.put_resp_header("access-control-allow-origin", origin)
      |> Plug.Conn.put_resp_header("access-control-allow-credentials", "true")
      |> Plug.Conn.put_resp_header("access-control-allow-headers", "x-app-version")

    if conn.method != "OPTIONS", do: {false, conn}, else: {true, Plug.Conn.send_resp(conn, 204, "")}
  end

  test "RO-042 should not abort preflighted cross-origin redirect when a route is registered", %{
    page: page,
    server: server
  } do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43242' }
    TestServer.set_route(server, "/download", fn conn ->
      case allow_cors(conn) do
        {true, conn} ->
          conn

        {false, conn} ->
          conn |> Plug.Conn.put_resp_header("location", "#{server.prefix}/file") |> Plug.Conn.send_resp(302, "")
      end
    end)

    TestServer.set_route(server, "/file", fn conn ->
      case allow_cors(conn) do
        {true, conn} -> conn
        {false, conn} -> Plug.Conn.send_resp(conn, 200, "file contents")
      end
    end)

    Page.goto!(page, server.empty_page)
    Page.route!(page, "**/never-matches", &Route.continue/1)

    result =
      Page.evaluate!(
        page,
        """
        async url => {
          const response = await fetch(url, { credentials: 'include', headers: { 'X-App-Version': '1.2.3' } });
          return `${response.status} ${await response.text()}`;
        }
        """,
        server.cross_process_prefix <> "/download"
      )

    assert result == "200 file contents"
  end

  test "RO-043 should reject cors with disallowed credentials", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/cars", fn route ->
      Route.fulfill!(route,
        content_type: "application/json",
        headers: %{
          "Access-Control-Allow-Origin" => server.prefix
          # Should fail without this line below!
          # 'Access-Control-Allow-Credentials': 'true'
        },
        status: 200,
        body: @cars
      )
    end)

    error =
      case Page.evaluate(page, """
           async () => {
             const response = await fetch('https://example.com/cars', {
               method: 'POST',
               headers: { 'Content-Type': 'application/json' },
               mode: 'cors',
               body: JSON.stringify({ 'number': 1 }),
               credentials: 'include'
             });
             return response.json();
           }
           """) do
        {:error, e} -> e
        {:ok, _} -> ""
      end

    assert error != ""
  end

  test "RO-044 should support cors for different methods", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/cars", fn route, request ->
      Route.fulfill!(route,
        content_type: "application/json",
        headers: %{"Access-Control-Allow-Origin" => "*"},
        status: 200,
        body: JSON.encode!([Request.method(request), "electric", "gas"])
      )
    end)

    # First POST
    resp =
      Page.evaluate!(page, """
      async () => {
        const response = await fetch('https://example.com/cars', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          mode: 'cors',
          body: JSON.stringify({ 'number': 1 })
        });
        return response.json();
      }
      """)

    assert resp == ["POST", "electric", "gas"]

    # Then DELETE
    resp =
      Page.evaluate!(page, """
      async () => {
        const response = await fetch('https://example.com/cars', {
          method: 'DELETE',
          headers: {},
          mode: 'cors',
          body: ''
        });
        return response.json();
      }
      """)

    assert resp == ["DELETE", "electric", "gas"]
  end

  test "RO-045 should support the times parameter with route matching", %{page: page, server: server} do
    me = self()

    Page.route!(
      page,
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

  test "RO-046 should work if handler with times parameter was removed from another handler", %{
    page: page,
    server: server
  } do
    me = self()

    handler = fn route ->
      send(me, {:intercepted, "first"})
      Route.continue(route)
    end

    Page.route!(page, "**/*", handler, times: 1)

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, "second"})
      Page.unroute!(page, "**/*", handler)
      Route.fallback!(route)
    end)

    Page.goto!(page, server.empty_page)
    assert received() == ["second"]
    Page.goto!(page, server.empty_page)
    assert received() == ["second"]
  end

  test "RO-047 should support async handler w/ times", %{page: page, server: server} do
    Page.route!(
      page,
      "**/empty.html",
      fn route ->
        Process.sleep(100)
        Route.fulfill!(route, body: "<html>intercepted</html>", content_type: "text/html")
      end,
      times: 1
    )

    Page.goto!(page, server.empty_page)
    Expect.to_have_text!(Page.locator(page, "body"), "intercepted")
    Page.goto!(page, server.empty_page)
    Expect.not_to_have_text!(Page.locator(page, "body"), "intercepted")
  end

  @tag skip:
         if(@browser_name == "chromium" and @browser_major_version < 155,
           do:
             "upstream skip: Chromium drops a request that is intercepted while Fetch.disable is being processed; fix is not rolled yet"
         )
  test "RO-048 route abort with times: 1 should not affect second sequential fetch", %{
    page: page,
    server: server
  } do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/41802' });
    TestServer.set_route(server, "/data", fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_resp(200, "ok")
    end)

    Page.goto!(page, server.empty_page)
    Page.route!(page, "**/data", &Route.abort(&1, "timedout"), times: 1)

    results =
      Page.evaluate!(page, """
      async () => {
        async function fetchOrHung(url) {
          const timeout = new Promise(resolve => setTimeout(() => resolve('hung'), 3000));
          const request = fetch(url).then(r => String(r.status)).catch(() => 'aborted');
          return Promise.race([request, timeout]);
        }
        const first = await fetchOrHung('/data');
        const second = await fetchOrHung('/data');
        return [first, second];
      }
      """)

    assert results == ["aborted", "200"]
  end

  test "RO-049 should contain raw request header", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Request.all_headers!(Route.request(route))})
      Route.continue(route)
    end)

    Page.goto!(page, server.prefix <> "/empty.html")
    headers = List.last(received())
    Utils.assert_truthy(headers["accept"])
  end

  test "RO-050 should contain sec-fetch headers in route", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42620' });
    # it.fail(browserName === 'chromium', 'Fetch.requestPaused fires before Chromium attaches Fetch Metadata headers')
    expected_failure(@browser_name == "chromium", fn ->
      sec_fetch = fn headers ->
        Map.new(
          for {name, value} <- headers, String.starts_with?(String.downcase(name), "sec-fetch-"), do: {name, value}
        )
      end

      modes = ["cors", "no-cors", "same-origin"]

      Page.goto!(page, server.empty_page)

      me = self()

      Page.route!(page, "**/probe-*", fn route ->
        request = Route.request(route)
        path = URI.parse(Request.url(request)).path

        send(
          me,
          {:routed, path,
           %{headers: sec_fetch.(Request.headers(request)), all_headers: sec_fetch.(Request.all_headers!(request))}}
        )

        Route.continue(route)
      end)

      server_requests = for mode <- modes, do: TestServer.wait_for_request(server, "/probe-#{mode}")

      Page.evaluate!(
        page,
        """
        async modes => {
          for (const mode of modes)
            await (await fetch(`/probe-${mode}`, { mode })).text();
        }
        """,
        modes
      )

      server_requests = Task.await_many(server_requests, :infinity)

      routed =
        for _ <- modes, into: %{} do
          assert_receive {:routed, path, headers}
          {path, headers}
        end

      # expect.soft: every mismatch is reported.
      failures =
        for {mode, server_request} <- Enum.zip(modes, server_requests),
            path = "/probe-#{mode}",
            on_server = sec_fetch.(server_request.req_headers),
            {what, actual, expected} <- [
              {"on server", on_server,
               %{"sec-fetch-site" => "same-origin", "sec-fetch-mode" => mode, "sec-fetch-dest" => "empty"}},
              # The route handler should see the same headers.
              {"route.request().headers()", routed[path].headers, on_server},
              {"route.request().allHeaders()", routed[path].all_headers, on_server}
            ],
            actual != expected,
            do: "#{path} #{what}: #{inspect(actual)} != #{inspect(expected)}"

      assert failures == []
    end)
  end

  test "RO-051 should contain raw response header", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Route.request(route)})
      Route.continue(route)
    end)

    Page.goto!(page, server.prefix <> "/empty.html")
    request = List.last(received())
    response = Request.response!(request)
    headers = Response.all_headers!(response)
    Utils.assert_truthy(headers["content-type"])
  end

  test "RO-052 should contain raw response header after fulfill", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:intercepted, Route.request(route)})
      Route.fulfill!(route, status: 200, body: "Hello", content_type: "text/html")
    end)

    Page.goto!(page, server.prefix <> "/empty.html")
    request = List.last(received())
    response = Request.response!(request)
    headers = Response.all_headers!(response)
    Utils.assert_truthy(headers["content-type"])
  end

  for method <- [:fulfill, :continue, :fallback, :abort] do
    @method method
    test "RO-053 route.#{method} should throw if called twice", %{page: page, server: server} do
      me = self()
      Page.route!(page, "**/*", &send(me, {:route, &1}))
      Runtime.Promise.void(fn -> Page.goto(page, server.prefix <> "/empty.html") end)
      assert_receive {:route, route}, 5000
      apply(Route, :"#{@method}!", [route])
      {:error, e} = apply(Route, @method, [route])
      assert Exception.message(e) =~ "Route is already handled!"
    end
  end

  test "RO-054 should intercept when postData is more than 1MB", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/22753' });
    Page.goto!(page, server.empty_page)
    me = self()
    # 2MB
    post_body = String.duplicate("0", 2 * 1024 * 1024)

    Page.route!(page, "**/404.html", fn route ->
      Route.abort!(route)
      send(me, {:post_data, Request.post_data(Route.request(route))})
    end)

    Page.evaluate!(
      page,
      """
      POST_BODY => fetch('/404.html', {
        method: 'POST',
        body: POST_BODY,
      }).catch(e => {})
      """,
      post_body
    )

    assert_receive {:post_data, post_data}
    assert post_data == post_body
  end

  test "RO-055 should be able to intercept every navigation to a page controlled by service worker", %{
    page: page,
    server: server
  } do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/33561' });
    me = self()
    url = server.prefix <> "/serviceworkers/bug-33561/index.html"

    Page.route!(page, url, fn route ->
      send(me, {:intercepted, 1})
      Route.continue!(route)
    end)

    Page.goto!(page, url)
    Page.evaluate!(page, "() => window['activationPromise']")
    Page.goto!(page, url)
    assert length(received()) == 2
  end

  test "RO-056 should respect URLPattern ignoreCase"
end
