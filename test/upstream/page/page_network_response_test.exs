defmodule PlaywrightEx.Page.PageNetworkResponseTest do
  @upstream "tests/page/page-network-response.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  @moduletag :page

  # url.pathToFileURL(path).href
  defp path_to_file_url(path), do: "file://" <> URI.encode(path)

  # `res.writeHead(200, headers); res.end()`: Plug's default `cache-control` is dropped, and the
  # response is chunked, as Node's without a body (`transfer-encoding` is filtered by the tests).
  defp write_head(conn, status, headers), do: Plug.Conn.send_chunked(%{conn | resp_headers: headers}, status)

  # `server.setRoute(path, (req, res) => { serverResponse = res; ... })`: the request process
  # sends itself to the test, which then drives the response (`serverResponse.write(...)`).
  defp server_response_loop(conn) do
    receive do
      {:write, data, from} ->
        {:ok, conn} = Plug.Conn.chunk(conn, data)
        send(from, :written)
        server_response_loop(conn)

      {:end, data, from} ->
        {:ok, conn} = Plug.Conn.chunk(conn, data)
        send(from, :written)
        conn
    end
  end

  defp server_write(pid, data, op \\ :write) do
    send(pid, {op, data, self()})
    assert_receive :written, 5000
  end

  test "NE-030 should work @smoke", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn = Plug.Conn.put_resp_header(conn, "foo", "bar")
      # `res.setHeader('BaZ', 'bAz')`: put_resp_header wants lowercase names.
      conn = %{conn | resp_headers: conn.resp_headers ++ [{"BaZ", "bAz"}]}
      Plug.Conn.send_resp(conn, 200, "")
    end)

    response = Page.goto!(page, server.empty_page)
    assert Response.all_headers!(response)["foo"] == "bar"
    assert Response.all_headers!(response)["baz"] == "bAz"
    assert Response.all_headers!(response)["BaZ"] == nil
  end

  @tag skip:
         if(@browser_name == "webkit" and match?({:win32, _}, :os.type()),
           do: "upstream skip: libcurl does not support non-set-cookie multivalue headers"
         )
  test "NE-031 should return multiple header value", %{page: page, server: server} do
    # it.skip(browserName === 'webkit' && platform === 'win32', ...)  -- not Windows WebKit
    TestServer.set_route(server, "/headers", fn conn ->
      # Upstream writes directly to the socket to repeat a header: Plug sends repeated entries.
      write_head(conn, 200, [{"Name-A", "v1"}, {"Name-a", "v2"}, {"name-A", "v3"}])
    end)

    response = Page.goto!(page, "#{server.prefix}/headers")
    assert Response.status(response) == 200
    assert Response.headers(response)["name-a"] == "v1, v2, v3"
  end

  test "NE-032 should return text", %{page: page, server: server} do
    response = Page.goto!(page, server.prefix <> "/simple.json")
    assert Response.text!(response) == ~s({"foo": "bar"}\n)
  end

  test "NE-033 should return uncompressed text", %{page: page, server: server} do
    TestServer.enable_gzip(server, "/simple.json")
    response = Page.goto!(page, server.prefix <> "/simple.json")
    assert Response.headers(response)["content-encoding"] == "gzip"
    assert Response.text!(response) == ~s({"foo": "bar"}\n)
  end

  test "NE-034 should return uncompressed text for brotli encoding", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/39160
    # it.fixme(isAndroid, 'net::ERR_CONTENT_DECODING_FAILED')  -- not Android
    text = ~s({"foo": "bar"}\n)
    # zlib.brotliCompressSync(Buffer.from(text)): no Brotli in OTP, precomputed with Node.
    compressed = Base.decode64!("CweAeyJmb28iOiAiYmFyIn0KAw==")

    TestServer.set_route(server, "/brotli.json", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.put_resp_header("content-encoding", "br")
      |> Plug.Conn.send_resp(200, compressed)
    end)

    response = Page.goto!(page, server.prefix <> "/brotli.json")
    assert Response.headers(response)["content-encoding"] == "br"
    assert Response.text!(response) == text
  end

  test "NE-035 should return text for identity encoding", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/42501
    text = "<div>hello</div>"

    TestServer.set_route(server, "/identity.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8")
      |> Plug.Conn.put_resp_header("content-encoding", "Identity")
      |> Plug.Conn.send_resp(200, text)
    end)

    response = Page.goto!(page, server.prefix <> "/identity.html")
    assert Response.headers(response)["content-encoding"] == "Identity"
    assert Response.text!(response) == text
  end

  test "NE-036 should throw when requesting body of redirected response", %{page: page, server: server} do
    TestServer.set_redirect(server, "/foo.html", "/empty.html")
    response = Page.goto!(page, server.prefix <> "/foo.html")
    redirected_from = Request.redirected_from(Response.request(response))
    assert redirected_from
    redirected = Request.response!(redirected_from)
    assert Response.status(redirected) == 302
    {:error, error} = Response.text(redirected)
    assert Exception.message(error) =~ "Response body is unavailable for redirect responses"
  end

  test "NE-037 should wait until response completes", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    me = self()
    # Setup server to trap request.
    TestServer.set_route(server, "/get", fn conn ->
      # In Firefox, |fetch| will be hanging until it receives |Content-Type| header
      # from server.
      conn =
        conn |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8") |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "hello ")
      send(me, {:server_response, self()})
      server_response_loop(conn)
    end)

    # Setup page to trap response.
    Page.on(page, :request_finished, fn r -> if Request.url(r) =~ "/get", do: send(me, :request_finished) end)
    # send request and wait for server response
    response_promise = Page.wait_for_event(page, :response)
    server_request = TestServer.wait_for_request(server, "/get")
    Page.evaluate!(page, "() => fetch('./get', { method: 'GET' })")
    Task.await(server_request, :infinity)
    page_response = PlaywrightEx.Promise.await!(response_promise)

    assert_receive {:server_response, server_response}, 5000
    assert page_response
    assert Response.status(page_response) == 200
    refute_received :request_finished

    response_text = Runtime.Promise.async(fn -> Response.text!(page_response) end)
    # Write part of the response and wait for it to be flushed.
    server_write(server_response, "wor")
    # Finish response.
    server_write(server_response, "ld!", :end)
    assert Runtime.Promise.await(response_text) == "hello world!"
  end

  test "NE-038 should return json", %{page: page, server: server} do
    response = Page.goto!(page, server.prefix <> "/simple.json")
    assert Response.json!(response) == %{"foo" => "bar"}
  end

  test "NE-039 should return body", %{page: page, server: server, asset: asset} do
    response = Page.goto!(page, server.prefix <> "/pptr.png")
    image_buffer = File.read!(asset.("pptr.png"))
    response_buffer = Response.body!(response)
    assert response_buffer == image_buffer
  end

  test "NE-040 should return body with compression", %{page: page, server: server, asset: asset} do
    TestServer.enable_gzip(server, "/pptr.png")
    response = Page.goto!(page, server.prefix <> "/pptr.png")
    image_buffer = File.read!(asset.("pptr.png"))
    response_buffer = Response.body!(response)
    assert response_buffer == image_buffer
  end

  # issue: https://github.com/microsoft/playwright/issues/40510
  @tag skip:
         (cond do
            @browser_name == "webkit" ->
              "upstream fixme: webkit encodes the response body"

            @browser_name == "chromium" and @browser_major_version < 151 ->
              "upstream fixme: older chromium re-encodes the non-utf8 response body and lacks Response.bytes()"

            true ->
              nil
          end)
  test "NE-041 should return non-utf8 body even when content-type says utf8",
       %{page: page, server: server} do
    # Binary data with bytes that are invalid UTF-8.
    bytes = [0x80, 0x81, 0x82, 0xFF, 0xFE, 0x00, 0x01, 0x02]
    buffer = :binary.list_to_bin(bytes)

    TestServer.set_route(server, "/binary-as-text", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain;charset=UTF-8")
      |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(buffer)))
      |> Plug.Conn.send_resp(200, buffer)
    end)

    Page.goto!(page, server.empty_page)
    response_promise = Page.wait_for_response(page, server.prefix <> "/binary-as-text")

    bytes_received =
      Page.evaluate!(page, "url => fetch(url).then(r => r.bytes())", server.prefix <> "/binary-as-text")

    response = PlaywrightEx.Promise.await!(response_promise)
    body = Response.body!(response)
    assert body == buffer
    # `Array.from(bytesReceived)`: a Uint8Array serializes as an array.
    assert bytes_received == bytes
  end

  test "NE-042 should return status text", %{page: page, server: server} do
    TestServer.set_route(server, "/cool", &TestServer.send_resp(&1, 200, "cool!"))
    response = Page.goto!(page, server.prefix <> "/cool")
    assert Response.status_text(response) == "cool!"
  end

  @tag skip:
         if(@browser_name == "webkit" and match?({:win32, _}, :os.type()),
           do: "upstream skip: libcurl does not support non-set-cookie multivalue headers"
         )
  test "NE-043 should report all headers", %{page: page, server: server} do
    # it.skip(browserName === 'webkit' && platform === 'win32', ...)  -- not Windows WebKit
    expected_headers = %{
      "header-a" => ["value-a", "value-a-1", "value-a-2"],
      "header-b" => ["value-b"]
    }

    TestServer.set_route(server, "/headers", fn conn ->
      write_head(conn, 200, for({name, values} <- expected_headers, value <- values, do: {name, value}))
    end)

    Page.goto!(page, server.empty_page)
    response = Page.expect_response!(page, "**/*", fn -> Page.evaluate!(page, "() => fetch('/headers')") end)
    headers = Response.headers_array!(response)

    actual_headers =
      headers
      |> Enum.group_by(& &1.name, & &1.value)
      |> Map.drop(~w(Keep-Alive keep-alive Connection connection Date date Transfer-Encoding transfer-encoding))
      # Deviation: Bandit (not Node) adds `vary: accept-encoding`.
      |> Map.delete("vary")

    assert actual_headers == expected_headers
  end

  test "NE-044 should report multiple set-cookie headers", %{page: page, server: server} do
    # it.skip(isElectron && browserMajorVersion < 99, 'This needs Chromium >= 99');  -- not ported: no Electron
    TestServer.set_route(server, "/headers", fn conn ->
      conn = write_head(conn, 200, [{"Set-Cookie", "a=b"}, {"Set-Cookie", "c=d"}])
      {:ok, conn} = Plug.Conn.chunk(conn, "\r\n")
      conn
    end)

    Page.goto!(page, server.empty_page)
    response = Page.expect_response!(page, "**/*", fn -> Page.evaluate!(page, "() => fetch('/headers')") end)
    headers = Response.headers_array!(response)
    cookies = for %{name: name, value: value} <- headers, String.downcase(name) == "set-cookie", do: value
    assert cookies == ["a=b", "c=d"]
    assert Response.header_value!(response, "not-there") == nil
    assert Response.header_value!(response, "set-cookie") == "a=b\nc=d"
    assert Response.header_values!(response, "set-cookie") == ["a=b", "c=d"]
  end

  @tag skip:
         if(@browser_name == "webkit" and match?({:win32, _}, :os.type()),
           do: "upstream skip: libcurl does not support non-set-cookie multivalue headers"
         )
  test "NE-045 should behave the same way for headers and allHeaders",
       %{page: page, server: server, browser_name: browser_name} do
    TestServer.set_route(server, "/headers", fn conn ->
      headers = [
        {"Set-Cookie", "a=b"},
        {"Set-Cookie", "c=d"},
        {"header-a", "a=b"},
        {"header-a", "c=d"},
        {"Name-A", "v1"},
        {"name-b", "v4"},
        {"Name-a", "v2"},
        {"name-A", "v3"}
      ]

      # Chromium does not report set-cookie headers immediately, so they are missing from .headers()
      headers =
        if browser_name == "chromium",
          do: List.keydelete(List.keydelete(headers, "Set-Cookie", 0), "Set-Cookie", 0),
          else: headers

      conn = write_head(conn, 200, headers)
      {:ok, conn} = Plug.Conn.chunk(conn, "\r\n")
      conn
    end)

    Page.goto!(page, server.empty_page)
    response = Page.expect_response!(page, "**/*", fn -> Page.evaluate!(page, "() => fetch('/headers')") end)
    all_headers = Response.all_headers!(response)
    assert Response.headers(response) == all_headers
    assert all_headers["header-a"] == "a=b, c=d"
    assert all_headers["name-a"] == "v1, v2, v3"
    assert all_headers["name-b"] == "v4"
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream skip: Firefox does return null for file:// URLs")
  test "NE-046 should provide a Response with a file URL", %{page: page, asset: asset, browser_name: browser_name} do
    # it.skip(isAndroid), it.skip(channel === 'webkit-wsl')  -- neither
    fileurl = path_to_file_url(asset.("frames/two-frames.html"))
    response = Page.goto!(page, fileurl)

    # isElectron || chromium || (webkit && isWindows)
    if browser_name == "chromium" or (browser_name == "webkit" and match?({:win32, _}, :os.type())),
      do: assert(Response.status(response) == 200),
      else: assert(Response.status(response) == 0)

    assert Response.ok(response) == true
  end

  test "NE-047 should return set-cookie header after route.fulfill", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # it.fail(browserName === 'webkit' || browserName === 'chromium', 'https://github.com/microsoft/playwright/issues/11035')
    expected_failure(browser_name in ["webkit", "chromium"], fn ->
      Page.route!(page, "**/*", fn route ->
        Route.fulfill!(route, status: 200, headers: %{"set-cookie" => "a=b"}, content_type: "text/plain", body: "")
      end)

      response = Page.goto!(page, server.empty_page)
      headers = Response.all_headers!(response)
      assert headers["set-cookie"] == "a=b"
    end)
  end

  test "NE-048 should return headers after route.fulfill", %{page: page, server: server} do
    Page.route!(page, "**/*", fn route ->
      Route.fulfill!(route,
        status: 200,
        headers: %{"foo" => "bar", "content-language" => "en"},
        content_type: "text/plain",
        body: "done"
      )
    end)

    response = Page.goto!(page, server.empty_page)

    assert Response.all_headers!(response) == %{
             "foo" => "bar",
             "content-type" => "text/plain",
             "content-length" => "4",
             "content-language" => "en"
           }
  end

  test "NE-049 should report if request was fromServiceWorker", %{page: page, server: server} do
    # it.skip(isAndroid || isElectron)  -- neither
    res = Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
    assert Response.from_service_worker(res) == false

    Page.evaluate!(page, "() => window['activationPromise']")

    res =
      Page.expect_response!(page, ~r/example\.txt/, fn -> Page.evaluate!(page, "() => fetch('/example.txt')") end)

    assert Response.from_service_worker(res) == true
  end

  @tag skip:
         (cond do
            @browser_name == "webkit" ->
              "upstream skip: No prefetch in WebKit: https://caniuse.com/link-rel-prefetch"

            @browser_name == "chromium" and @browser_major_version < 138 ->
              "upstream skip: Requires Sec-Purpose header, shipped in Chrome 138"

            true ->
              nil
          end)
  test "NE-050 should return body for prefetch script", %{
    page: page,
    server: server
  } do
    response =
      Page.expect_response!(page, "**/prefetch.js", fn -> Page.goto!(page, server.prefix <> "/prefetch.html") end)

    body = Response.body!(response)
    assert body == "// Scripts will be pre-fetched"
  end

  @tag skip:
         if(match?({:unix, :darwin}, :os.type()) and @browser_name == "webkit",
           do: "upstream fixme: WebKit on Mac evicts the body and returns empty buffer"
         )
  test "NE-051 should return body for image with evicted body", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/42002
    # truncated 1x1 gif, Chromium evicts its body
    image_base64 = "R0lGODlhAQABAAAAACw="

    TestServer.set_route(server, "/pixel.gif", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/gif")
      |> Plug.Conn.send_resp(200, Base.decode64!(image_base64))
    end)

    TestServer.set_route(server, "/page.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s(<html><body><img src="/pixel.gif"></body></html>))
    end)

    response = Page.expect_response!(page, "**/pixel.gif", fn -> Page.goto!(page, server.prefix <> "/page.html") end)
    body = Response.body!(response)
    assert Base.encode64(body) == image_base64
  end

  test "NE-052 should bypass disk cache when page interception is enabled", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/30000
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    Page.route!(page, "**/api*", &Route.continue/1)
    me = self()

    api_route = fn conn ->
      send(me, {:request, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=31536000")
      |> Plug.Conn.send_resp(200, "Hello")
    end

    # Counts every server hit so far, as upstream's `requests.length`.
    count = fn path, acc -> count_requests(path, acc) end

    TestServer.set_route(server, "/api", api_route)

    Enum.reduce(0..2, 0, fn i, requests ->
      # main frame iteration #{i}
      resp_promise = Page.wait_for_response(page, "**/api")

      Page.evaluate!(page, """
      async () => {
        const response = await fetch('/api');
        return response.status;
      }
      """)

      response = PlaywrightEx.Promise.await!(resp_promise)
      assert Response.status(response) == 200
      requests = count.("/api", requests)
      assert requests == i + 1
      requests
    end)

    TestServer.set_route(server, "/frame/api", api_route)

    Enum.reduce(0..2, 0, fn i, requests ->
      # subframe iteration #{i}
      resp_promise = Page.wait_for_response(page, "**/frame/api")

      page
      |> Page.frame(%{url: "**/frame.html"})
      |> Frame.evaluate!("""
      async () => {
        const response = await fetch('/frame/api');
        return response.status;
      }
      """)

      response = PlaywrightEx.Promise.await!(resp_promise)
      assert Response.status(response) == 200
      requests = count.("/frame/api", requests)
      assert requests == i + 1
      requests
    end)
  end

  test "NE-053 request.existingResponse should return null before response is received", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    me = self()

    TestServer.set_route(server, "/get", fn conn ->
      send(me, {:server_response, self()})
      # Don't end the response yet
      receive do
        :end ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8")
          |> Plug.Conn.send_resp(200, "done")
      end
    end)

    request_promise = Page.wait_for_event(page, :request)
    server_request = TestServer.wait_for_request(server, "/get")
    Page.evaluate!(page, "() => { void fetch('./get', { method: 'GET' }); }")
    request = PlaywrightEx.Promise.await!(request_promise)
    Task.await(server_request, :infinity)
    assert_receive {:server_response, server_response}, 5000

    # Response hasn't been received yet
    assert Request.existing_response(request) == nil

    # Now send the response
    # (the wait starts first: the server ends the response in another process)
    response_promise = Page.wait_for_event(page, :response)
    send(server_response, :end)
    PlaywrightEx.Promise.await!(response_promise)

    # After response is received, existingResponse should return the response
    existing_response = Request.existing_response(request)
    assert existing_response != nil
    assert Response.status(existing_response) == 200
  end

  test "NE-054 request.existingResponse should return the response after it is received", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page)
    request = Response.request(response)
    assert Request.existing_response(request) == response
  end

  test "NE-055 should return http version", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page)
    assert Response.http_version!(response) == "HTTP/1.1"
  end

  test "NE-056 Response.formData() should parse multipart/form-data in page context", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/40244
    Page.goto!(page, server.empty_page)

    result =
      Page.evaluate!(page, """
      async () => {
        const boundary = '----WebKitFormBoundary1234';
        const body = [
          `--${boundary}`,
          'Content-Disposition: form-data; name="field1"',
          '',
          'value1',
          `--${boundary}`,
          'Content-Disposition: form-data; name="file1"; filename="test.txt"',
          'Content-Type: text/plain',
          '',
          'hello',
          `--${boundary}--`,
        ].join('\\r\\n');
        const response = new Response(body, {
          headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}` },
        });
        const fd = await response.formData();
        const file = fd.get('file1');
        return {
          field1: fd.get('field1'),
          filename: file instanceof File ? file.name : null,
          fileContent: file instanceof File ? await file.text() : null,
        };
      }
      """)

    assert result["field1"] == "value1"
    assert result["filename"] == "test.txt"
    assert result["fileContent"] == "hello"
  end

  @tag skip:
         if(@browser_name == "firefox",
           do: "upstream skip: Firefox keeps the response body available after navigating away, so it never throws"
         )
  test "NE-057 should give a readable error when response.body() races with navigation",
       %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/41512
    response =
      Page.expect_response!(page, server.prefix <> "/title.html", fn ->
        Page.goto!(page, server.prefix <> "/title.html")
      end)

    # Navigate away — the browser frees the network resource from the first page load.
    # The first page must have a non-empty body, otherwise WebKit returns an empty buffer instead of throwing.
    Page.goto!(page, server.prefix <> "/grid.html")
    {:error, error} = Response.body(response)
    assert is_exception(error)
    assert Exception.message(error) =~ "navigated away"
  end

  defp count_requests(path, acc) do
    receive do
      {:request, ^path} -> count_requests(path, acc + 1)
    after
      0 -> acc
    end
  end
end
