defmodule PlaywrightEx.Page.PageNetworkRequestTest do
  @upstream "tests/page/page-network-request.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  @moduletag :page

  # Collects events sent by listeners: `const requests = []; page.on('request', r => requests.push(r))`.
  defp received(acc \\ []) do
    receive do
      {:event, event} -> received([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp on_request(page) do
    me = self()
    Page.on(page, :request, &send(me, {:event, &1}))
  end

  defp adjust_server_headers(headers, "firefox"), do: Map.delete(headers, "priority")
  defp adjust_server_headers(headers, _browser_name), do: headers

  # Node's `req.headers` (Bandit lowercases the names, as Node does).
  defp server_headers(conn) do
    Enum.reduce(conn.req_headers, %{}, fn {name, value}, acc ->
      Map.update(acc, name, value, &"#{&1}, #{value}")
    end)
  end

  test "should work for main frame navigation request", %{page: page, server: server} do
    on_request(page)
    Page.goto!(page, server.empty_page)
    requests = received()
    assert length(requests) == 1
    assert Request.frame(Enum.at(requests, 0)) == Page.main_frame(page)
  end

  test "should work for subframe navigation request", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    on_request(page)
    Utils.attach_frame(page, "frame1", server.empty_page)
    requests = received()
    assert length(requests) == 1
    assert Request.frame(Enum.at(requests, 0)) == Enum.at(Page.frames(page), 1)
  end

  test "should work for fetch requests @smoke", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    on_request(page)
    Page.evaluate!(page, "() => fetch('/digits/1.png')")
    requests = received()
    assert length(requests) == 1
    assert Request.frame(Enum.at(requests, 0)) == Page.main_frame(page)
  end

  test "should work for a redirect", %{page: page, server: server} do
    TestServer.set_redirect(server, "/foo.html", "/empty.html")
    on_request(page)
    Page.goto!(page, server.prefix <> "/foo.html")

    requests = received()
    assert length(requests) == 2
    assert Request.url(Enum.at(requests, 0)) == server.prefix <> "/foo.html"
    assert Request.url(Enum.at(requests, 1)) == server.prefix <> "/empty.html"
  end

  # https://github.com/microsoft/playwright/issues/3993
  test "should not work for a redirect and interception", %{page: page, server: server} do
    TestServer.set_redirect(server, "/foo.html", "/empty.html")
    me = self()

    Page.route!(page, "**", fn route ->
      send(me, {:event, Route.request(route)})
      Route.continue(route)
    end)

    Page.goto!(page, server.prefix <> "/foo.html")

    assert Page.url(page) == server.prefix <> "/empty.html"

    requests = received()
    assert length(requests) == 1
    assert Request.url(Enum.at(requests, 0)) == server.prefix <> "/foo.html"
  end

  test "should return headers", %{page: page, server: server, browser_name: browser_name} do
    response = Page.goto!(page, server.empty_page)

    case browser_name do
      "chromium" -> assert Request.headers(Response.request(response))["user-agent"] =~ "Chrome"
      "firefox" -> assert Request.headers(Response.request(response))["user-agent"] =~ "Firefox"
      "webkit" -> assert Request.headers(Response.request(response))["user-agent"] =~ "WebKit"
    end
  end

  test "should get the same headers as the server", %{page: page, server: server, browser_name: browser_name} do
    # it.fail(webkit && win32 && channel !== 'webkit-wsl'): Curl does not show accept-encoding and accept-language
    expected_failure(@browser_name == "webkit" and match?({:win32, _}, :os.type()), fn ->
      me = self()

      TestServer.set_route(server, "/empty.html", fn conn ->
        send(me, {:server_request, conn})
        Plug.Conn.send_resp(conn, 200, "done")
      end)

      response = Page.goto!(page, server.prefix <> "/empty.html")
      headers = Request.all_headers!(Response.request(response))
      assert_received {:server_request, server_request}
      assert headers == adjust_server_headers(server_headers(server_request), browser_name)
    end)
  end

  test "should not return allHeaders() until they are available",
       %{page: page, server: server, browser_name: browser_name} do
    # it.fail(webkit && win32 && channel !== 'webkit-wsl'): Curl does not show accept-encoding and accept-language
    expected_failure(@browser_name == "webkit" and match?({:win32, _}, :os.type()), fn ->
      me = self()
      # `requestHeadersPromise = request.allHeaders()`: started in the listener, awaited later.
      Page.on(page, :request, fn request ->
        Task.start(fn -> send(me, {:request_headers, Request.all_headers(request)}) end)
      end)

      Page.on(page, :response, fn response ->
        Task.start(fn -> send(me, {:response_headers, Response.all_headers(response)}) end)
      end)

      TestServer.set_route(server, "/empty.html", fn conn ->
        send(me, {:server_request, conn})
        conn = conn |> Plug.Conn.put_resp_header("foo", "bar") |> Plug.Conn.send_chunked(200)
        Process.sleep(3000)
        {:ok, conn} = Plug.Conn.chunk(conn, "done")
        conn
      end)

      Page.goto!(page, server.prefix <> "/empty.html")
      assert_receive {:request_headers, {:ok, request_headers}}, 5000
      assert_received {:server_request, server_request}
      assert request_headers == adjust_server_headers(server_headers(server_request), browser_name)

      assert_receive {:response_headers, {:ok, response_headers}}, 5000
      assert response_headers["foo"] == "bar"
    end)
  end

  test "should get the same headers as the server CORS", %{page: page, server: server, browser_name: browser_name} do
    # it.fail(webkit && win32 && channel !== 'webkit-wsl'): Curl does not show accept-encoding and accept-language
    expected_failure(@browser_name == "webkit" and match?({:win32, _}, :os.type()), fn ->
      Page.goto!(page, server.prefix <> "/empty.html")
      me = self()

      TestServer.set_route(server, "/something", fn conn ->
        send(me, {:server_request, conn})
        conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(200, "done")
      end)

      response_promise = Page.wait_for_event(page, :response)

      text =
        Page.evaluate!(
          page,
          """
          async url => {
            const data = await fetch(url);
            return data.text();
          }
          """,
          server.cross_process_prefix <> "/something"
        )

      assert text == "done"
      response = PlaywrightEx.Promise.await!(response_promise)
      headers = Request.all_headers!(Response.request(response))
      assert_received {:server_request, server_request}
      assert headers == adjust_server_headers(server_headers(server_request), browser_name)
    end)
  end

  test "should not get preflight CORS requests when intercepting", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # it.fail(isAndroid, ...)  -- not Android
    Page.goto!(page, server.prefix <> "/empty.html")
    me = self()

    TestServer.set_route(server, "/something", fn conn ->
      send(me, {:event, conn.method})

      if conn.method == "OPTIONS" do
        conn
        |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
        |> Plug.Conn.put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS, DELETE")
        |> Plug.Conn.put_resp_header("access-control-allow-headers", "*")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.send_resp(204, "")
      else
        conn |> Plug.Conn.put_resp_header("access-control-allow-origin", "*") |> Plug.Conn.send_resp(200, "done")
      end
    end)

    fetch = """
    async url => {
      const data = await fetch(url, {
        method: 'DELETE',
        headers: { 'X-PINGOTHER': 'pingpong' }
      });
      return data.text();
    }
    """

    # First check the browser will send preflight request when interception is OFF.
    text = Page.evaluate!(page, fetch, server.cross_process_prefix <> "/something")
    assert text == "done"
    assert received() == ["OPTIONS", "DELETE"]

    # Now check the browser will NOT send preflight request when interception is ON.
    Page.route!(page, "**/something", fn route ->
      send(me, {:routed, Request.method(Route.request(route))})
      Route.continue(route)
    end)

    text = Page.evaluate!(page, fetch, server.cross_process_prefix <> "/something")
    assert text == "done"
    # Check that there was no preflight (OPTIONS) request.
    assert_received {:routed, "DELETE"}
    refute_received {:routed, _}

    # if (browserName === 'firefox' && !isBidi)  -- isBidi: we run the default protocols
    if browser_name == "firefox",
      do: assert(received() == ["OPTIONS", "DELETE"]),
      else: assert(received() == ["DELETE"])
  end

  test "should return postData", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/post", &Plug.Conn.send_resp(&1, 200, ""))
    on_request(page)
    Page.evaluate!(page, "() => fetch('./post', { method: 'POST', body: JSON.stringify({ foo: 'bar' }) })")
    request = List.last(received())
    assert request
    assert Request.post_data(request) == ~s({"foo":"bar"})
  end

  test "should work with binary post data", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/post", &Plug.Conn.send_resp(&1, 200, ""))
    on_request(page)

    Page.evaluate!(page, """
    async () => {
      await fetch('./post', { method: 'POST', body: new Uint8Array(Array.from(Array(256).keys())) });
    }
    """)

    request = List.last(received())
    assert request
    buffer = Request.post_data_buffer(request)
    assert byte_size(buffer) == 256
    for i <- 0..255, do: assert(:binary.at(buffer, i) == i)
  end

  test "should work with binary post data and interception", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/post", &Plug.Conn.send_resp(&1, 200, ""))
    Page.route!(page, "/post", &Route.continue/1)
    on_request(page)

    Page.evaluate!(page, """
    async () => {
      await fetch('./post', { method: 'POST', body: new Uint8Array(Array.from(Array(256).keys())) });
    }
    """)

    request = List.last(received())
    assert request
    buffer = Request.post_data_buffer(request)
    assert byte_size(buffer) == 256
    for i <- 0..255, do: assert(:binary.at(buffer, i) == i)
  end

  test "should override post data content type", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    me = self()

    TestServer.set_route(server, "/post", fn conn ->
      send(me, {:server_request, conn})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.route!(page, "**/post", fn route, request ->
      headers = Map.put(Request.headers(request), "content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      Route.continue(route, headers: headers, post_data: Request.post_data(request))
    end)

    Page.evaluate!(page, """
    async () => {
      await fetch('./post', { method: 'POST', body: 'foo=bar' });
    }
    """)

    assert_received {:server_request, request}
    assert request
    assert Plug.Conn.get_req_header(request, "content-type") == ["application/x-www-form-urlencoded; charset=UTF-8"]
  end

  test "should get |undefined| with postData() when there is no post data", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page)
    assert Request.post_data(Response.request(response)) == nil
  end

  test "should parse the json post data", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/post", &Plug.Conn.send_resp(&1, 200, ""))
    on_request(page)
    Page.evaluate!(page, "() => fetch('./post', { method: 'POST', body: JSON.stringify({ foo: 'bar' }) })")
    request = List.last(received())
    assert request
    assert Request.post_data_json(request) == %{"foo" => "bar"}
  end

  test "should parse the data if content-type is application/x-www-form-urlencoded", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/post", &Plug.Conn.send_resp(&1, 200, ""))
    on_request(page)

    Page.set_content!(
      page,
      "<form method='POST' action='/post'><input type='text' name='foo' value='bar'><input type='number' name='baz' value='123'><input type='submit'></form>"
    )

    Page.click!(page, "input[type=submit]")
    request = List.last(received())
    assert request
    assert Request.post_data_json(request) == %{"foo" => "bar", "baz" => "123"}
  end

  test "should parse the data if content-type is application/x-www-form-urlencoded; charset=UTF-8",
       %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/29872
    Page.goto!(page, server.empty_page)
    request_promise = Page.wait_for_request(page, "**/post")

    Page.evaluate!(page, """
    () => fetch('./post', {
      method: 'POST',
      headers: {
        'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
      },
      body: 'foo=bar&baz=123'
    })
    """)

    assert Request.post_data_json(PlaywrightEx.Promise.await!(request_promise)) == %{"foo" => "bar", "baz" => "123"}
  end

  test "should get |undefined| with postDataJSON() when there is no post data", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page)
    assert Request.post_data_json(Response.request(response)) == nil
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream fixme: File content is missing in WebKit")
  test "should return multipart/form-data", %{page: page, server: server} do
    # it.fixme(browserName === 'webkit'), it.skip(chromium < 126)  -- we run a recent chromium
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/post", &Plug.Conn.send_resp(&1, 200, ""))
    Page.route!(page, "**/*", &Route.continue/1)
    request_promise = Page.wait_for_request(page, "**/post")

    Page.evaluate!(page, """
    async () => {
      const body = new FormData();
      body.set('name1', 'value1');
      body.set('file', new File(['file-value'], 'foo.txt'));
      body.set('name2', 'value2');
      body.append('name2', 'another-value2');
      await fetch('/post', { method: 'POST', body });
    }
    """)

    request = PlaywrightEx.Promise.await!(request_promise)
    content_type = Request.header_value!(request, "Content-Type")
    re = ~r/^multipart\/form-data; boundary=(.*)$/
    assert content_type =~ re
    [_, b] = Regex.run(re, content_type)

    expected =
      "--#{b}\r\nContent-Disposition: form-data; name=\"name1\"\r\n\r\nvalue1\r\n--#{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"foo.txt\"\r\nContent-Type: application/octet-stream\r\n\r\nfile-value\r\n--#{b}\r\nContent-Disposition: form-data; name=\"name2\"\r\n\r\nvalue2\r\n--#{b}\r\nContent-Disposition: form-data; name=\"name2\"\r\n\r\nanother-value2\r\n--#{b}--\r\n"

    assert Request.post_data_buffer(request) == expected
  end

  test "should return event source", %{page: page, server: server} do
    sse_message = %{"foo" => "bar"}
    # 1. Setup server-sent events on server that immediately sends a message to the client.
    TestServer.set_route(server, "/sse", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.put_resp_header("connection", "keep-alive")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "data: #{JSON.encode!(sse_message)}\n\n")
      # `res.write()` without `res.end()`: the response stays open.
      Process.sleep(:infinity)
      conn
    end)

    # 2. Subscribe to page request events.
    Page.goto!(page, server.empty_page)
    on_request(page)
    # 3. Connect to EventSource in browser and return first message.
    assert Page.evaluate!(page, """
           () => {
             const eventSource = new EventSource('/sse');
             return new Promise(resolve => {
               eventSource.onmessage = e => resolve(JSON.parse(e.data));
             });
           }
           """) == sse_message

    assert Request.resource_type(Enum.at(received(), 0)) == "eventsource"
  end

  test "should return navigation bit", %{page: page, server: server} do
    on_request(page)
    TestServer.set_redirect(server, "/rrredirect", "/frames/one-frame.html")
    Page.goto!(page, server.prefix <> "/rrredirect")
    requests = Map.new(received(), &{&1 |> Request.url() |> String.split("/") |> List.last(), &1})
    assert Request.is_navigation_request(requests["rrredirect"]) == true
    assert Request.is_navigation_request(requests["one-frame.html"]) == true
    assert Request.is_navigation_request(requests["frame.html"]) == true
    assert Request.is_navigation_request(requests["script.js"]) == false
    assert Request.is_navigation_request(requests["style.css"]) == false
  end

  test "should return navigation bit when navigating to image", %{page: page, server: server} do
    on_request(page)
    Page.goto!(page, server.prefix <> "/pptr.png")
    assert Request.is_navigation_request(Enum.at(received(), 0)) == true
  end

  test "should report raw headers", %{page: page, server: server, browser_name: browser_name} do
    me = self()

    TestServer.set_route(server, "/headers", fn conn ->
      expected_headers = for {name, value} <- conn.req_headers, do: %{name: name, value: value}
      # if (browserName === 'webkit' && platform === 'win32' ...)  -- not Windows WebKit
      expected_headers =
        if browser_name == "firefox",
          do: Enum.reject(expected_headers, &(String.downcase(&1.name) == "priority")),
          else: expected_headers

      send(me, {:expected_headers, expected_headers})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.goto!(page, server.empty_page)

    request =
      Page.expect_request!(page, "**/*", fn ->
        Page.evaluate!(page, """
        () => fetch('/headers', {
          headers: [
            ['header-a', 'value-a'],
            ['header-b', 'value-b'],
            ['header-a', 'value-a-1'],
            ['header-a', 'value-a-2'],
          ]
        })
        """)
      end)

    headers = Request.headers_array!(request)
    assert_received {:expected_headers, expected_headers}
    # Deviation: Bandit lowercases the raw header names (Node's `req.rawHeaders` keeps them), so
    # the names are compared lowercased.
    headers = for %{name: name, value: value} <- headers, do: %{name: String.downcase(name), value: value}
    assert Enum.sort_by(headers, & &1.name) == Enum.sort_by(expected_headers, & &1.name)
    assert Request.header_value!(request, "header-a") == "value-a, value-a-1, value-a-2"
    assert Request.header_value!(request, "not-there") == nil
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream skip: WebKit won't give us raw headers for redirects")
  test "should report raw response headers in redirects", %{page: page, server: server} do
    TestServer.set_extra_headers(server, "/redirect/1.html", %{"sec-test-header" => "1.html"})
    TestServer.set_extra_headers(server, "/redirect/2.html", %{"sec-test-header" => "2.html"})
    TestServer.set_extra_headers(server, "/empty.html", %{"sec-test-header" => "empty.html"})
    TestServer.set_redirect(server, "/redirect/1.html", "/redirect/2.html")
    TestServer.set_redirect(server, "/redirect/2.html", "/empty.html")

    expected_urls = Enum.map(["/redirect/1.html", "/redirect/2.html", "/empty.html"], &(server.prefix <> &1))
    expected_headers = ["1.html", "2.html", "empty.html"]

    response = Page.goto!(page, server.prefix <> "/redirect/1.html")

    {redirect_chain, headers_chain} =
      response
      |> Response.request()
      |> Stream.unfold(fn
        nil -> nil
        req -> {req, Request.redirected_from(req)}
      end)
      |> Enum.reduce({[], []}, fn req, {redirect_chain, headers_chain} ->
        res = Request.response!(req)
        headers = Response.all_headers!(res)
        {[Request.url(req) | redirect_chain], [headers["sec-test-header"] | headers_chain]}
      end)

    assert redirect_chain == expected_urls
    assert headers_chain == expected_headers
  end

  test "should report all cookies in one header", %{page: page, server: server} do
    TestServer.set_route(server, "/headers", &Plug.Conn.send_resp(&1, 200, ""))

    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      document.cookie = 'myCookie=myValue';
      document.cookie = 'myOtherCookie=myOtherValue';
    }
    """)

    response = Page.goto!(page, server.empty_page)
    cookie = Request.all_headers!(Response.request(response))["cookie"]
    assert cookie == "myCookie=myValue; myOtherCookie=myOtherValue"
  end

  test "should not allow to access frame on popup main request", %{page: page, server: server} do
    Page.set_content!(page, ~s(<a target=_blank href="#{server.empty_page}">click me</a>))
    request_promise = BrowserContext.wait_for_event(Page.context(page), :request)
    popup_promise = BrowserContext.wait_for_event(Page.context(page), :page)
    clicked = Task.async(fn -> page |> Page.get_by_text("click me") |> Locator.click!() end)
    request = PlaywrightEx.Promise.await!(request_promise)

    assert Request.is_navigation_request(request) == true

    error =
      try do
        Request.frame(request)
        nil
      rescue
        e -> e
      end

    assert Exception.message(error) =~ "Frame for this navigation request is not available"

    response = Request.response!(request)
    Response.finished!(response)
    PlaywrightEx.Promise.await!(popup_promise)
    Task.await(clicked, :infinity)
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: Does not send second request")
  test "page.reload return 304 status code", %{page: page, server: server, browser_name: browser_name} do
    # issue: https://github.com/microsoft/playwright/issues/28779
    # issue: https://github.com/microsoft/playwright/issues/29441
    {:ok, request_number} = Agent.start_link(fn -> 0 end)

    TestServer.set_route(server, "/test.html", fn conn ->
      n = Agent.get_and_update(request_number, &{&1 + 1, &1 + 1})

      conn =
        conn
        |> Plug.Conn.put_resp_header("cf-cache-status", "DYNAMIC")
        |> Plug.Conn.put_resp_header("content-type", "text/html;charset=UTF-8")
        |> Plug.Conn.put_resp_header("last-modified", "Fri, 05 Jan 2024 01:56:20 GMT")
        |> Plug.Conn.put_resp_header("vary", "Access-Control-Request-Headers")

      # Node drops the body of a 304 (`res.write()` is a no-op), Plug refuses it.
      if n == 1,
        do: Plug.Conn.send_resp(conn, 200, "<div>Test</div>"),
        else: Plug.Conn.send_resp(conn, 304, "")
    end)

    response1 = Page.goto!(page, server.prefix <> "/test.html")
    assert Response.status(response1) == 200
    response2 = Page.reload!(page)
    assert Agent.get(request_number, & &1) == 2

    if browser_name == "chromium" do
      assert Response.status(response2) == 200
      assert Response.status_text(response2) == "OK"
      assert Response.text!(response2) == "<div>Test</div>"
    else
      assert Response.status(response2) == 304
      assert Response.status_text(response2) == "Not Modified"
    end
  end

  @tag skip:
         if(@browser_name != "chromium",
           do: "upstream skip: FF and WK actually succeed with the request, and block afterwards"
         )
  test "should handle mixed-content blocked requests", %{page: page, asset: asset} do
    # issue: https://github.com/microsoft/playwright/issues/29833
    Page.route!(page, "**/mixedcontent.html", fn route ->
      Route.fulfill(route,
        status: 200,
        content_type: "text/html",
        body: """
            <!doctype html>
            <meta charset="utf-8">
            <style>
            @font-face {
              font-family: 'pwtest-iconfont';
              src: url('http://another.com/iconfont.woff2') format('woff2');
            }
            body {
              font-family: 'pwtest-iconfont';
            }
            </style>
            <span>+-</span>
        """
      )
    end)

    Page.route!(page, "**/iconfont.woff2", fn route ->
      body = File.read!(asset.("webfont/iconfont2.woff"))
      Route.fulfill!(route, body: {:binary, body})
    end)

    request =
      Page.expect_event!(page, :request_failed, fn -> Page.goto!(page, "https://example.com/mixedcontent.html") end,
        predicate: &(Request.url(&1) =~ "iconfont.woff2")
      )

    headers = Request.all_headers!(request)
    assert headers["origin"]
    assert Request.failure(request).errorText == "mixed-content"
  end
end
