defmodule PlaywrightEx.Library.Defaultbrowsercontext1Test do
  @upstream "tests/library/defaultbrowsercontext-1.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  # browserTest `defaultSameSiteCookieValue` (no BiDi here).
  defp default_same_site_cookie_value("chromium"), do: "Lax"
  defp default_same_site_cookie_value("firefox"), do: "None"
  defp default_same_site_cookie_value("webkit"), do: if(windows?(), do: "None", else: "Lax")

  defp windows?, do: match?({:win32, _}, :os.type())

  test "context.cookies() should work @smoke", %{
    server: server,
    launch_persistent: launch_persistent,
    browser_name: browser_name
  } do
    %{page: page} = launch_persistent.([])
    Page.goto!(page, server.empty_page)

    document_cookie =
      Page.evaluate!(page, """
      () => {
        document.cookie = 'username=John Doe';
        return document.cookie;
      }
      """)

    assert document_cookie == "username=John Doe"

    assert BrowserContext.cookies!(Page.context(page)) == [
             %{
               name: "username",
               value: "John Doe",
               domain: server.hostname,
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: false,
               sameSite: default_same_site_cookie_value(browser_name)
             }
           ]
  end

  test "context.addCookies() should work", %{
    server: server,
    launch_persistent: launch_persistent,
    browser_name: browser_name
  } do
    %{page: page} = launch_persistent.([])
    Page.goto!(page, server.empty_page)

    BrowserContext.add_cookies!(Page.context(page), [
      %{url: server.empty_page, name: "username", value: "John Doe", sameSite: "Lax"}
    ])

    assert Page.evaluate!(page, "() => document.cookie") == "username=John Doe"

    assert BrowserContext.cookies!(Page.context(page)) == [
             %{
               name: "username",
               value: "John Doe",
               domain: server.hostname,
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: false,
               sameSite: if(browser_name == "webkit" and windows?(), do: "None", else: "Lax")
             }
           ]
  end

  test "context.clearCookies() should work", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.([])
    Page.goto!(page, server.empty_page)

    BrowserContext.add_cookies!(Page.context(page), [
      %{url: server.empty_page, name: "cookie1", value: "1"},
      %{url: server.empty_page, name: "cookie2", value: "2"}
    ])

    assert Page.evaluate!(page, "document.cookie") == "cookie1=1; cookie2=2"
    BrowserContext.clear_cookies!(Page.context(page))
    Page.reload!(page)
    assert BrowserContext.cookies!(Page.context(page), []) == []
    assert Page.evaluate!(page, "document.cookie") == ""
  end

  test "should support viewport option", %{launch_persistent: launch_persistent} do
    %{page: page, context: context} = launch_persistent.(viewport: %{width: 456, height: 789})
    verify_viewport(page, 456, 789)
    page2 = BrowserContext.new_page!(context)
    verify_viewport(page2, 456, 789)
  end

  test "should support deviceScaleFactor option", %{launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(device_scale_factor: 3)
    assert Page.evaluate!(page, "window.devicePixelRatio") == 3
  end

  test "should support userAgent option", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(user_agent: "foobar")
    assert Page.evaluate!(page, "() => navigator.userAgent") == "foobar"
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    assert header(Task.await(request), "user-agent") == "foobar"
  end

  test "should support bypassCSP option", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(bypass_csp: true)
    Page.goto!(page, server.prefix <> "/csp.html")
    Page.add_script_tag!(page, content: ~s|window["__injected"] = 42;|)
    assert Page.evaluate!(page, "__injected") == 42
    assert Page.evaluate!(page, ~s|window["__inlineScriptValue"]|) == 42
  end

  test "should support javascriptEnabled option", %{launch_persistent: launch_persistent, browser_name: browser_name} do
    %{page: page} = launch_persistent.(java_script_enabled: false)
    Page.goto!(page, ~s|data:text/html, <script>var something = "forbidden"</script>|)
    {:error, error} = Page.evaluate(page, "something")

    if browser_name == "webkit",
      do: assert(Exception.message(error) =~ "Can't find variable: something"),
      else: assert(Exception.message(error) =~ "something is not defined")
  end

  test "should support httpCredentials option", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(http_credentials: %{username: "user", password: "pass"})
    TestServer.set_auth(server, "/playground.html", "user", "pass")
    response = Page.goto!(page, server.prefix <> "/playground.html")
    assert Response.status(response) == 200
  end

  test "should support offline option", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(offline: true)
    assert {:error, error} = Page.goto(page, server.empty_page)
    assert error
  end

  @tag skip: "not ported: Download"
  test "should support acceptDownloads option"
end
