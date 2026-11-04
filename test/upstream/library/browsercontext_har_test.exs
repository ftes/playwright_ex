defmodule PlaywrightEx.Library.BrowsercontextHarTest do
  @upstream "tests/library/browsercontext-har.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  # browserTest's `context` fixture.
  @moduletag :page

  # testInfo.outputPath(): a fresh directory per test.
  setup do
    dir = Path.join(System.tmp_dir!(), "playwright_ex-har-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{output_path: &Path.join(dir, &1)}
  end

  # Upstream: `req.destroy()`. Kill the connection's handler process.
  defp destroy_request(_conn), do: Process.exit(self(), :kill)

  defp echo_post_body(conn), do: Plug.Conn.send_resp(conn, 200, conn.assigns.post_body)

  test "should context.routeFromHAR, matching the method and following redirects", %{context: context, asset: asset} do
    path = asset.("har-fulfill.har")
    BrowserContext.route_from_har!(context, path)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://no.playwright/")
    # HAR contains a redirect for the script that should be followed automatically.
    assert Page.evaluate!(page, "window.value") == "foo"
    # HAR contains a POST for the css file that should not be used.
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(255, 0, 0)")
  end

  test "should page.routeFromHAR, matching the method and following redirects", %{context: context, asset: asset} do
    path = asset.("har-fulfill.har")
    page = BrowserContext.new_page!(context)
    Page.route_from_har!(page, path)
    Page.goto!(page, "http://no.playwright/")
    # HAR contains a redirect for the script that should be followed automatically.
    assert Page.evaluate!(page, "window.value") == "foo"
    # HAR contains a POST for the css file that should not be used.
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(255, 0, 0)")
  end

  test "fallback:continue should continue when not found in har", %{context: context, server: server, asset: asset} do
    path = asset.("har-fulfill.har")
    BrowserContext.route_from_har!(context, path, not_found: :fallback)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/one-style.html")
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(255, 192, 203)")
  end

  test "by default should abort requests not found in har", %{context: context, server: server, asset: asset} do
    path = asset.("har-fulfill.har")
    BrowserContext.route_from_har!(context, path)
    page = BrowserContext.new_page!(context)
    {:error, error} = Page.goto(page, server.empty_page)
    assert is_exception(error)
  end

  test "fallback:continue should continue requests on bad har", %{
    context: context,
    server: server,
    output_path: output_path
  } do
    path = output_path.("test.har")
    File.write!(path, JSON.encode!(%{log: %{}}))
    BrowserContext.route_from_har!(context, path, not_found: :fallback)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/one-style.html")
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(255, 192, 203)")
  end

  test "should only handle requests matching url filter", %{context: context, asset: asset} do
    path = asset.("har-fulfill.har")
    BrowserContext.route_from_har!(context, path, not_found: :fallback, url: "**/*.js")
    page = BrowserContext.new_page!(context)

    BrowserContext.route!(context, "http://no.playwright/", fn route ->
      assert Request.url(Route.request(route)) == "http://no.playwright/"

      Route.fulfill!(route,
        status: 200,
        content_type: "text/html",
        body: ~s(<script src="./script.js"></script><div>hello</div>)
      )
    end)

    Page.goto!(page, "http://no.playwright/")
    # HAR contains a redirect for the script that should be followed automatically.
    assert Page.evaluate!(page, "window.value") == "foo"
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgba(0, 0, 0, 0)")
  end

  test "should only context.routeFromHAR requests matching url filter", %{context: context, asset: asset} do
    path = asset.("har-fulfill.har")
    BrowserContext.route_from_har!(context, path, url: "**/*.js")
    page = BrowserContext.new_page!(context)

    BrowserContext.route!(context, "http://no.playwright/", fn route ->
      assert Request.url(Route.request(route)) == "http://no.playwright/"

      Route.fulfill!(route,
        status: 200,
        content_type: "text/html",
        body: ~s(<script src="./script.js"></script><div>hello</div>)
      )
    end)

    Page.goto!(page, "http://no.playwright/")
    # HAR contains a redirect for the script that should be followed automatically.
    assert Page.evaluate!(page, "window.value") == "foo"
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgba(0, 0, 0, 0)")
  end

  test "should only page.routeFromHAR requests matching url filter", %{context: context, asset: asset} do
    path = asset.("har-fulfill.har")
    page = BrowserContext.new_page!(context)
    Page.route_from_har!(page, path, url: "**/*.js")

    BrowserContext.route!(context, "http://no.playwright/", fn route ->
      assert Request.url(Route.request(route)) == "http://no.playwright/"

      Route.fulfill!(route,
        status: 200,
        content_type: "text/html",
        body: ~s(<script src="./script.js"></script><div>hello</div>)
      )
    end)

    Page.goto!(page, "http://no.playwright/")
    # HAR contains a redirect for the script that should be followed automatically.
    assert Page.evaluate!(page, "window.value") == "foo"
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgba(0, 0, 0, 0)")
  end

  test "should apply overrides before routing from har", %{context: context, asset: asset} do
    path = asset.("har-fulfill.har")
    BrowserContext.route_from_har!(context, path, url: "**/*.js")
    page = BrowserContext.new_page!(context)

    BrowserContext.route!(context, "http://no.playwright/my-script.js", fn route ->
      Route.fallback!(route, url: "http://no.playwright/script2.js")
    end)

    BrowserContext.route!(context, "http://test.example/", fn route ->
      Route.fulfill!(route,
        status: 200,
        content_type: "text/html",
        body: ~s(<script src="http://no.playwright/my-script.js"></script><div>hello</div>)
      )
    end)

    Page.goto!(page, "http://test.example/")
    # HAR contains script2.js that sets the value.
    assert Page.evaluate!(page, "window.value") == "foo"
  end

  test "should support regex filter", %{context: context, asset: asset} do
    path = asset.("har-fulfill.har")
    BrowserContext.route_from_har!(context, path, url: ~r/.*(\.js|.*\.css|no.playwright\/)$/)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://no.playwright/")
    assert Page.evaluate!(page, "window.value") == "foo"
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(255, 0, 0)")
  end

  test "newPage should fulfill from har, matching the method and following redirects", %{
    browser: browser,
    asset: asset
  } do
    path = asset.("har-fulfill.har")
    page = Browser.new_page!(browser)
    Page.route_from_har!(page, path)
    Page.goto!(page, "http://no.playwright/")
    # HAR contains a redirect for the script that should be followed automatically.
    assert Page.evaluate!(page, "window.value") == "foo"
    # HAR contains a POST for the css file that should not be used.
    Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(255, 0, 0)")
    Page.close!(page)
  end

  test "should change document URL after redirected navigation", %{context: context, asset: asset} do
    path = asset.("har-redirect.har")
    BrowserContext.route_from_har!(context, path)
    page = BrowserContext.new_page!(context)
    navigation = Page.wait_for_navigation(page)
    url = Task.async(fn -> Page.wait_for_url!(page, "https://www.theverge.com/") end)
    Page.goto!(page, "https://theverge.com/")
    response = Promise.await!(navigation)
    Task.await(url)
    Expect.to_have_url!(page, "https://www.theverge.com/")
    assert Request.url(Response.request(response)) == "https://www.theverge.com/"
    assert Page.evaluate!(page, "() => location.href") == "https://www.theverge.com/"
  end

  test "should change document URL after redirected navigation on click", %{
    server: server,
    context: context,
    asset: asset
  } do
    path = asset.("har-redirect.har")
    BrowserContext.route_from_har!(context, path, url: ~r/.*theverge.*/)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a href="https://theverge.com/">click me</a>))
    navigation = Page.wait_for_navigation(page)
    Page.click!(page, "text=click me")
    response = Promise.await!(navigation)
    Expect.to_have_url!(page, "https://www.theverge.com/")
    assert Request.url(Response.request(response)) == "https://www.theverge.com/"
    assert Page.evaluate!(page, "() => location.href") == "https://www.theverge.com/"
  end

  test "should goBack to redirected navigation", %{context: context, asset: asset, server: server} do
    path = asset.("har-redirect.har")
    BrowserContext.route_from_har!(context, path, url: ~r/.*theverge.*/)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://theverge.com/")
    Page.goto!(page, server.empty_page)
    Expect.to_have_url!(page, server.empty_page)
    response = Page.go_back!(page)
    Expect.to_have_url!(page, "https://www.theverge.com/")
    assert Request.url(Response.request(response)) == "https://www.theverge.com/"
    assert Page.evaluate!(page, "() => location.href") == "https://www.theverge.com/"
  end

  test "should goForward to redirected navigation", %{context: context, asset: asset, server: server} do
    path = asset.("har-redirect.har")
    BrowserContext.route_from_har!(context, path, url: ~r/.*theverge.*/)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Expect.to_have_url!(page, server.empty_page)
    Page.goto!(page, "https://theverge.com/")
    Expect.to_have_url!(page, "https://www.theverge.com/")
    Page.go_back!(page)
    Expect.to_have_url!(page, server.empty_page)
    response = Page.go_forward!(page)
    Expect.to_have_url!(page, "https://www.theverge.com/")
    assert Request.url(Response.request(response)) == "https://www.theverge.com/"
    assert Page.evaluate!(page, "() => location.href") == "https://www.theverge.com/"
  end

  test "should reload redirected navigation", %{context: context, asset: asset} do
    path = asset.("har-redirect.har")
    BrowserContext.route_from_har!(context, path, url: ~r/.*theverge.*/)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://theverge.com/")
    Expect.to_have_url!(page, "https://www.theverge.com/")
    response = Page.reload!(page)
    Expect.to_have_url!(page, "https://www.theverge.com/")
    assert Request.url(Response.request(response)) == "https://www.theverge.com/"
    assert Page.evaluate!(page, "() => location.href") == "https://www.theverge.com/"
  end

  test "should fulfill from har with content in a file", %{context: context, asset: asset} do
    path = asset.("har-sha1.har")
    BrowserContext.route_from_har!(context, path)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://no.playwright/")
    assert Page.content!(page) == "<html><head></head><body>Hello, world</body></html>"
  end

  test "should round-trip har.zip", %{context_factory: context_factory, server: server, output_path: output_path} do
    har_path = output_path.("har.zip")
    context1 = context_factory.(record_har: %{mode: "minimal", path: har_path})
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.prefix <> "/one-style.html")
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path, not_found: :abort)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.prefix <> "/one-style.html")
    assert Page.content!(page2) =~ "hello, world!"
    Expect.to_have_css!(Page.locator(page2, "body"), "background-color", "rgb(255, 192, 203)")
  end

  test "should produce extracted zip", %{context_factory: context_factory, server: server, output_path: output_path} do
    har_path = output_path.("har.har")
    context1 = context_factory.(record_har: %{mode: "minimal", path: har_path, content: "attach"})
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.prefix <> "/one-style.html")
    BrowserContext.close!(context1)

    assert File.exists?(har_path)
    har = File.read!(har_path)
    refute har =~ "background-color"

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path, not_found: :abort)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.prefix <> "/one-style.html")
    assert Page.content!(page2) =~ "hello, world!"
    Expect.to_have_css!(Page.locator(page2, "body"), "background-color", "rgb(255, 192, 203)")
  end

  test "should round-trip extracted har.zip", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    har_path = output_path.("har.zip")
    context1 = context_factory.(record_har: %{mode: "minimal", path: har_path})
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.prefix <> "/one-style.html")
    BrowserContext.close!(context1)

    har_dir = output_path.("hardir")
    {:ok, _} = :zip.unzip(String.to_charlist(har_path), cwd: String.to_charlist(har_dir))

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, Path.join(har_dir, "har.har"))
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.prefix <> "/one-style.html")
    assert Page.content!(page2) =~ "hello, world!"
    Expect.to_have_css!(Page.locator(page2, "body"), "background-color", "rgb(255, 192, 203)")
  end

  @fetch_function """
  async (body) => {
    const response = await fetch('/echo', { method: 'POST', body });
    return await response.text();
  }
  """

  test "should round-trip har with postData", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    TestServer.set_route(server, "/echo", &echo_post_body/1)

    har_path = output_path.("har.zip")
    context1 = context_factory.(record_har: %{mode: "minimal", path: har_path})
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.empty_page)

    assert Page.evaluate!(page1, @fetch_function, "1") == "1"
    assert Page.evaluate!(page1, @fetch_function, "2") == "2"
    assert Page.evaluate!(page1, @fetch_function, "3") == "3"
    BrowserContext.close!(context1)

    TestServer.reset(server)
    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)
    assert Page.evaluate!(page2, @fetch_function, "1") == "1"
    assert Page.evaluate!(page2, @fetch_function, "2") == "2"
    assert Page.evaluate!(page2, @fetch_function, "3") == "3"

    assert (case Page.evaluate(page2, @fetch_function, "4") do
              {:ok, value} -> value
              {:error, e} -> e
            end)
  end

  @fetch_path_function """
  async (arg) => {
    const response = await fetch(arg.path, { method: 'POST', body: arg.body });
    return await response.text();
  }
  """

  test "should record overridden requests to har", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    TestServer.set_route(server, "/echo", &echo_post_body/1)

    har_path = output_path.("har.zip")
    context1 = context_factory.(record_har: %{mode: "minimal", path: har_path})
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.empty_page)

    Page.route!(page1, "**/echo_redir", fn route ->
      Route.fallback!(route,
        url: server.prefix <> "/echo",
        # `+route.request().postData() + 10`: a number, serialized as JSON.
        post_data: String.to_integer(Request.post_data(Route.request(route))) + 10
      )
    end)

    assert Page.evaluate!(page1, @fetch_path_function, %{path: "/echo_redir", body: "1"}) == "11"
    assert Page.evaluate!(page1, @fetch_path_function, %{path: "/echo_redir", body: "2"}) == "12"
    BrowserContext.close!(context1)

    TestServer.reset(server)
    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)
    assert Page.evaluate!(page2, @fetch_path_function, %{path: "/echo", body: "11"}) == "11"
    assert Page.evaluate!(page2, @fetch_path_function, %{path: "/echo", body: "12"}) == "12"
  end

  @fetch_header_function """
  async (bazValue) => {
    const response = await fetch('/echo', {
      method: 'POST',
      body: '',
      headers: {
        foo: 'foo-value',
        bar: 'bar-value',
        baz: bazValue,
      }
    });
    return await response.text();
  }
  """

  test "should disambiguate by header", %{context_factory: context_factory, server: server, output_path: output_path} do
    TestServer.set_route(server, "/echo", fn conn ->
      Plug.Conn.send_resp(conn, 200, conn |> Plug.Conn.get_req_header("baz") |> List.first())
    end)

    har_path = output_path.("har.zip")
    context1 = context_factory.(record_har: %{mode: "minimal", path: har_path})
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.empty_page)

    assert Page.evaluate!(page1, @fetch_header_function, "baz1") == "baz1"
    assert Page.evaluate!(page1, @fetch_header_function, "baz2") == "baz2"
    assert Page.evaluate!(page1, @fetch_header_function, "baz3") == "baz3"
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)
    assert Page.evaluate!(page2, @fetch_header_function, "baz1") == "baz1"
    assert Page.evaluate!(page2, @fetch_header_function, "baz2") == "baz2"
    assert Page.evaluate!(page2, @fetch_header_function, "baz3") == "baz3"
    assert Page.evaluate!(page2, @fetch_header_function, "baz4") == "baz1"
  end

  test "should update har.zip for context", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    har_path = output_path.("har.zip")
    context1 = context_factory.([])
    BrowserContext.route_from_har!(context1, har_path, update: true)
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.prefix <> "/one-style.html")
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path, not_found: :abort)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.prefix <> "/one-style.html")
    assert Page.content!(page2) =~ "hello, world!"
    Expect.to_have_css!(Page.locator(page2, "body"), "background-color", "rgb(255, 192, 203)")
  end

  test "should ignore boundary when matching multipart/form-data body", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
        <form id="form" action="form.html" enctype="multipart/form-data" method="POST">
        <input id="file" type="file" multiple />
        <button type="submit">Upload</button>
        </form>
      """)
    end)

    TestServer.set_route(server, "/form.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<div>done</div>")
    end)

    har_path = output_path.("har.zip")
    context1 = context_factory.([])
    BrowserContext.route_from_har!(context1, har_path, update: true)
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.prefix <> "/empty.html")
    req_promise = TestServer.wait_for_request(server, "/form.html")
    Locator.click!(Page.locator(page1, "button"))
    Expect.to_have_text!(Page.locator(page1, "div"), "done")
    req = Task.await(req_promise)
    assert req.assigns.post_body =~ "---"
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path, not_found: :abort)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.prefix <> "/empty.html")
    request_promise = Page.wait_for_request(page2, ~r/.*form.html/)
    Locator.click!(Page.locator(page2, "button"))
    request = Promise.await!(request_promise)
    assert Request.response!(request)
    assert Request.failure(request) == nil
    Expect.to_have_text!(Page.locator(page2, "div"), "done")
  end

  test "should record single set-cookie headers", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.prepend_resp_headers([{"set-cookie", "first=foo"}])
      |> Plug.Conn.send_resp(200, "")
    end)

    har_path = output_path.("har.zip")
    context1 = context_factory.([])
    BrowserContext.route_from_har!(context1, har_path, update: true)
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.empty_page)
    cookie1 = Page.evaluate!(page1, "() => document.cookie")
    assert cookie1 == "first=foo"
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path, not_found: :abort)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)
    cookie2 = Page.evaluate!(page2, "() => document.cookie")
    assert cookie2 == "first=foo"
  end

  test "should record multiple set-cookie headers", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.prepend_resp_headers([{"set-cookie", "first=foo"}, {"set-cookie", "second=bar"}])
      |> Plug.Conn.send_resp(200, "")
    end)

    har_path = output_path.("har.zip")
    context1 = context_factory.([])
    BrowserContext.route_from_har!(context1, har_path, update: true)
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.empty_page)
    cookie1 = Page.evaluate!(page1, "() => document.cookie")
    assert cookie1 |> String.split("; ") |> Enum.sort() |> Enum.join("; ") == "first=foo; second=bar"
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, har_path, not_found: :abort)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)
    cookie2 = Page.evaluate!(page2, "() => document.cookie")
    assert cookie2 |> String.split("; ") |> Enum.sort() |> Enum.join("; ") == "first=foo; second=bar"
  end

  test "should update har.zip for page", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    har_path = output_path.("har.zip")
    context1 = context_factory.([])
    page1 = BrowserContext.new_page!(context1)
    Page.route_from_har!(page1, har_path, update: true)
    Page.goto!(page1, server.prefix <> "/one-style.html")
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    page2 = BrowserContext.new_page!(context2)
    Page.route_from_har!(page2, har_path, not_found: :abort)
    Page.goto!(page2, server.prefix <> "/one-style.html")
    assert Page.content!(page2) =~ "hello, world!"
    Expect.to_have_css!(Page.locator(page2, "body"), "background-color", "rgb(255, 192, 203)")
  end

  test "should update har.zip for page with different options", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    har_path = output_path.("har.zip")
    context1 = context_factory.([])
    page1 = BrowserContext.new_page!(context1)
    Page.route_from_har!(page1, har_path, update: true, update_content: :embed, update_mode: :full)
    Page.goto!(page1, server.prefix <> "/one-style.html")
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    page2 = BrowserContext.new_page!(context2)
    Page.route_from_har!(page2, har_path, not_found: :abort)
    Page.goto!(page2, server.prefix <> "/one-style.html")
    assert Page.content!(page2) =~ "hello, world!"
    Expect.to_have_css!(Page.locator(page2, "body"), "background-color", "rgb(255, 192, 203)")
  end

  test "should update extracted har.zip for page", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    har_path = output_path.("har.har")
    context1 = context_factory.([])
    page1 = BrowserContext.new_page!(context1)
    Page.route_from_har!(page1, har_path, update: true)
    Page.goto!(page1, server.prefix <> "/one-style.html")
    BrowserContext.close!(context1)

    context2 = context_factory.([])
    page2 = BrowserContext.new_page!(context2)
    Page.route_from_har!(page2, har_path, not_found: :abort)
    Page.goto!(page2, server.prefix <> "/one-style.html")
    assert Page.content!(page2) =~ "hello, world!"
    Expect.to_have_css!(Page.locator(page2, "body"), "background-color", "rgb(255, 192, 203)")
  end

  test "page.unrouteAll should stop page.routeFromHAR", %{
    context_factory: context_factory,
    server: server,
    asset: asset
  } do
    har_path = asset.("har-fulfill.har")
    context1 = context_factory.([])
    page1 = BrowserContext.new_page!(context1)
    # The har file contains requests for another domain, so the router
    # is expected to abort all requests.
    Page.route_from_har!(page1, har_path, not_found: :abort)
    assert {:error, _} = Page.goto(page1, server.empty_page)
    Page.unroute_all!(page1, behavior: :wait)
    response = Page.goto!(page1, server.empty_page)
    assert Response.ok(response)
  end

  test "context.unrouteAll should stop context.routeFromHAR", %{
    context_factory: context_factory,
    server: server,
    asset: asset
  } do
    har_path = asset.("har-fulfill.har")
    context1 = context_factory.([])
    page1 = BrowserContext.new_page!(context1)
    # The har file contains requests for another domain, so the router
    # is expected to abort all requests.
    BrowserContext.route_from_har!(context1, har_path, not_found: :abort)
    assert {:error, _} = Page.goto(page1, server.empty_page)
    BrowserContext.unroute_all!(context1, behavior: :wait)
    response = Page.goto!(page1, server.empty_page)
    assert Response.ok(response)
  end

  test "should ignore aborted requests", %{context_factory: context_factory, server: server, output_path: output_path} do
    path = output_path.("test.har")
    fetch_x = "url => fetch(url).catch(e => 'cancelled')"

    TestServer.set_route(server, "/x", &destroy_request/1)
    context1 = context_factory.([])
    BrowserContext.route_from_har!(context1, path, update: true)
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.empty_page)
    req_promise = TestServer.wait_for_request(server, "/x")
    eval_promise = Task.async(fn -> Page.evaluate!(page1, fetch_x, server.prefix <> "/x") end)
    Task.await(req_promise)
    req = Task.await(eval_promise)
    assert req == "cancelled"
    BrowserContext.close!(context1)

    TestServer.reset(server)

    TestServer.set_route(server, "/x", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(200, "test")
    end)

    context2 = context_factory.([])
    BrowserContext.route_from_har!(context2, path)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)
    eval_promise = Task.async(fn -> Page.evaluate(page2, fetch_x, server.prefix <> "/x") end)
    # Promise.race([evalPromise, page2.waitForTimeout(1000).then(() => 'timeout')])
    result =
      case Task.yield(eval_promise, 1000) do
        {:ok, {:ok, value}} -> value
        nil -> "timeout"
      end

    assert result == "timeout"
    # Not upstream: settle the pending evaluate before the test process exits.
    BrowserContext.close!(context2)
    Task.await(eval_promise)
  end
end
