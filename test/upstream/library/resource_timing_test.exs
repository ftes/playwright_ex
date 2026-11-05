defmodule PlaywrightEx.Library.ResourceTimingTest do
  @upstream "tests/library/resource-timing.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer

  test "should work @smoke", %{context_factory: context_factory, server: server} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    request = Page.wait_for_event(page, :request_finished)
    Page.goto!(page, server.empty_page)
    request = Promise.await!(request)
    timing = Request.timing(request)
    verify_connection_timing_consistency(timing)
    assert timing.requestStart >= timing.connectEnd
    assert timing.responseStart >= timing.requestStart
    assert timing.responseEnd >= timing.responseStart
    assert timing.responseEnd < 10_000
    BrowserContext.close!(context)
  end

  @tag skip:
         if(System.get_env("BROWSER") == "webkit" and match?({:win32, _}, :os.type()),
           do: "responseStart is wrong due upstream webkit/libcurl bug"
         )
  test "should work for subresource", %{context_factory: context_factory, server: server} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    test = self()
    Page.on(page, :request_finished, fn request -> send(test, {:request_finished, request}) end)
    Page.goto!(page, server.prefix <> "/one-style.html")
    assert_receive {:request_finished, _}
    assert_receive {:request_finished, request}
    refute_received {:request_finished, _}
    timing = Request.timing(request)
    verify_connection_timing_consistency(timing)
    assert timing.requestStart >= 0
    assert timing.responseStart > timing.requestStart
    assert timing.responseEnd >= timing.responseStart
    assert timing.responseEnd < 10_000
    BrowserContext.close!(context)
  end

  test "should work for SSL", %{browser: browser, https_server: https_server} do
    page = Browser.new_page!(browser, ignore_https_errors: true)
    request = Page.wait_for_event(page, :request_finished)
    Page.goto!(page, https_server.empty_page)
    request = Promise.await!(request)
    timing = Request.timing(request)
    verify_connection_timing_consistency(timing)
    assert timing.requestStart >= timing.connectEnd
    assert timing.responseStart > timing.requestStart
    assert timing.responseEnd >= timing.responseStart
    assert timing.responseEnd < 10_000
    Page.close!(page)
  end

  @tag skip:
         if(System.get_env("BROWSER") == "webkit",
           do: "In WebKit, redirects don't carry the timing info"
         )
  test "should work for redirect", %{context_factory: context_factory, server: server} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    TestServer.set_redirect(server, "/foo.html", "/empty.html")
    test = self()
    Page.on(page, :response, fn response -> send(test, {:response, response}) end)
    Page.goto!(page, server.prefix <> "/foo.html")
    assert_receive {:response, response1}
    assert_receive {:response, response2}
    refute_received {:response, _}
    responses = [response1, response2]
    Enum.each(responses, &Response.finished!/1)

    assert length(responses) == 2
    assert Response.url(response1) == server.prefix <> "/foo.html"
    assert Response.url(response2) == server.prefix <> "/empty.html"

    timing1 = Request.timing(Response.request(response1))
    verify_connection_timing_consistency(timing1)
    assert timing1.requestStart >= timing1.connectEnd
    assert timing1.responseStart > timing1.requestStart
    assert timing1.responseEnd >= timing1.responseStart
    assert timing1.responseEnd < 10_000

    timing2 = Request.timing(Response.request(response2))
    verify_connection_timing_consistency(timing2)
    assert timing2.requestStart >= 0
    assert timing2.responseStart > timing2.requestStart
    assert timing2.responseEnd >= timing2.responseStart
    assert timing2.responseEnd < 10_000

    BrowserContext.close!(context)
  end

  @tag skip:
         if(System.get_env("BROWSER") == "firefox", do: "Response event is not fired in Firefox")
  test "should work when serving from memory cache", %{
    context_factory: context_factory,
    server: server
  } do
    TestServer.set_route(server, "/one-style.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=10031518")
      |> Plug.Conn.send_resp(200, "body { background: red }")
    end)

    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/one-style.html")
    response = Page.wait_for_response(page, "**/one-style.css")
    Page.reload!(page)
    response = Promise.await!(response)
    Response.finished!(response)

    timing = Request.timing(Response.request(response))
    verify_connection_timing_consistency(timing)

    assert timing.responseStart == timing.responseEnd
    assert timing.responseEnd < 1000
    BrowserContext.close!(context)
  end

  # Upstream's `expect(value === -1 || ...)` has no matcher, so it asserts nothing.
  defp verify_timing_value(_value, _previous), do: nil

  defp verify_connection_timing_consistency(timing) do
    verify_timing_value(timing.domainLookupStart, -1)
    verify_timing_value(timing.domainLookupEnd, timing.domainLookupStart)
    verify_timing_value(timing.connectStart, timing.domainLookupEnd)
    verify_timing_value(timing.secureConnectionStart, timing.connectStart)
    verify_timing_value(timing.connectEnd, timing.secureConnectionStart)
  end
end
