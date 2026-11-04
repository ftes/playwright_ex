defmodule PlaywrightEx.Library.BrowsercontextHarTest do
  @upstream "tests/library/browsercontext-har.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
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

  @tag skip: "not ported: expect"
  test "should context.routeFromHAR, matching the method and following redirects"

  @tag skip: "not ported: expect"
  test "should page.routeFromHAR, matching the method and following redirects"

  @tag skip: "not ported: expect"
  test "fallback:continue should continue when not found in har"

  test "by default should abort requests not found in har", %{context: context, server: server, asset: asset} do
    path = asset.("har-fulfill.har")
    BrowserContext.route_from_har!(context, path)
    page = BrowserContext.new_page!(context)
    {:error, error} = Page.goto(page, server.empty_page)
    assert is_exception(error)
  end

  @tag skip: "not ported: expect"
  test "fallback:continue should continue requests on bad har"

  @tag skip: "not ported: expect"
  test "should only handle requests matching url filter"

  @tag skip: "not ported: expect"
  test "should only context.routeFromHAR requests matching url filter"

  @tag skip: "not ported: expect"
  test "should only page.routeFromHAR requests matching url filter"

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

  @tag skip: "not ported: expect"
  test "should support regex filter"

  @tag skip: "not ported: expect"
  test "newPage should fulfill from har, matching the method and following redirects"

  @tag skip: "not ported: expect"
  test "should change document URL after redirected navigation"

  @tag skip: "not ported: expect"
  test "should change document URL after redirected navigation on click"

  @tag skip: "not ported: expect"
  test "should goBack to redirected navigation"

  @tag skip: "not ported: expect"
  test "should goForward to redirected navigation"

  @tag skip: "not ported: expect"
  test "should reload redirected navigation"

  test "should fulfill from har with content in a file", %{context: context, asset: asset} do
    path = asset.("har-sha1.har")
    BrowserContext.route_from_har!(context, path)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://no.playwright/")
    assert Page.content!(page) == "<html><head></head><body>Hello, world</body></html>"
  end

  @tag skip: "not ported: expect"
  test "should round-trip har.zip"

  @tag skip: "not ported: expect"
  test "should produce extracted zip"

  @tag skip: "not ported: expect"
  test "should round-trip extracted har.zip"

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

  @tag skip: "not ported: expect"
  test "should update har.zip for context"

  @tag skip: "not ported: expect"
  test "should ignore boundary when matching multipart/form-data body"

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

  @tag skip: "not ported: expect"
  test "should update har.zip for page"

  @tag skip: "not ported: expect"
  test "should update har.zip for page with different options"

  @tag skip: "not ported: expect"
  test "should update extracted har.zip for page"

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
