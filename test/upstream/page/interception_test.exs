defmodule PlaywrightEx.Page.InterceptionTest do
  @upstream "tests/page/interception.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  # `const intercepted = []; ... intercepted.push(x)`: the handlers send to the test process.
  defp received(acc \\ []) do
    receive do
      {:intercepted, x} -> received([x | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "should work with navigation @smoke", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(
        me,
        {:intercepted,
         {route |> Route.request() |> Request.url() |> String.split("/") |> List.last(), Route.request(route)}}
      )

      Route.continue(route)
    end)

    TestServer.set_redirect(server, "/rrredirect", "/frames/one-frame.html")
    Page.goto!(page, server.prefix <> "/rrredirect")
    requests = Map.new(received())
    assert Request.is_navigation_request(requests["rrredirect"]) == true
    assert Request.is_navigation_request(requests["frame.html"]) == true
    assert Request.is_navigation_request(requests["script.js"]) == false
    assert Request.is_navigation_request(requests["style.css"]) == false
  end

  test "should intercept after a service worker", %{page: page, server: server, browser_name: browser_name} do
    Page.goto!(page, server.prefix <> "/serviceworkers/fetchdummy/sw.html")
    Page.evaluate!(page, "() => window['activationPromise']")

    # Sanity check.
    sw_response = Page.evaluate!(page, "() => window['fetchDummy']('foo')")
    assert sw_response == "responseFromServiceWorker:foo"

    Page.route!(page, "**/foo", fn route ->
      url = Request.url(Route.request(route))
      name = url |> String.split("/") |> List.last()
      Route.fulfill(route, status: 200, content_type: "text/css", body: "responseFromInterception:" <> name)
    end)

    # Page route is applied after service worker fetch event.
    sw_response2 = Page.evaluate!(page, "() => window['fetchDummy']('foo')")
    assert sw_response2 == "responseFromServiceWorker:foo"

    # Page route is not applied to service worker initiated fetch.
    non_intercepted_response = Page.evaluate!(page, "() => window['fetchDummy']('passthrough')")
    assert non_intercepted_response == "FAILURE: Not Found"

    # Firefox/Juggler does not want to fetch the redirect for some reason.
    # isBidi  -- not ported: no BiDi
    if browser_name != "firefox" do
      # Page route is not applied to service worker initiated fetch with redirect.
      TestServer.set_redirect(server, "/serviceworkers/fetchdummy/passthrough", "/simple.json")
      redirected_response = Page.evaluate!(page, "() => window['fetchDummy']('passthrough')")
      assert redirected_response == ~s({"foo": "bar"}\n)
    end
  end

  @tag skip: "not ported: globToRegexPattern, urlMatches (the driver converts globs)"
  test "should work with glob"

  @tag skip: "not ported: globToRegexPattern, urlMatches (the driver converts globs)"
  test "should throw on unbalanced glob braces"

  test "should throw on page.route with invalid glob", %{page: page} do
    assert {:error, e} = Page.route(page, "http://*/foo{", &Route.continue/1)
    assert Exception.message(e) =~ "unmatched '{'"
  end

  test "should intercept by glob", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.route!(page, "http://localhos**?*oo", fn route -> Route.fulfill!(route, status: 200, body: "intercepted") end)
    result = Page.evaluate!(page, "url => fetch(url).then(r => r.text())", server.prefix <> "/?foo")
    assert result == "intercepted"
  end

  test "should intercept network activity from worker", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/data_for_worker", &Plug.Conn.send_resp(&1, 200, "failed to intercept"))
    url = server.prefix <> "/data_for_worker"
    Page.route!(page, url, fn route -> Route.fulfill(route, status: 200, body: "intercepted") end)

    msg =
      Page.expect_event!(page, :console, fn ->
        Page.evaluate!(
          page,
          """
          url => new Worker(URL.createObjectURL(new Blob([`
            fetch("${url}").then(response => response.text()).then(console.log);
          `], { type: 'application/javascript' })))
          """,
          url
        )
      end)

    assert ConsoleMessage.text(msg) == "intercepted"
  end

  test "should intercept worker requests when enabled after worker creation", %{
    page: page,
    server: server,
    browser_name: browser_name,
    browser: browser
  } do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/32355' }
    major = browser |> Browser.version() |> String.split(".") |> hd() |> String.to_integer()

    # it.skip(browserName === 'chromium' && browserMajorVersion < 130, 'fixed in Chromium 130');
    if !(browser_name == "chromium" and major < 130) do
      Page.goto!(page, server.empty_page)
      TestServer.set_route(server, "/data_for_worker", &Plug.Conn.send_resp(&1, 200, "failed to intercept"))
      url = server.prefix <> "/data_for_worker"

      Page.expect_event!(page, :worker, fn ->
        Page.evaluate!(
          page,
          """
          url => {
            window.w = new Worker(URL.createObjectURL(new Blob([`
              onmessage = function(e) {
                fetch("${url}").then(response => response.text()).then(console.log);
              };
            `], { type: 'application/javascript' })));
          }
          """,
          url
        )
      end)

      # Install the route **after** the worker has been created.
      Page.route!(page, url, fn route -> Route.fulfill(route, status: 200, body: "intercepted") end)

      msg = Page.expect_event!(page, :console, fn -> Page.evaluate!(page, "() => window.w.postMessage('')") end)
      assert ConsoleMessage.text(msg) == "intercepted"
    end
  end

  test "should intercept network activity from worker 2", %{page: page, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/31747' }
    url = server.prefix <> "/worker/worker.js"

    Page.route!(page, url, fn route ->
      Route.fulfill(route, status: 200, body: ~s[console.log("intercepted");], content_type: "application/javascript")
    end)

    msg = Page.expect_event!(page, :console, fn -> Page.goto!(page, server.prefix <> "/worker/worker.html") end)
    assert ConsoleMessage.text(msg) == "intercepted"
  end

  # `vm.runInContext('new RegExp(...)')`: no cross-realm regexes in Elixir, a plain Regex.
  test "should work with regular expression passed from a different context", %{page: page, server: server} do
    regexp = Regex.compile!("empty\\.html")
    me = self()

    Page.route!(page, regexp, fn route, request ->
      send(me, {:intercepted, {route, request, Frame.url(Request.frame(request))}})
      Route.continue(route)
    end)

    response = Page.goto!(page, server.empty_page)
    assert [{route, request, frame_url}] = received()
    assert Route.request(route) == request
    assert Request.url(request) =~ "empty.html"
    assert Request.headers(request)["user-agent"]
    assert Request.method(request) == "GET"
    assert Request.post_data(request) == nil
    assert Request.is_navigation_request(request) == true
    assert Request.resource_type(request) == "document"
    assert Request.frame(request) == Page.main_frame(page)
    assert frame_url == "about:blank"
    assert Response.ok(response) == true
  end

  # `/\/intercept-me/g`: Elixir regexes have no global flag (nor `lastIndex`).
  test "should intercept every request matching a global regexp", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    me = self()

    Page.route!(page, ~r/\/intercept-me/, fn route ->
      send(me, {:intercepted, 1})
      Route.fulfill!(route, body: "intercepted")
    end)

    url = server.prefix <> "/intercept-me"

    for _i <- 0..2,
        do:
          assert(Page.evaluate!(page, "u => fetch(u, { cache: 'no-store' }).then(r => r.text())", url) == "intercepted")

    assert length(received()) == 3
  end

  @tag skip: "not ported: ElementHandle"
  test "should not break remote worker importScripts"

  @tag skip: "not ported: expect"
  test "should disable memory cache when intercepting"

  @tag skip: "upstream skip: browserName !== 'webkit'"
  test "should intercept blob url requests"
end
