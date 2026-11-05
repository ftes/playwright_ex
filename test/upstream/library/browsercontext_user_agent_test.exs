defmodule PlaywrightEx.Library.BrowsercontextUserAgentTest do
  @upstream "tests/library/browsercontext-user-agent.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.TestServer

  import PlaywrightEx.Utils, only: [attach_frame: 3]

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  test "should work", %{browser: browser, server: server} do
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

  test "should work for subframes", %{browser: browser, server: server} do
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

  test "should emulate device user-agent", %{browser: browser, server: server, playwright: playwright} do
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

  test "should make a copy of default options", %{browser: browser, server: server} do
    options = %{user_agent: "foobar"}
    context = Browser.new_context!(browser, options)
    # options.userAgent = 'wrong'  -- Elixir data is immutable
    page = BrowserContext.new_page!(context)
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    assert header(Task.await(request, :infinity), "user-agent") == "foobar"
    BrowserContext.close!(context)
  end

  test "custom user agent for download", %{server: server, context_factory: context_factory} do
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
    Task.start(fn -> Locator.click(Page.locator(page, "#download")) end)
    req = Task.await(server_request, :infinity)
    assert header(req, "user-agent") == "MyCustomUA"
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: This API is Chromium-only")
  test "should work for navigator.userAgentData and sec-ch-ua headers", %{
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
