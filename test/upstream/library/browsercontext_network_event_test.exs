defmodule PlaywrightEx.Library.BrowsercontextNetworkEventTest do
  @upstream "tests/library/browsercontext-network-event.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp received(tag, acc \\ []) do
    receive do
      {^tag, value} -> received(tag, [value | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "BrowserContext.Events.Request", %{context: context, server: server} do
    test = self()
    page = BrowserContext.new_page!(context)
    BrowserContext.on(context, :request, fn request -> send(test, {:request, request}) end)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<a target=_blank rel=noopener href=\"/one-style.html\">yo</a>")
    page1 = BrowserContext.expect_page!(context, fn -> Page.click!(page, "a") end)
    Page.wait_for_load_state!(page1)
    urls = Enum.map(received(:request), &Request.url/1)

    assert urls == [
             server.empty_page,
             "#{server.prefix}/one-style.html",
             "#{server.prefix}/one-style.css"
           ]
  end

  test "BrowserContext.Events.Response", %{context: context, server: server} do
    test = self()
    page = BrowserContext.new_page!(context)
    BrowserContext.on(context, :response, fn response -> send(test, {:response, response}) end)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<a target=_blank rel=noopener href=\"/one-style.html\">yo</a>")
    page1 = BrowserContext.expect_page!(context, fn -> Page.click!(page, "a") end)
    Page.wait_for_load_state!(page1)
    urls = Enum.map(received(:response), &Response.url/1)

    assert urls == [
             server.empty_page,
             "#{server.prefix}/one-style.html",
             "#{server.prefix}/one-style.css"
           ]
  end

  test "BrowserContext.Events.RequestFailed", %{context: context, server: server} do
    test = self()

    # res.connection.destroy(): kill the connection's handler process.
    TestServer.set_route(server, "/one-style.css", fn conn ->
      Plug.Conn.put_resp_header(conn, "content-type", "text/css")
      Process.exit(self(), :kill)
    end)

    page = BrowserContext.new_page!(context)
    BrowserContext.on(context, :request_failed, fn request -> send(test, {:request_failed, request}) end)
    Page.goto!(page, server.prefix <> "/one-style.html")
    failed_requests = received(:request_failed)
    assert length(failed_requests) == 1
    assert Request.url(hd(failed_requests)) =~ "one-style.css"
    assert Request.response!(hd(failed_requests)) == nil
    assert Request.resource_type(hd(failed_requests)) == "stylesheet"
    assert Request.frame(hd(failed_requests))
  end

  test "BrowserContext.Events.RequestFinished", %{context: context, server: server} do
    page = BrowserContext.new_page!(context)
    request_finished = BrowserContext.wait_for_event(context, :request_finished)
    response = Page.goto!(page, server.empty_page)
    Promise.await!(request_finished)
    request = Response.request(response)
    assert Request.url(request) == server.empty_page
    assert Request.response!(request)
    assert Request.frame(request) == Page.main_frame(page)
    assert Frame.url(Request.frame(request)) == server.empty_page
    assert Request.failure(request) == nil
  end

  test "should fire events in proper order", %{context: context, server: server} do
    test = self()
    page = BrowserContext.new_page!(context)
    BrowserContext.on(context, :request, fn _ -> send(test, {:event, "request"}) end)
    BrowserContext.on(context, :response, fn _ -> send(test, {:event, "response"}) end)
    BrowserContext.on(context, :request_finished, fn _ -> send(test, {:event, "requestfinished"}) end)
    request_finished = BrowserContext.wait_for_event(context, :request_finished)
    Page.goto!(page, server.empty_page)
    Promise.await!(request_finished)

    assert received(:event) == [
             "request",
             "response",
             "requestfinished"
           ]
  end

  @tag skip: "upstream skip: headless browsers, except firefox, do not request favicons"
  test "should not fire events for favicon or favicon redirects"

  test "should reject response.finished if context closes", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    TestServer.set_route(server, "/get", fn conn ->
      # In Firefox, |fetch| will be hanging until it receives |Content-Type| header
      # from server.
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8")
        |> Plug.Conn.send_chunked(200)

      {:ok, _conn} = Plug.Conn.chunk(conn, "hello ")
      Process.sleep(:infinity)
    end)

    # send request and wait for server response
    page_response =
      Page.expect_event!(page, :response, fn ->
        Page.evaluate!(page, "() => fetch('./get', { method: 'GET' })")
      end)

    finish_promise = Task.async(fn -> Response.finished(page_response) end)
    BrowserContext.close!(Page.context(page))
    {:error, error} = Task.await(finish_promise, :infinity)
    assert error.message =~ "closed"
  end
end
