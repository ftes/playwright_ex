defmodule PlaywrightEx.Library.BrowsercontextUserAgentTest do
  @upstream "tests/library/browsercontext-user-agent.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  import PlaywrightEx.Utils, only: [attach_frame: 3]

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  test "UA-001 should work", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "() => navigator.userAgent") =~ "Mozilla"
    BrowserContext.close!(context)

    context = Browser.new_context!(browser, user_agent: "foobar")
    page = BrowserContext.new_page!(context)
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    assert header(Task.await(request, :infinity), "user-agent") == "foobar"
    BrowserContext.close!(context)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43597' }
  test "UA-007 should preserve custom user agent in route.fetch", %{context_factory: context_factory, server: server} do
    context = context_factory.(user_agent: "my-custom-user-agent")
    page = BrowserContext.new_page!(context)

    Page.route!(page, "**/empty.html", fn route ->
      Route.fulfill!(route, response: Route.fetch!(route))
    end)

    request = Page.wait_for_request(page, server.empty_page)
    server_request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    request = Promise.await!(request)
    server_request = Task.await(server_request, :infinity)
    # expect.soft: the first failure ends the test here.
    assert Request.headers(request)["user-agent"] == "my-custom-user-agent"
    assert header(server_request, "user-agent") == "my-custom-user-agent"
  end

  test "UA-002 should work for subframes", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "() => navigator.userAgent") =~ "Mozilla"
    BrowserContext.close!(context)

    context = Browser.new_context!(browser, user_agent: "foobar")
    page = BrowserContext.new_page!(context)
    request = TestServer.wait_for_request(server, "/empty.html")
    attach_frame(page, "frame1", server.empty_page)
    assert header(Task.await(request, :infinity), "user-agent") == "foobar"
    BrowserContext.close!(context)
  end

  test "UA-003 should emulate device user-agent", %{browser: browser, server: server, playwright: playwright} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/mobile.html")
    refute Page.evaluate!(page, "() => navigator.userAgent") =~ "iPhone"
    BrowserContext.close!(context)

    context = Browser.new_context!(browser, user_agent: Playwright.devices(playwright)["iPhone 6"].user_agent)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/mobile.html")
    assert Page.evaluate!(page, "() => navigator.userAgent") =~ "iPhone"
    BrowserContext.close!(context)
  end

  test "UA-004 should make a copy of default options", %{browser: browser, server: server} do
    options = %{user_agent: "foobar"}
    context = Browser.new_context!(browser, options)
    # options.userAgent = 'wrong'  -- Elixir data is immutable
    page = BrowserContext.new_page!(context)
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    assert header(Task.await(request, :infinity), "user-agent") == "foobar"
    BrowserContext.close!(context)
  end

  test "UA-005 custom user agent for download", %{server: server, context_factory: context_factory} do
    # it.skip(chromium && chromiumVersionLessThan(browserVersion, '116.0.0.0'))  -- the pinned Chromium is newer
    TestServer.set_route(server, "/download", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header("content-disposition", "attachment")
      |> Plug.Conn.send_resp(200, "Hello world")
    end)

    context = context_factory.(user_agent: "MyCustomUA")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a id="download" download="name" href="/download">Download</a>))
    server_request = TestServer.wait_for_request(server, "/download")
    Runtime.Promise.void(fn -> Locator.click(Page.locator(page, "#download")) end)
    req = Task.await(server_request, :infinity)
    assert header(req, "user-agent") == "MyCustomUA"
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: This API is Chromium-only")
  test "UA-006 should work for navigator.userAgentData and sec-ch-ua headers", %{
    playwright: playwright,
    browser: browser,
    server: server
  } do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    request = Task.await(request, :infinity)
    assert header(request, "sec-ch-ua") =~ ~s("Chromium")
    assert header(request, "sec-ch-ua-mobile") == "?0"
    assert header(request, "sec-ch-ua-platform")
    assert %{"mobile" => false} = Page.evaluate!(page, "() => window.navigator.userAgentData.toJSON()")
    BrowserContext.close!(context)

    context = Browser.new_context!(browser, Playwright.devices(playwright)["Pixel 7"])
    page = BrowserContext.new_page!(context)
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    request = Task.await(request, :infinity)
    assert header(request, "sec-ch-ua") =~ ~s("Chromium")
    assert header(request, "sec-ch-ua-mobile") == "?1"
    assert header(request, "sec-ch-ua-platform") == ~s("Android")

    assert %{"mobile" => true, "platform" => "Android"} =
             Page.evaluate!(page, "() => window.navigator.userAgentData.toJSON()")

    BrowserContext.close!(context)
  end
end
