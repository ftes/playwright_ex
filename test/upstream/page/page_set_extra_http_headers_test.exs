defmodule PlaywrightEx.Page.PageSetExtraHttpHeadersTest do
  @upstream "tests/page/page-set-extra-http-headers.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  defp major_version(browser), do: browser |> Browser.version() |> String.split(".") |> hd() |> String.to_integer()

  test "should work @smoke", %{page: page, server: server} do
    Page.set_extra_http_headers!(page, %{"foo" => "bar"})
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    request = Task.await(request, :infinity)
    assert header(request, "foo") == "bar"
    assert header(request, "baz") == nil
  end

  test "should work with redirects", %{page: page, server: server} do
    TestServer.set_redirect(server, "/foo.html", "/empty.html")
    Page.set_extra_http_headers!(page, %{"foo" => "bar"})
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.prefix <> "/foo.html")
    assert header(Task.await(request, :infinity), "foo") == "bar"
  end

  test "should work with extra headers from browser context", %{page: page, server: server} do
    BrowserContext.set_extra_http_headers!(Page.context(page), %{"foo" => "bar"})
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    assert header(Task.await(request, :infinity), "foo") == "bar"
  end

  test "should throw for non-string header values", %{page: page} do
    {:error, error1} = Page.set_extra_http_headers(page, %{"foo" => 1})
    assert Exception.message(error1) =~ ~s(Expected value of header "foo" to be String, but "number" is found.)
    {:error, error2} = BrowserContext.set_extra_http_headers(Page.context(page), %{"foo" => true})
    assert Exception.message(error2) =~ ~s(Expected value of header "foo" to be String, but "boolean" is found.)
  end

  test "should not duplicate referer header",
       %{page: page, server: server, browser_name: browser_name, browser: browser} do
    Page.set_extra_http_headers!(page, %{"referer" => server.empty_page})
    response = Page.goto!(page, server.empty_page)
    assert Response.ok(response) == true

    # it.fail(browserName === 'chromium' && browserMajorVersion < 154, 'Request has referer and Referer')
    if browser_name == "chromium" and major_version(browser) < 154,
      do: refute(Request.headers(Response.request(response))["referer"] == server.empty_page),
      else: assert(Request.headers(Response.request(response))["referer"] == server.empty_page)
  end
end
