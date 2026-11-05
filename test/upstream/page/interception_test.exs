defmodule PlaywrightEx.Page.InterceptionTest do
  @upstream "tests/page/interception.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.PlaywrightError
  alias PlaywrightEx.Client.LocalUtils
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.TestServer

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

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

  # Deviation: the driver converts globs (`LocalUtils.globToRegex`, PLAN), as in the non-JS clients.
  defp local_utils(playwright),
    do: PlaywrightEx.Client.Connection.local_utils(PlaywrightEx.Runtime.Heap.get(playwright, :_connection))

  defp glob_to_regex_pattern(playwright, glob) do
    local_utils = local_utils(playwright)
    Api.call(nil, local_utils, fn -> LocalUtils.glob_to_regex(local_utils, %{glob: glob}) end)
  end

  defp url_matches(playwright, base_url, url, match) do
    local_utils = local_utils(playwright)
    Api.call(nil, local_utils, fn -> UrlMatch.url_matches(local_utils, base_url, url, match) end)
  end

  test "should work with glob", %{playwright: playwright} do
    glob_to_regex = fn glob -> Regex.compile!(glob_to_regex_pattern(playwright, glob)) end
    url_matches = &url_matches(playwright, &1, &2, &3)

    assert Regex.match?(glob_to_regex.("**/*.js"), "https://localhost:8080/foo.js")
    refute Regex.match?(glob_to_regex.("**/*.css"), "https://localhost:8080/foo.js")
    refute Regex.match?(glob_to_regex.("*.js"), "https://localhost:8080/foo.js")
    assert Regex.match?(glob_to_regex.("https://**/*.js"), "https://localhost:8080/foo.js")

    assert Regex.match?(
             glob_to_regex.("http://localhost:8080/simple/path.js"),
             "http://localhost:8080/simple/path.js"
           )

    assert Regex.match?(glob_to_regex.("**/{a,b}.js"), "https://localhost:8080/a.js")
    assert Regex.match?(glob_to_regex.("**/{a,b}.js"), "https://localhost:8080/b.js")
    refute Regex.match?(glob_to_regex.("**/{a,b}.js"), "https://localhost:8080/c.js")

    assert Regex.match?(glob_to_regex.("**/*.{png,jpg,jpeg}"), "https://localhost:8080/c.jpg")
    assert Regex.match?(glob_to_regex.("**/*.{png,jpg,jpeg}"), "https://localhost:8080/c.jpeg")
    assert Regex.match?(glob_to_regex.("**/*.{png,jpg,jpeg}"), "https://localhost:8080/c.png")
    refute Regex.match?(glob_to_regex.("**/*.{png,jpg,jpeg}"), "https://localhost:8080/c.css")
    assert Regex.match?(glob_to_regex.("foo*"), "foo.js")
    refute Regex.match?(glob_to_regex.("foo*"), "foo/bar.js")
    refute Regex.match?(glob_to_regex.("http://localhost:3000/signin-oidc*"), "http://localhost:3000/signin-oidc/foo")
    assert Regex.match?(glob_to_regex.("http://localhost:3000/signin-oidc*"), "http://localhost:3000/signin-oidcnice")

    assert Regex.match?(glob_to_regex.("**/*.js"), "/foo.js")
    refute Regex.match?(glob_to_regex.("asd/**.js"), "/foo.js")
    refute Regex.match?(glob_to_regex.("**/*.js"), "bar_foo.js")

    # range [] is NOT supported
    assert Regex.match?(glob_to_regex.("**/api/v[0-9]"), "http://example.com/api/v[0-9]")
    refute Regex.match?(glob_to_regex.("**/api/v[0-9]"), "http://example.com/api/version")

    # query params
    assert Regex.match?(glob_to_regex.("**/api\\?param"), "http://example.com/api?param")
    refute Regex.match?(glob_to_regex.("**/api\\?param"), "http://example.com/api-param")

    assert Regex.match?(
             glob_to_regex.("**/three-columns/settings.html\\?**id=settings-**"),
             "http://mydomain:8080/blah/blah/three-columns/settings.html?id=settings-e3c58efe-02e9-44b0-97ac-dd138100cf7c&blah"
           )

    # toEqual(/.../): the regex sources.
    assert glob_to_regex_pattern(playwright, "\\?") == ~S"^\?$"
    assert glob_to_regex_pattern(playwright, "\\") == ~S"^\\$"
    assert glob_to_regex_pattern(playwright, "\\\\") == ~S"^\\$"
    assert glob_to_regex_pattern(playwright, "\\[") == ~S"^\[$"
    assert glob_to_regex_pattern(playwright, "[a-z]") == ~S"^\[a-z\]$"
    assert glob_to_regex_pattern(playwright, "$^+.\\*()|\\?\\{\\}\\[\\]") == ~S"^\$\^\+\.\*\(\)\|\?\{\}\[\]$"

    assert url_matches.(nil, "http://playwright.dev/", "http://playwright.dev")
    assert url_matches.(nil, "http://playwright.dev/?a=b", "http://playwright.dev?a=b")
    assert url_matches.(nil, "http://playwright.dev/", "h*://playwright.dev")
    assert url_matches.(nil, "http://api.playwright.dev/?x=y", "http://*.playwright.dev?x=y")
    assert url_matches.(nil, "http://playwright.dev/foo/bar", "**/foo/**")
    assert url_matches.("http://playwright.dev", "http://playwright.dev/?x=y", "?x=y")
    assert url_matches.("http://playwright.dev/foo/", "http://playwright.dev/foo/bar?x=y", "./bar?x=y")

    # '$$', '$&', '$`' and "$'" are special in String.prototype.replace with a string argument.
    assert url_matches.(nil, "http://playwright.dev/foo$$bar", "http://playwright.dev/foo$$bar")
    assert url_matches.(nil, "http://playwright.dev/a$&b", "http://playwright.dev/a$&b")
    assert url_matches.("http://playwright.dev", "http://playwright.dev/p$$q", "./p$$q")

    # Case insensitive matching
    assert url_matches.(nil, "https://playwright.dev/fooBAR", "HtTpS://pLaYwRiGhT.dEv/fooBAR")
    assert url_matches.("http://ignored", "https://playwright.dev/fooBAR", "HtTpS://pLaYwRiGhT.dEv/fooBAR")
    # Path and search query are case-sensitive
    refute url_matches.(nil, "https://playwright.dev/foobar", "https://playwright.dev/fooBAR")
    refute url_matches.(nil, "https://playwright.dev/foobar?a=b", "https://playwright.dev/foobar?A=B")

    # Literal globs are normalized through new URL(), so explicit default ports,
    # percent-encoding and IDN hosts match request.url() which is already normalized.
    assert url_matches.(nil, "http://example.com/path", "http://example.com:80/path")
    assert url_matches.(nil, "https://example.com/path", "https://example.com:443/path")
    assert url_matches.(nil, "http://example.com:8080/path", "http://example.com:8080/path")
    assert url_matches.(nil, "http://localhost/", "http://localhost:80/**")
    assert url_matches.(nil, "http://example.com/foo%20bar", "http://example.com/foo bar")
    assert url_matches.(nil, "http://xn--mnchen-3ya.de/", "http://münchen.de/")

    assert url_matches.(nil, "https://localhost:3000/?a=b", "**/?a=b")
    assert url_matches.(nil, "https://localhost:3000/?a=b", "**?a=b")
    assert url_matches.(nil, "https://localhost:3000/?a=b", "**=b")

    # Custom schema.
    assert url_matches.(nil, "my.custom.protocol://foo", "my.custom.protocol://**")
    refute url_matches.(nil, "my.p://foo", "my.{p,y}://**")
    assert url_matches.(nil, "my.p://foo/", "my.{p,y}://**")
    assert url_matches.(nil, "file:///foo/", "f*e://**")

    # This is not supported, we treat ? as a query separator.
    refute Regex.match?(glob_to_regex.("http://localhost:8080/?imple/path.js"), "http://localhost:8080/Simple/path.js")
    refute url_matches.(nil, "http://playwright.dev/", "http://playwright.?ev")
    assert url_matches.(nil, "http://playwright./?ev", "http://playwright.?ev")
    refute url_matches.(nil, "http://playwright.dev/foo", "http://playwright.dev/f??")
    assert url_matches.(nil, "http://playwright.dev/f??", "http://playwright.dev/f??")
    assert url_matches.(nil, "http://playwright.dev/?x=y", "http://playwright.dev\\?x=y")
    assert url_matches.(nil, "http://playwright.dev/?x=y", "http://playwright.dev/\\?x=y")
    assert url_matches.("http://playwright.dev/foo", "http://playwright.dev/foo?bar", "?bar")
    assert url_matches.("http://playwright.dev/foo", "http://playwright.dev/foo?bar", "\\\\?bar")
    assert url_matches.("http://first.host/", "http://second.host/foo", "**/foo")
    assert url_matches.("http://playwright.dev/", "http://localhost/", "*//localhost/")

    # /**/ should match /.
    assert url_matches.(nil, "https://foo/bar.js", "https://foo/**/bar.js")
    assert url_matches.(nil, "https://foo/bar.js", "https://foo/**/**/bar.js")

    custom_prefixes = ["about", "data", "chrome", "edge", "file"]

    for prefix <- custom_prefixes do
      assert url_matches.("http://playwright.dev/", "#{prefix}:blank", "#{prefix}:blank")
      refute url_matches.("http://playwright.dev/", "#{prefix}:blank", "http://playwright.dev/")
      assert url_matches.(nil, "#{prefix}:blank", "#{prefix}:blank")
      assert url_matches.(nil, "#{prefix}:blank", "#{prefix}:*")
      refute url_matches.(nil, "not#{prefix}:blank", "#{prefix}:*")
    end
  end

  test "should throw on unbalanced glob braces", %{playwright: playwright} do
    glob_to_regex_pattern = &glob_to_regex_pattern(playwright, &1)

    assert_raise PlaywrightError, ~r/Invalid glob pattern "{foo": unmatched '{'/, fn ->
      glob_to_regex_pattern.("{foo")
    end

    assert_raise PlaywrightError, ~r/Invalid glob pattern "}foo": unmatched '}'/, fn ->
      glob_to_regex_pattern.("}foo")
    end

    assert_raise PlaywrightError, ~r/unmatched '{'/, fn -> glob_to_regex_pattern.("http://*/foo{") end
    assert_raise PlaywrightError, ~r/unmatched '{'/, fn -> glob_to_regex_pattern.("**/*.png?{") end
    assert_raise PlaywrightError, ~r/unmatched '{'/, fn -> glob_to_regex_pattern.("https://example.com/{a") end
    assert_raise PlaywrightError, ~r/nested '{' is not supported/, fn -> glob_to_regex_pattern.("{{foo}") end
    # Escaped braces remain literal and must not throw.
    glob_to_regex_pattern.("\\{foo")
    glob_to_regex_pattern.("foo\\}")
  end

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

  @tag skip:
         if(@browser_name == "chromium" and @browser_major_version < 130, do: "upstream skip: fixed in Chromium 130")
  test "should intercept worker requests when enabled after worker creation", %{
    page: page,
    server: server
  } do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/32355' }
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

  test "should not break remote worker importScripts", %{page: page, server: server} do
    Page.route!(page, "**", fn route ->
      Route.continue!(route)
    end)

    Page.goto!(page, server.prefix <> "/worker/worker-http-import.html")
    Page.wait_for_selector!(page, "#status:has-text('finished')")
  end

  test "should disable memory cache when intercepting", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/page.html", fn route ->
      send(me, {:intercepted, 1})
      Route.fulfill(route, body: "success")
    end)

    Page.goto!(page, server.prefix <> "/page.html")
    assert Locator.text_content!(Page.locator(page, "body")) =~ "success"
    Page.goto!(page, server.empty_page)
    Expect.to_have_url!(page, server.empty_page)
    interceted = length(received())
    assert interceted == 1
    Page.go_back!(page)
    Expect.to_have_url!(page, server.prefix <> "/page.html")
    interceted = interceted + length(received())
    assert interceted == 2
  end

  @tag skip: if(@browser_name != "webkit", do: "upstream skip: browserName !== 'webkit'")
  test "should intercept blob url requests", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.route!(page, "**/*", fn route -> Route.fulfill(route, status: 200, body: "intercepted") end)
    Page.on(page, :console, fn msg -> IO.puts(ConsoleMessage.text(msg)) end)

    response =
      Page.evaluate!(page, """
      async () => {
        const blobUrl = URL.createObjectURL(new Blob(['failed to intercept'], { type: 'text/plain' }));
        return await fetch(blobUrl).then(response => response.text());
      }
      """)

    assert response == "intercepted"
  end
end
