defmodule PlaywrightEx.Library.Chromium.DisableWebSecurityTest do
  @upstream "tests/library/chromium/disable-web-security.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.TestServer

  @moduletag :page
  @moduletag skip: if(System.get_env("BROWSER", "chromium") != "chromium", do: "chromium only")

  # it.use({ launchOptions }): this module's `browser` is launched with --disable-web-security.
  setup_all %{browser_type: browser_type} do
    %{browser: BrowserType.launch!(browser_type, args: ["--disable-web-security"])}
  end

  defp set_routes(server) do
    TestServer.set_route(server, "/main.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s(<a href="#{server.prefix}/target.html" target="_blank">Click me</a>))
    end)

    TestServer.set_route(server, "/target.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<html></html>")
    end)
  end

  test "test utility world in popup w/ --disable-web-security", %{page: page, server: server} do
    set_routes(server)

    Page.goto!(page, server.prefix <> "/main.html")
    page1_promise = BrowserContext.wait_for_event(Page.context(page), :page)
    page |> Page.get_by_role("link", name: "Click me") |> Locator.click!()
    page1 = Promise.await!(page1_promise)
    Expect.to_have_url!(page1, ~r/target/)
  end

  test "test init script w/ --disable-web-security", %{page: page, server: server} do
    set_routes(server)

    BrowserContext.add_init_script!(Page.context(page), "window.injected = 123")
    Page.goto!(page, server.prefix <> "/main.html")
    page1_promise = BrowserContext.wait_for_event(Page.context(page), :page)
    page |> Page.get_by_role("link", name: "Click me") |> Locator.click!()
    page1 = Promise.await!(page1_promise)
    value = Page.evaluate!(page1, "window.injected")
    assert value == 123
  end
end
