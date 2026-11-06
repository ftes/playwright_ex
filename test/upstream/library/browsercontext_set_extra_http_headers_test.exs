defmodule PlaywrightEx.Library.BrowsercontextSetExtraHttpHeadersTest do
  @upstream "tests/library/browsercontext-set-extra-http-headers.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  test "should override extra headers from browser context", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, extra_http_headers: %{"fOo" => "bAr", "baR" => "foO"})
    page = BrowserContext.new_page!(context)
    Page.set_extra_http_headers!(page, %{"Foo" => "Bar"})
    request_task = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    request = Task.await(request_task, :infinity)
    BrowserContext.close!(context)
    assert header(request, "foo") == "Bar"
    assert header(request, "bar") == "foO"
  end

  test "should throw for non-string header values", %{browser: browser} do
    {:error, error3} = Browser.new_context(browser, extra_http_headers: %{"foo" => :null})
    assert Exception.message(error3) =~ ~s(Expected value of header "foo" to be String, but "object" is found.)
  end
end
