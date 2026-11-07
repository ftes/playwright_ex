defmodule PlaywrightEx.Page.PageEventNetworkTest do
  @upstream "tests/page/page-event-network.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp received(tag, acc \\ []) do
    receive do
      {^tag, value} -> received(tag, [value | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "NE-084 Page.Events.Request @smoke", %{page: page, server: server} do
    test = self()
    Page.on(page, :request, fn request -> send(test, {:request, request}) end)
    Page.goto!(page, server.empty_page)
    requests = received(:request)
    assert length(requests) == 1
    [request] = requests
    assert Request.url(request) == server.empty_page
    assert Request.resource_type(request) == "document"
    assert Request.method(request) == "GET"
    assert Request.response!(request)
    assert Request.frame(request) == Page.main_frame(page)
    assert Frame.url(Request.frame(request)) == server.empty_page
  end

  test "NE-085 Page.Events.Response @smoke", %{page: page, server: server} do
    test = self()
    Page.on(page, :response, fn response -> send(test, {:response, response}) end)
    Page.goto!(page, server.empty_page)
    responses = received(:response)
    assert length(responses) == 1
    [response] = responses
    assert Response.url(response) == server.empty_page
    assert Response.status(response) == 200
    assert Response.ok(response) == true
    assert Response.request(response)
  end

  test "NE-086 Page.Events.RequestFailed @smoke", %{page: page, server: server, browser_name: browser_name} do
    test = self()

    # res.connection.destroy(): kill the connection's handler process.
    TestServer.set_route(server, "/one-style.css", fn _conn -> Process.exit(self(), :kill) end)

    Page.on(page, :request_failed, fn request -> send(test, {:request_failed, request}) end)
    Page.goto!(page, server.prefix <> "/one-style.html")
    failed_requests = received(:request_failed)
    assert length(failed_requests) == 1
    [failed_request] = failed_requests
    assert Request.url(failed_request) =~ "one-style.css"
    assert Request.response!(failed_request) == nil
    assert Request.resource_type(failed_request) == "stylesheet"

    case {browser_name, :os.type()} do
      {"chromium", _} ->
        assert Request.failure(failed_request).errorText == "net::ERR_EMPTY_RESPONSE"

      {"webkit", {:unix, :linux}} ->
        assert Request.failure(failed_request).errorText =~
                 ~r/(Message Corrupt)|(Connection terminated unexpectedly)/i

      {"webkit", {:unix, :darwin}} ->
        assert Request.failure(failed_request).errorText == "The network connection was lost."

      {"webkit", {:win32, _}} ->
        assert Request.failure(failed_request).errorText == "Server returned nothing (no headers, no data)"

      {"firefox", _} ->
        assert Request.failure(failed_request).errorText == "NS_ERROR_NET_RESET"
    end

    assert Request.frame(failed_request)
  end

  test "NE-087 Page.Events.RequestFinished @smoke", %{page: page, server: server} do
    request_finished = Page.wait_for_event(page, :request_finished)
    response = Page.goto!(page, server.empty_page)
    Promise.await!(request_finished)
    request = Response.request(response)
    assert Request.url(request) == server.empty_page
    assert Request.response!(request)
    assert Request.frame(request) == Page.main_frame(page)
    assert Frame.url(Request.frame(request)) == server.empty_page
    assert Request.failure(request) == nil
  end

  test "NE-088 should fire events in proper order", %{page: page, server: server} do
    test = self()
    Page.on(page, :request, fn _request -> send(test, {:event, "request"}) end)
    Page.on(page, :response, fn _response -> send(test, {:event, "response"}) end)
    response = Page.goto!(page, server.empty_page)
    assert Response.finished!(response) == nil
    send(test, {:event, "requestfinished"})
    assert received(:event) == ["request", "response", "requestfinished"]
  end

  test "NE-089 should support redirects", %{page: page, server: server} do
    test = self()
    foo_url = server.prefix <> "/foo.html"
    Page.on(page, :request, fn request -> send(test, {:event, {Request.url(request), Request.method(request)}}) end)

    Page.on(page, :response, fn response ->
      send(test, {:event, {Response.url(response), Response.status(response)}})
    end)

    Page.on(page, :request_finished, fn request -> send(test, {:event, {Request.url(request), "DONE"}}) end)
    Page.on(page, :request_failed, fn request -> send(test, {:event, {Request.url(request), "FAIL"}}) end)

    TestServer.set_redirect(server, "/foo.html", "/empty.html")
    response = Page.goto!(page, foo_url)
    Response.finished!(response)

    events =
      Enum.group_by(received(:event), &elem(&1, 0), &elem(&1, 1))

    expected = %{foo_url => ["GET", 302, "DONE"], server.empty_page => ["GET", 200, "DONE"]}
    assert events == expected
    redirected_from = Request.redirected_from(Response.request(response))
    assert Request.url(redirected_from) =~ "/foo.html"
    assert Request.redirected_from(redirected_from) == nil
    assert Request.redirected_to(redirected_from) == Response.request(response)
  end

  test "NE-090 should resolve responses after a cross-process navigation", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43508' }
    test = self()

    TestServer.set_route(server, "/foo", fn conn ->
      send(test, {:response_from_server, self()})

      receive do
        {:end, body} -> Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    Page.goto!(page, server.empty_page)
    request_promise = Page.wait_for_request(page, fn _ -> true end)
    # start a long running request and wait until it hits the server
    Page.evaluate!(page, "url => void fetch(url)", server.prefix <> "/foo")
    assert_receive {:response_from_server, response_from_server}
    request = Promise.await!(request_promise)
    response_promise = Runtime.Promise.async(fn -> Request.response(request) end)
    failed_promise = Page.wait_for_event(page, :request_failed)
    # navigate, which should cancel the request
    Page.goto!(page, server.cross_process_prefix)
    # make sure we aren't stalling this request on the server
    send(response_from_server, {:end, "done"})
    # the response should resolve to null, because the page navigated.
    assert Runtime.Promise.await(response_promise) == {:ok, nil}
    # the request should fail with the browser's "canceled" error.
    assert Promise.await!(failed_promise) == request

    assert Request.failure(request).errorText =~
             %{"chromium" => "net::ERR_ABORTED", "firefox" => "NS_BINDING_ABORTED", "webkit" => "cancelled"}[
               browser_name
             ]
  end

  test "NE-143 should resolve responses after a same-process navigation", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43508' }
    test = self()

    TestServer.set_route(server, "/foo", fn conn ->
      send(test, {:response_from_server, self()})

      receive do
        {:end, body} -> Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    TestServer.set_route(server, "/streaming", fn conn ->
      conn = conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_chunked(200)
      {:ok, conn} = Plug.Conn.chunk(conn, "partial body")
      # The response never ends: the request process waits until the test is over.
      ref = Process.monitor(test)

      receive do
        {:DOWN, ^ref, :process, _, _} -> conn
      end
    end)

    Page.goto!(page, server.empty_page)
    request_promise = Page.wait_for_request(page, server.prefix <> "/foo")
    streaming_response_promise = Page.wait_for_response(page, server.prefix <> "/streaming")
    # start a long running request and wait until it hits the server
    Page.evaluate!(page, "url => void fetch(url)", server.prefix <> "/foo")
    # start a request that never finishes streaming its body
    Page.evaluate!(page, "url => void fetch(url)", server.prefix <> "/streaming")
    assert_receive {:response_from_server, response_from_server}
    request = Promise.await!(request_promise)
    response_promise = Runtime.Promise.async(fn -> Request.response(request) end)
    streaming_response = Promise.await!(streaming_response_promise)
    streaming_text_promise = Runtime.Promise.async(fn -> Response.text(streaming_response) end)
    Page.on(page, :request_failed, fn request -> send(test, {:request_failed, request}) end)
    # navigate within the same process, which should cancel the requests
    Page.goto!(page, server.prefix <> "/title.html")
    # make sure we aren't stalling this request on the server
    send(response_from_server, {:end, "done"})
    # the response should resolve to null, because the page navigated.
    assert Runtime.Promise.await(response_promise) == {:ok, nil}
    # both requests should fail with the browser's "canceled" error.
    error_text =
      %{"chromium" => "net::ERR_ABORTED", "firefox" => "NS_BINDING_ABORTED", "webkit" => "cancelled"}[browser_name]

    # `failedRequests` (pushed by the listener): the listener runs in a process of its own, so
    # the test awaits both events.
    assert_receive {:request_failed, failed1}
    assert_receive {:request_failed, failed2}
    failed_requests = [failed1, failed2] ++ received(:request_failed)

    assert Enum.sort(Enum.map(failed_requests, &Request.url/1)) == [
             server.prefix <> "/foo",
             server.prefix <> "/streaming"
           ]

    assert Request.failure(request).errorText =~ error_text
    assert Request.failure(Response.request(streaming_response)).errorText =~ error_text
    # the partial body should not be available anymore.
    {:error, streaming_text_error} = Runtime.Promise.await(streaming_text_promise)
    assert Exception.message(streaming_text_error) =~ "navigated away"
  end
end
