defmodule PlaywrightEx.Page.PageNetworkSizesTest do
  @upstream "tests/page/page-network-sizes.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer

  @moduletag :page

  # it.skip(({ isElectron, browserMajorVersion }) => isElectron && browserMajorVersion < 99, 'This needs Chromium >= 99');  -- not Electron

  @browser_name System.get_env("BROWSER", "chromium")

  test "NE-058 should set bodySize and headersSize", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    request = Page.wait_for_event(page, :request)
    Page.evaluate!(page, "() => fetch('./get', { method: 'POST', body: '12345' }).then(r => r.text())")
    request = Promise.await!(request)
    sizes = Request.sizes!(request)
    assert sizes.requestBodySize == 5
    assert sizes.requestHeadersSize >= 250
  end

  test "NE-059 should set bodySize to 0 if there was no body", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    request = Page.wait_for_event(page, :request)
    Page.evaluate!(page, "() => fetch('./get').then(r => r.text())")
    request = Promise.await!(request)
    sizes = Request.sizes!(request)
    assert sizes.requestBodySize == 0
    assert sizes.requestHeadersSize >= 190
  end

  test "NE-060 should set bodySize, headersSize, and transferSize", %{page: page, server: server} do
    TestServer.set_route(server, "/get", fn conn ->
      # In Firefox, |fetch| will be hanging until it receives |Content-Type| header
      # from server.
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8")
      |> Plug.Conn.send_resp(200, "abc134")
    end)

    Page.goto!(page, server.empty_page)
    response = Page.wait_for_event(page, :response)
    server_request = TestServer.wait_for_request(server, "/get")
    Page.evaluate!(page, "async () => fetch('./get').then(r => r.text())")
    response = Promise.await!(response)
    Task.await(server_request, :infinity)
    sizes = Request.sizes!(Response.request(response))
    assert sizes.responseBodySize == 6
    assert sizes.responseHeadersSize >= 100
  end

  test "NE-061 should set bodySize to 0 when there was no response body", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page)
    sizes = Request.sizes!(Response.request(response))
    assert sizes.responseBodySize == 0
    assert sizes.responseHeadersSize >= 150
  end

  test "NE-062 should have the correct responseBodySize", %{page: page, server: server, asset: asset} do
    response = Page.goto!(page, server.prefix <> "/simplezip.json")
    sizes = Request.sizes!(Response.request(response))
    assert sizes.responseBodySize == File.stat!(asset.("simplezip.json")).size
  end

  @tag skip:
         (cond do
            @browser_name == "firefox" ->
              "upstream fixme: firefox"

            @browser_name == "webkit" and not match?({:unix, :darwin}, :os.type()) ->
              "upstream fixme: webkit on non-darwin"

            true ->
              nil
          end)
  test "NE-063 should have the correct responseBodySize for chunked request", %{
    page: page,
    server: server,
    asset: asset,
    browser_name: browser_name
  } do
    # it.fixme(browserName === 'webkit' && platform !== 'darwin');
    content = File.read!(asset.("simplezip.json"))
    amount_of_chunks = 10
    chunk_size = ceil(byte_size(content) / amount_of_chunks)

    TestServer.set_route(server, "/chunked-simplezip.json", fn conn ->
      conn =
        conn |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8") |> Plug.Conn.send_chunked(200)

      for start <- 0..(byte_size(content) - 1)//chunk_size, reduce: conn do
        conn ->
          size = min(chunk_size, byte_size(content) - start)
          # Wait for each chunk to be flushed, otherwise Node 26 merges synchronous writes into a single chunk.
          # (Plug.Conn.chunk/2 returns once the chunk is sent.)
          {:ok, conn} = Plug.Conn.chunk(conn, binary_part(content, start, size))
          conn
      end
    end)

    response = Page.goto!(page, server.prefix <> "/chunked-simplezip.json")
    sizes = Request.sizes!(Response.request(response))
    # The actual file size is 5100 bytes. The extra 75 bytes are coming from the chunked encoding headers and end bytes.
    if browser_name == "webkit" do
      # WebKit on macOS reports 5173 with the legacy CFNetwork loader (builds <= 2346) and the
      # correct 5175 with NWLoader. Upstream to-do: expect 5175 once the NWLoader-based build ships.
      assert sizes.responseBodySize in [5173, 5175]
    else
      assert sizes.responseBodySize == 5175
    end
  end

  test "NE-064 should have the correct responseBodySize with gzip compression", %{
    page: page,
    server: server,
    asset: asset
  } do
    TestServer.enable_gzip(server, "/simplezip.json")
    Page.goto!(page, server.empty_page)
    response = Page.wait_for_event(page, :response)
    Page.evaluate!(page, "() => fetch('./simplezip.json').then(r => r.text())")
    response = Promise.await!(response)
    sizes = Request.sizes!(Response.request(response))

    assert sizes.responseBodySize == byte_size(:zlib.gzip(File.read!(asset.("simplezip.json"))))
  end

  test "NE-065 should handle redirects", %{page: page, server: server} do
    TestServer.set_redirect(server, "/foo", "/bar")
    TestServer.set_route(server, "/bar", &Plug.Conn.send_resp(&1, 200, "bar"))
    Page.goto!(page, server.empty_page)
    response = Page.wait_for_event(page, :response)

    Page.evaluate!(page, """
    async () => fetch('/foo', {
      method: 'POST',
      body: '12345',
    }).then(r => r.text())
    """)

    response = Promise.await!(response)
    assert Request.sizes!(Response.request(response)).requestBodySize == 5
    new_request = Request.redirected_to(Response.request(response))
    assert Request.sizes!(new_request).responseBodySize == 3
  end

  test "NE-066 should throw for failed requests", %{page: page, server: server} do
    # res.connection.destroy(): kill the connection's handler process.
    TestServer.set_route(server, "/one-style.css", fn _conn -> Process.exit(self(), :kill) end)
    Page.goto!(page, server.empty_page)
    request = Page.wait_for_event(page, :request_failed)
    Page.goto!(page, server.prefix <> "/one-style.html")
    request = Promise.await!(request)
    assert {:error, error} = Request.sizes(request)
    assert Exception.message(error) =~ "Unable to fetch sizes for failed request"
  end

  for status_code <- [200, 401, 404, 500] do
    @status_code status_code
    test "NE-067 should work with #{status_code} status code", %{page: page, server: server} do
      status_code = @status_code

      TestServer.set_route(server, "/foo", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8")
        |> Plug.Conn.put_resp_header("content-length", "3")
        |> Plug.Conn.send_resp(status_code, "bar")
      end)

      Page.goto!(page, server.empty_page)
      response = Page.wait_for_event(page, :response)

      Page.evaluate!(page, """
      async () => fetch('/foo', {
        method: 'POST',
        body: '12345',
      }).then(r => r.text())
      """)

      response = Promise.await!(response)
      assert Response.status(response) == status_code
      sizes = Request.sizes!(Response.request(response))
      assert sizes.requestBodySize == 5
      assert sizes.responseBodySize == 3
    end
  end

  @tag skip: if(@browser_name == "chromium", do: "upstream fixme: chromium")
  test "NE-068 should have correct responseBodySize for 404 with content", %{page: page, server: server} do
    TestServer.set_route(
      server,
      "/broken-image.png",
      &Plug.Conn.send_resp(&1, 404, "<p>this should have a non-negative size</p>")
    )

    TestServer.set_route(server, "/page-with-404-image.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      <!DOCTYPE html>
      <html>
        <head><title>Page with Broken Image</title></head>
        <body>
          <img src="/broken-image.png" />
        </body>
      </html>
      """)
    end)

    req = Page.wait_for_request(page, ~r/broken-image\.png$/)
    Page.goto!(page, server.prefix <> "/page-with-404-image.html")
    req = Promise.await!(req)

    %{responseBodySize: response_body_size} = Request.sizes!(req)
    assert response_body_size >= 0
  end

  @tag skip: if(@browser_name == "chromium", do: "upstream fixme: chromium")
  test "NE-069 should return sizes without hanging", %{page: page, server: server} do
    TestServer.set_route(server, "/has-abandoned-fetch", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      <!DOCTYPE html>
      <html>
        <head><title>t</title></head>
        <body>
          <script>
            fetch("./404");
          </script>
        </body>
      </html>
      """)
    end)

    req = Page.wait_for_request(page, ~r/404$/)
    Page.goto!(page, server.prefix <> "/has-abandoned-fetch")
    req = Promise.await!(req)

    Request.sizes!(req)
  end
end
