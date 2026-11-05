defmodule PlaywrightEx.Library.FaviconTest do
  @upstream "tests/library/favicon.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

  # it.skip(headless && browserName !== 'firefox'): we run headless.
  @tag skip:
         if(@browser_name != "firefox", do: "upstream skip: headless browsers, except firefox, do not request favicons")
  test "should load svg favicon with prefer-color-scheme", %{page: page, server: server, asset: asset} do
    # Browsers aggressively cache favicons, so force bust with the
    # `d` parameter to make iterating on this test more predictable and isolated.
    favicon = "/favicon.svg?d=#{System.system_time(:millisecond)}"

    TestServer.set_route(server, favicon, fn conn ->
      TestServer.serve_file(server, conn, asset.("media-query-prefers-color-scheme.svg"))
    end)

    TestServer.set_route(server, "/page.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      <!DOCTYPE html>
      <html>
        <head>
          <meta charset="utf-8">
          <link rel="icon" type="image/svg+xml" href="#{favicon}">
          <title>SVG Favicon Test</title>
        </head>
        <body>
          favicons
        </body>
      </html>
      """)
    end)

    request = TestServer.wait_for_request(server, favicon)
    Page.goto!(page, server.prefix <> "/page.html")
    Task.await(request)

    # Add artificial delay since, just because we saw the request for the favicon,
    # it does not mean the browser has processed it.
    Page.wait_for_timeout!(page, 500)
    # Text still being around ensures we haven't actually lost our browser to a crash.
    Page.wait_for_selector!(page, "text=favicons")
  end
end
