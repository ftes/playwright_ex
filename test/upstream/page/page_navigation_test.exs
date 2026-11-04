defmodule PlaywrightEx.Page.PageNavigationTest do
  @upstream "tests/page/page-navigation.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp html(body), do: fn conn -> Plug.Conn.send_resp(conn, 200, body) end

  test "should work with _blank target", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", html(~s(<a href="#{server.empty_page}" target="_blank">Click me</a>)))
    Page.goto!(page, server.empty_page)
    Page.click!(page, ~s("Click me"))
  end

  test "should work with cross-process _blank target", %{page: page, server: server} do
    TestServer.set_route(
      server,
      "/empty.html",
      html(~s(<a href="#{server.cross_process_prefix}/empty.html" target="_blank">Click me</a>))
    )

    Page.goto!(page, server.empty_page)
    Page.click!(page, ~s("Click me"))
  end

  test "should work with _blank target in form", %{page: page, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/18392' }
    TestServer.set_route(server, "/done.html?", html("Done"))
    TestServer.set_route(server, "/done.html", html("Done"))
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <form target="_blank" action="done.html" >
      <input type="submit" value="Click me">
    </form>
    """)

    Page.expect_popup!(page, fn -> Page.click!(page, ~s("Click me")) end)

    Page.set_content!(page, """
    <form target="_blank" action="done.html" method="post">
      <input type="submit" value="Click me">
    </form>
    """)

    Page.expect_popup!(page, fn -> Page.click!(page, ~s("Click me")) end)
  end

  test "should not throw TargetClosedException on cross-origin redirect after click", %{page: page, server: server} do
    TestServer.set_route(server, "/target.html", html("<title>final page</title>"))
    TestServer.set_redirect(server, "/redirect", server.cross_process_prefix <> "/target.html")
    Page.goto!(page, server.prefix <> "/empty.html")

    Page.set_content!(page, """
      <form action="#{server.prefix}/redirect" method="POST">
        <button type="submit">Submit</button>
      </form>
    """)

    # triggers POST -> 302 -> cross-origin
    Page.expect_navigation!(page, fn -> Page.click!(page, "button") end)
    Expect.to_have_url!(page, server.cross_process_prefix <> "/target.html")
    Expect.to_have_title!(page, "final page")
  end
end
