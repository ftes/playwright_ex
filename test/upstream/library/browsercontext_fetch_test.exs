defmodule PlaywrightEx.Library.BrowsercontextFetchTest do
  @upstream "tests/library/browsercontext-fetch.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import Bitwise

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.TestProxy
  alias PlaywrightEx.TestServer

  @moduletag :page

  # it.skip(({ mode }) => mode !== 'default');  -- we always run the default mode

  # const __testHookLookup = ...: a Node function that only the in-process client can pass. As
  # playwright-python does, the tests whose requests pass it use a context whose proxy resolves
  # the host names with this function (see TestProxy.set_lookup/2): `lookup_context/1`.
  defp test_hook_lookup(hostname) do
    if hostname == "localhost" or String.ends_with?(hostname, "playwright.dev"),
      do: "127.0.0.1",
      else: raise("Failed to resolve hostname: #{hostname}")
  end

  defp lookup_context(context_factory) do
    %{proxy_server: lookup_proxy} = TestProxy.proxy_server(%{})
    TestProxy.set_lookup(lookup_proxy, &test_hook_lookup/1)
    context_factory.(proxy: %{server: lookup_proxy.url})
  end

  # tests/config/errors.ts
  @k_target_closed_error_message "Target page, context or browser has been closed"

  # --- Node server tricks on Bandit --------------------------------------------

  # `req.socket` / `res.socket`: the connection's socket, owned by the handler process.
  defp raw_socket(%Plug.Conn{adapter: {Bandit.Adapter, adapter}}), do: adapter.transport.socket

  defp socket_write(conn, data), do: :ok = ThousandIsland.Socket.send(raw_socket(conn), data)

  # `req.socket.destroy()`: the handler dies with its socket, no response is sent.
  defp destroy_socket(conn) do
    ThousandIsland.Socket.close(raw_socket(conn))
    Process.exit(self(), :kill)
  end

  # Keeps the response open (upstream: no `res.end()`) until the client closes the connection.
  defp wait_for_close(conn, timeout \\ 10_000) do
    ThousandIsland.Socket.recv(raw_socket(conn), 0, timeout)
    destroy_socket(conn)
  end

  defp raw_head(status_line, headers),
    do: [
      "HTTP/1.1 ",
      status_line,
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]

  # zlib.brotliCompress: no brotli encoder in Erlang/OTP, so an uncompressed meta-block
  # (window 22 bits, what Node emits for short input), then an empty last meta-block.
  defp brotli_compress(data) when byte_size(data) in 1..65_536 do
    header = 0b1011 ||| (byte_size(data) - 1) <<< 7 ||| 1 <<< 23
    <<header::little-24, data::binary, 0x03>>
  end

  defp set_cookies(conn, cookies), do: Plug.Conn.prepend_resp_headers(conn, Enum.map(cookies, &{"set-cookie", &1}))

  defp request_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  defp sorted_cookie_pairs(cookie), do: cookie |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.sort()

  # `new URLSearchParams(query).getAll(name)`
  defp get_all(query, name), do: for({^name, value} <- URI.query_decoder(query || ""), do: value)

  defp windows?, do: match?({:win32, _}, :os.type())
  defp linux?, do: match?({:unix, :linux}, :os.type())

  # formidable: a minimal multipart/form-data parser on the request body, parts in order.
  defp parse_multipart(conn) do
    {:ok, "multipart", "form-data", %{"boundary" => boundary}} =
      conn |> request_header("content-type") |> Plug.Conn.Utils.content_type()

    conn.assigns.post_body
    |> :binary.split("--" <> boundary, [:global])
    |> Enum.slice(1..-2//1)
    |> Enum.map(fn "\r\n" <> part ->
      [head, body] = :binary.split(part, "\r\n\r\n")

      headers =
        for line <- String.split(head, "\r\n"), into: %{} do
          [name, value] = String.split(line, ":", parts: 2)
          {String.downcase(name), String.trim(value)}
        end

      "form-data" <> disposition = headers["content-disposition"]
      params = Plug.Conn.Utils.params(disposition)

      %{
        name: params["name"],
        filename: params["filename"],
        mimetype: headers["content-type"],
        body: binary_part(body, 0, byte_size(body) - 2)
      }
    end)
  end

  defp fields(parts), do: for(%{filename: nil} = part <- parts, do: {part.name, part.body})
  defp files(parts), do: for(%{filename: filename} = part <- parts, filename != nil, into: %{}, do: {part.name, part})

  # ------------------------------------------------------------------------------

  test "get should work @smoke", %{context: context, server: server} do
    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/simple.json")
    assert APIResponse.url(response) == server.prefix <> "/simple.json"
    assert APIResponse.status(response) == 200
    assert APIResponse.status_text(response) == "OK"
    assert APIResponse.ok(response)
    assert APIResponse.headers(response)["content-type"] == "application/json; charset=utf-8"
    # Plug sends lowercase header names (upstream: `Content-Type`).
    assert %{name: "content-type", value: "application/json; charset=utf-8"} in APIResponse.headers_array(response)
    assert APIResponse.text!(response) == ~s({"foo": "bar"}\n)
  end

  test "fetch should work", %{context: context, server: server} do
    response = APIRequestContext.fetch!(BrowserContext.request(context), server.prefix <> "/simple.json")
    assert APIResponse.url(response) == server.prefix <> "/simple.json"
    assert APIResponse.status(response) == 200
    assert APIResponse.status_text(response) == "OK"
    assert APIResponse.ok(response)
    assert APIResponse.headers(response)["content-type"] == "application/json; charset=utf-8"
    # Plug sends lowercase header names (upstream: `Content-Type`).
    assert %{name: "content-type", value: "application/json; charset=utf-8"} in APIResponse.headers_array(response)
    assert APIResponse.text!(response) == ~s({"foo": "bar"}\n)
  end

  test "should return timing", %{context: context, asset: asset} do
    # Create a fresh server to guarantee a new connection, because keep-alive
    # sockets from other tests do not have dns/connect timings.
    http_server = TestServer.server(start_supervised!({TestServer, dir_path: asset.("")}, id: :fresh_server))
    TestServer.set_route(http_server, "/", &Plug.Conn.send_resp(&1, 200, "Hello"))
    response = APIRequestContext.get!(BrowserContext.request(context), "http://localhost:#{http_server.port}/")
    assert APIResponse.ok(response)
    timing = APIResponse.timing(response)
    assert abs(timing.startTime - System.system_time(:millisecond)) < 5000
    assert timing.domainLookupStart == 0
    assert timing.domainLookupEnd >= timing.domainLookupStart
    assert timing.connectStart == timing.domainLookupEnd
    assert timing.secureConnectionStart == -1
    assert timing.connectEnd >= timing.connectStart
    assert timing.requestStart == timing.connectEnd
    assert timing.responseStart >= timing.requestStart
    assert timing.responseEnd >= timing.responseStart
    assert timing.responseEnd < 60_000
  end

  test "should return timing for https", %{context: context, asset: asset} do
    # Create a fresh server to guarantee a new connection, because keep-alive
    # sockets from other tests do not have dns/connect timings.
    https_server =
      TestServer.server(
        start_supervised!({TestServer, dir_path: asset.(""), ssl_options: TestServer.cert_options()},
          id: :fresh_https_server
        )
      )

    TestServer.set_route(https_server, "/", &Plug.Conn.send_resp(&1, 200, "Hello"))

    response =
      APIRequestContext.get!(BrowserContext.request(context), "https://localhost:#{https_server.port}/",
        ignore_https_errors: true
      )

    assert APIResponse.ok(response)
    timing = APIResponse.timing(response)
    assert abs(timing.startTime - System.system_time(:millisecond)) < 5000
    assert timing.domainLookupStart == 0
    assert timing.domainLookupEnd >= timing.domainLookupStart
    assert timing.connectStart == timing.domainLookupEnd
    assert timing.secureConnectionStart >= timing.connectStart
    assert timing.connectEnd >= timing.secureConnectionStart
    assert timing.requestStart == timing.connectEnd
    assert timing.responseStart >= timing.requestStart
    assert timing.responseEnd >= timing.responseStart
  end

  test "should throw on network error", %{context: context, server: server} do
    TestServer.set_route(server, "/test", &destroy_socket/1)
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/test")
    assert Exception.message(error) =~ "apiRequestContext.get: socket hang up"
  end

  test "should throw on network error after redirect", %{context: context, server: server} do
    TestServer.set_redirect(server, "/redirect", "/test")
    TestServer.set_route(server, "/test", &destroy_socket/1)
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/redirect")
    assert Exception.message(error) =~ "apiRequestContext.get: socket hang up"
  end

  defp send_partial_body_and_destroy(conn) do
    socket_write(conn, raw_head("200 OK", [{"content-length", "4096"}, {"content-type", "text/html"}]))
    socket_write(conn, "<title>A")
    destroy_socket(conn)
  end

  test "should throw on network error when sending body", %{context: context, server: server} do
    TestServer.set_route(server, "/test", &send_partial_body_and_destroy/1)
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/test")
    assert Exception.message(error) =~ "apiRequestContext.get: aborted"
  end

  test "should throw on network error when sending body after redirect", %{context: context, server: server} do
    TestServer.set_redirect(server, "/redirect", "/test")
    TestServer.set_route(server, "/test", &send_partial_body_and_destroy/1)
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/redirect")
    assert Exception.message(error) =~ "apiRequestContext.get: aborted"
  end

  test "should add session cookies to request", %{context_factory: context_factory, server: server} do
    # deviation: lookup_context/1 stands in for { __testHookLookup } on the request below
    context = lookup_context(context_factory)

    BrowserContext.add_cookies!(context, [
      %{
        name: "username",
        value: "John Doe",
        domain: ".my.playwright.dev",
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: false,
        sameSite: "Lax"
      }
    ])

    task = TestServer.wait_for_request(server, "/simple.json")
    APIRequestContext.get!(BrowserContext.request(context), "http://www.my.playwright.dev:#{server.port}/simple.json")
    req = Task.await(task, :infinity)
    assert request_header(req, "cookie") == "username=John Doe"
  end

  test "should filter cookies by domain", %{context_factory: context_factory, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/36069' }
    # deviation: lookup_context/1 stands in for { __testHookLookup } on the request below
    context = lookup_context(context_factory)

    BrowserContext.add_cookies!(context, [
      %{
        name: "first",
        value: "1",
        domain: "playwright.dev",
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: false,
        sameSite: "Lax"
      },
      %{
        name: "second",
        value: "2",
        domain: ".playwright.dev",
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: false,
        sameSite: "Lax"
      }
    ])

    task = TestServer.wait_for_request(server, "/simple.json")
    APIRequestContext.get!(BrowserContext.request(context), "http://my.playwright.dev:#{server.port}/simple.json")
    req = Task.await(task, :infinity)
    assert request_header(req, "cookie") == "second=2"
  end

  for method <- [:fetch, :delete, :get, :head, :patch, :post, :put] do
    @method method

    test "#{method} should support params passed as object", %{context: context, server: server} do
      # Elixir maps have no insertion order: the query follows the map's order, as the request's.
      params = %{"param1" => "value1", "парам2" => "знач2"}
      task = TestServer.wait_for_request(server, "/empty.html?" <> URI.encode_query(params))
      response = request!(@method, BrowserContext.request(context), server.empty_page, params: params)
      request = Task.await(task, :infinity)

      request_params = URI.decode_query(request.query_string)
      assert request_params["param1"] == "value1"
      assert request_params["парам2"] == "знач2"

      response_params = URI.decode_query(URI.parse(APIResponse.url(response)).query)
      assert response_params["param1"] == "value1"
      assert response_params["парам2"] == "знач2"
    end

    test "#{method} should support params passed as URLSearchParams", %{context: context, server: server} do
      # URLSearchParams: a keyword list.
      search_params = [{"param1", "value1"}]
      search_params = search_params ++ [{"param1", "value2"}]
      search_params = search_params ++ [{"парам2", "знач2"}]

      task = TestServer.wait_for_request(server, "/empty.html?" <> URI.encode_query(search_params, :www_form))
      response = request!(@method, BrowserContext.request(context), server.empty_page, params: search_params)
      request = Task.await(task, :infinity)

      assert get_all(request.query_string, "param1") == ["value1", "value2"]
      assert get_all(request.query_string, "парам2") == ["знач2"]

      response_query = URI.parse(APIResponse.url(response)).query
      assert get_all(response_query, "param1") == ["value1", "value2"]
      assert get_all(response_query, "парам2") == ["знач2"]
    end

    test "#{method} should support params passed as string", %{context: context, server: server} do
      params = "?param1=value1&param1=value2&парам2=знач2"
      task = TestServer.wait_for_request(server, "/empty.html" <> URI.encode(params))
      response = request!(@method, BrowserContext.request(context), server.empty_page, params: params)
      request = Task.await(task, :infinity)

      assert get_all(request.query_string, "param1") == ["value1", "value2"]
      assert get_all(request.query_string, "парам2") == ["знач2"]

      response_query = URI.parse(APIResponse.url(response)).query
      assert get_all(response_query, "param1") == ["value1", "value2"]
      assert get_all(response_query, "парам2") == ["знач2"]
    end

    test "#{method} should support failOnStatusCode", %{context: context, server: server} do
      {:error, error} =
        request(@method, BrowserContext.request(context), server.prefix <> "/does-not-exist.html",
          fail_on_status_code: true
        )

      assert Exception.message(error) =~ "404 Not Found"
      if @method != :head, do: assert(Exception.message(error) =~ "Response text:\nFile not found:")
    end

    test "#{method}should support ignoreHTTPSErrors option", %{context: context, https_server: https_server} do
      response = request!(@method, BrowserContext.request(context), https_server.empty_page, ignore_https_errors: true)
      assert APIResponse.status(response) == 200
    end
  end

  # `context.request[method](url, options)`
  defp request(method, request, url, options), do: apply(APIRequestContext, method, [request, url, options])
  defp request!(method, request, url, options), do: apply(APIRequestContext, :"#{method}!", [request, url, options])

  test "should not add context cookie if cookie header passed as a parameter", %{
    context_factory: context_factory,
    server: server
  } do
    # deviation: lookup_context/1 stands in for { __testHookLookup } on the request below
    context = lookup_context(context_factory)

    BrowserContext.add_cookies!(context, [
      %{
        name: "username",
        value: "John Doe",
        domain: ".my.playwright.dev",
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: false,
        sameSite: "Lax"
      }
    ])

    task = TestServer.wait_for_request(server, "/empty.html")

    APIRequestContext.get!(BrowserContext.request(context), "http://www.my.playwright.dev:#{server.port}/empty.html",
      headers: %{"Cookie" => "foo=bar"}
    )

    req = Task.await(task, :infinity)
    assert request_header(req, "cookie") == "foo=bar"
  end

  test "should follow redirects", %{context_factory: context_factory, server: server} do
    # deviation: lookup_context/1 stands in for { __testHookLookup } on the request below
    context = lookup_context(context_factory)
    TestServer.set_redirect(server, "/redirect1", "/redirect2")
    TestServer.set_redirect(server, "/redirect2", "/simple.json")

    BrowserContext.add_cookies!(context, [
      %{
        name: "username",
        value: "John Doe",
        domain: ".my.playwright.dev",
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: false,
        sameSite: "Lax"
      }
    ])

    task = TestServer.wait_for_request(server, "/simple.json")

    response =
      APIRequestContext.get!(BrowserContext.request(context), "http://www.my.playwright.dev:#{server.port}/redirect1")

    req = Task.await(task, :infinity)
    assert request_header(req, "cookie") == "username=John Doe"
    assert APIResponse.url(response) == "http://www.my.playwright.dev:#{server.port}/simple.json"
    assert APIResponse.json!(response) == %{"foo" => "bar"}
  end

  test "should follow redirects correctly when Location header contains UTF-8 characters", %{
    context: context,
    server: server
  } do
    # annotation: https://github.com/microsoft/playwright/issues/30903
    TestServer.set_route(server, "/redirect", fn conn ->
      # Plug only allows US-ASCII, so we can't send invalid headers directly. Sending it as a raw response instead.
      socket_write(
        conn,
        raw_head("301 Moved Permanently", [{"Location", "#{server.prefix}/empty.html?message=マスクПривет"}])
      )

      destroy_socket(conn)
    end)

    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/redirect")
    assert APIResponse.url(response) == server.prefix <> "/empty.html?" <> URI.encode_query(%{message: "マスクПривет"})
  end

  test "should add cookies from Set-Cookie header", %{context: context, page: page, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn |> set_cookies(["session=value", "foo=bar; max-age=3600"]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/setcookie.html")
    cookies = BrowserContext.cookies!(context)

    assert MapSet.new(cookies, &%{name: &1.name, value: &1.value}) ==
             MapSet.new([%{name: "session", value: "value"}, %{name: "foo", value: "bar"}])

    Page.goto!(page, server.empty_page)
    assert sorted_cookie_pairs(Page.evaluate!(page, "() => document.cookie")) == ["foo=bar", "session=value"]
  end

  test "page.request.addCookies should add cookies to the browser context", %{
    context: context,
    page: page,
    server: server
  } do
    APIRequestContext.add_cookies!(Page.request(page), [
      %{name: "a", value: "b", url: server.empty_page},
      %{name: "c", value: "d", domain: "localhost", path: "/", expires: System.system_time(:second) + 3600}
    ])

    assert context
           |> BrowserContext.cookies!()
           |> Enum.map(&%{name: &1.name, value: &1.value})
           |> Enum.sort_by(& &1.name) ==
             [%{name: "a", value: "b"}, %{name: "c", value: "d"}]

    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(BrowserContext.request(context), server.empty_page)
    req = Task.await(task, :infinity)
    assert sorted_cookie_pairs(request_header(req, "cookie")) == ["a=b", "c=d"]
    Page.goto!(page, server.empty_page)
    assert sorted_cookie_pairs(Page.evaluate!(page, "() => document.cookie")) == ["a=b", "c=d"]
  end

  test "page.request.cookies should return browser context cookies", %{context: context, page: page, server: server} do
    BrowserContext.add_cookies!(context, [
      %{name: "a", value: "b", url: server.empty_page},
      %{name: "c", value: "d", domain: "example.com", path: "/"}
    ])

    assert page |> Page.request() |> APIRequestContext.cookies!() |> Enum.map(& &1.name) |> Enum.sort() == ["a", "c"]
    assert page |> Page.request() |> APIRequestContext.cookies!(server.empty_page) |> Enum.map(& &1.name) == ["a"]

    assert APIRequestContext.cookies!(Page.request(page), server.empty_page) ==
             BrowserContext.cookies!(context, server.empty_page)
  end

  test "page.request.clearCookies should clear browser context cookies", %{context: context, page: page, server: server} do
    BrowserContext.add_cookies!(context, [
      %{name: "a", value: "b", url: server.empty_page},
      %{name: "c", value: "d", url: server.empty_page}
    ])

    APIRequestContext.clear_cookies!(Page.request(page), name: "a")
    assert Enum.map(BrowserContext.cookies!(context), & &1.name) == ["c"]
    APIRequestContext.clear_cookies!(Page.request(page))
    assert BrowserContext.cookies!(context) == []
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(Page.request(page), server.empty_page)
    req = Task.await(task, :infinity)
    assert request_header(req, "cookie") == nil
  end

  test "should preserve cookie order from Set-Cookie header", %{context: context, page: page, server: server} do
    # annotation: https://github.com/microsoft/playwright/issues/23390
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn |> set_cookies(["cookie.0=foo", "cookie.1=bar"]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(Page.request(page), server.prefix <> "/setcookie.html")
    cookies = BrowserContext.cookies!(context)

    assert Enum.map(cookies, &%{name: &1.name, value: &1.value}) == [
             %{name: "cookie.0", value: "foo"},
             %{name: "cookie.1", value: "bar"}
           ]

    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => document.cookie") == "cookie.0=foo; cookie.1=bar"
    request_promise = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(Page.request(page), server.empty_page)
    request = Task.await(request_promise, :infinity)
    assert request_header(request, "cookie") == "cookie.0=foo; cookie.1=bar"
  end

  test "should support cookie with empty value", %{context: context, page: page, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn |> set_cookies(["first="]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/setcookie.html")
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => document.cookie") == "first="
    cookies = BrowserContext.cookies!(context)
    assert Enum.map(cookies, &%{name: &1.name, value: &1.value}) == [%{name: "first", value: ""}]
  end

  test "should not lose body while handling Set-Cookie header", %{context: context, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn |> set_cookies(["session=value", "foo=bar; max-age=3600"]) |> Plug.Conn.send_resp(200, "text content")
    end)

    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/setcookie.html")
    assert APIResponse.text!(response) == "text content"
  end

  test "should remove cookie with negative max-age", %{page: page, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn |> set_cookies(["a=v; max-age=100000", "b=v; max-age=100000", "c=v"]) |> Plug.Conn.send_resp(200, "")
    end)

    TestServer.set_route(server, "/removecookie.html", fn conn ->
      max_age = -2 * System.system_time(:millisecond)
      conn |> set_cookies(["a=v; max-age=#{max_age}", "b=v; max-age=-1"]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(Page.request(page), "#{server.prefix}/setcookie.html")
    APIRequestContext.get!(Page.request(page), "#{server.prefix}/removecookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(Page.request(page), server.empty_page)
    server_request = Task.await(task, :infinity)
    assert request_header(server_request, "cookie") == "c=v"
  end

  test "should remove cookie with expires far in the past", %{page: page, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn |> set_cookies(["a=v; max-age=1000000"]) |> Plug.Conn.send_resp(200, "")
    end)

    TestServer.set_route(server, "/removecookie.html", fn conn ->
      conn |> set_cookies(["a=v; expires=Wed, 01 Jan 1000 00:00:00 GMT"]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(Page.request(page), "#{server.prefix}/setcookie.html")
    APIRequestContext.get!(Page.request(page), "#{server.prefix}/removecookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(Page.request(page), server.empty_page)
    server_request = Task.await(task, :infinity)
    refute request_header(server_request, "cookie")
  end

  test "should handle cookies on redirects", %{context: context, server: server, browser_name: browser_name} do
    TestServer.set_route(server, "/redirect1", fn conn ->
      conn
      |> set_cookies(["r1=v1;SameSite=Lax"])
      |> Plug.Conn.put_resp_header("location", "/a/b/redirect2")
      |> Plug.Conn.send_resp(301, "")
    end)

    TestServer.set_route(server, "/a/b/redirect2", fn conn ->
      conn
      |> set_cookies(["r2=v2;SameSite=Lax"])
      |> Plug.Conn.put_resp_header("location", "/title.html")
      |> Plug.Conn.send_resp(302, "")
    end)

    wait_for_redirects = fn ->
      tasks = for path <- ["/redirect1", "/a/b/redirect2", "/title.html"], do: TestServer.wait_for_request(server, path)
      APIRequestContext.get!(BrowserContext.request(context), "#{server.prefix}/redirect1")
      Task.await_many(tasks, :infinity)
    end

    [req1, req2, req3] = wait_for_redirects.()
    refute request_header(req1, "cookie")
    assert request_header(req2, "cookie") == "r1=v1"
    assert request_header(req3, "cookie") == "r1=v1"

    [req1, req2, req3] = wait_for_redirects.()
    assert request_header(req1, "cookie") == "r1=v1"
    assert sorted_cookie_pairs(request_header(req2, "cookie")) == ["r1=v1", "r2=v2"]
    assert request_header(req3, "cookie") == "r1=v1"

    cookies = BrowserContext.cookies!(context)
    # channel !== 'webkit-wsl': we run no channel
    same_site = if browser_name == "webkit" and windows?(), do: "None", else: "Lax"

    assert MapSet.new(cookies) ==
             MapSet.new([
               %{
                 sameSite: same_site,
                 name: "r2",
                 value: "v2",
                 domain: server.hostname,
                 path: "/a/b",
                 expires: -1,
                 httpOnly: false,
                 secure: false
               },
               %{
                 sameSite: same_site,
                 name: "r1",
                 value: "v1",
                 domain: server.hostname,
                 path: "/",
                 expires: -1,
                 httpOnly: false,
                 secure: false
               }
             ])
  end

  test "should return raw headers", %{context: context, server: server} do
    TestServer.set_route(server, "/headers", fn conn ->
      # Plug lowercases header names, so we write directly to the socket.
      socket_write(
        conn,
        raw_head("200 OK", [{"Name-A", "v1"}, {"name-b", "v4"}, {"Name-a", "v2"}, {"name-A", "v3"}])
      )

      destroy_socket(conn)
    end)

    response = APIRequestContext.get!(BrowserContext.request(context), "#{server.prefix}/headers")
    assert APIResponse.status(response) == 200

    headers =
      Enum.filter(APIResponse.headers_array(response), &String.contains?(String.downcase(&1.name), "name-"))

    assert headers == [
             %{name: "Name-A", value: "v1"},
             %{name: "name-b", value: "v4"},
             %{name: "Name-a", value: "v2"},
             %{name: "name-A", value: "v3"}
           ]

    # Comma separated values, this matches Response.headers()
    assert APIResponse.headers(response)["name-a"] == "v1, v2, v3"
    assert APIResponse.headers(response)["name-b"] == "v4"
  end

  test "should work with http credentials", %{context: context, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    task = TestServer.wait_for_request(server, "/empty.html")

    response =
      APIRequestContext.get!(BrowserContext.request(context), server.empty_page,
        headers: %{"authorization" => "Basic " <> Base.encode64("user:pass")}
      )

    request = Task.await(task, :infinity)
    assert APIResponse.status(response) == 200
    assert request.request_path == "/empty.html"
  end

  test "should work with setHTTPCredentials", %{context: context, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    response1 = APIRequestContext.get!(BrowserContext.request(context), server.empty_page)
    assert APIResponse.status(response1) == 401

    BrowserContext.set_http_credentials!(context, %{username: "user", password: "pass"})
    response2 = APIRequestContext.get!(BrowserContext.request(context), server.empty_page)
    assert APIResponse.status(response2) == 200
  end

  test "should return error with wrong credentials", %{context: context, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    BrowserContext.set_http_credentials!(context, %{username: "user", password: "wrong"})
    response2 = APIRequestContext.get!(BrowserContext.request(context), server.empty_page)
    assert APIResponse.status(response2) == 401
  end

  test "should support multiple httpCredentials", %{context_factory: context_factory, server: server} do
    TestServer.set_auth(server, "/empty.html", "user1", "pass1")

    context =
      context_factory.(
        http_credentials: [
          %{username: "user1", password: "pass1", origin: server.prefix},
          %{username: "user2", password: "pass2", origin: server.cross_process_prefix}
        ]
      )

    response1 = APIRequestContext.get!(BrowserContext.request(context), server.empty_page)
    assert APIResponse.status(response1) == 200
    # Wrong credentials are picked for the other origin.
    response2 = APIRequestContext.get!(BrowserContext.request(context), server.cross_process_prefix <> "/empty.html")
    assert APIResponse.status(response2) == 401
  end

  test "should support HTTPCredentials.send for newContext", %{context_factory: context_factory, server: server} do
    # annotation: https://github.com/microsoft/playwright/issues/30534
    context =
      context_factory.(
        http_credentials: %{username: "user", password: "pass", origin: String.upcase(server.prefix), send: "always"}
      )

    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(BrowserContext.request(context), server.empty_page)
    server_request = Task.await(task, :infinity)
    assert request_header(server_request, "authorization") == "Basic " <> Base.encode64("user:pass")
    assert APIResponse.status(response) == 200

    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(BrowserContext.request(context), server.cross_process_prefix <> "/empty.html")
    server_request = Task.await(task, :infinity)
    # Not sent to another origin.
    assert request_header(server_request, "authorization") == nil
    assert APIResponse.status(response) == 200
  end

  test "should support HTTPCredentials.send for browser.newPage", %{server: server, browser: browser} do
    # annotation: https://github.com/microsoft/playwright/issues/30534
    page =
      Browser.new_page!(browser,
        http_credentials: %{username: "user", password: "pass", origin: String.upcase(server.prefix), send: "always"}
      )

    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(Page.request(page), server.empty_page)
    server_request = Task.await(task, :infinity)
    assert request_header(server_request, "authorization") == "Basic " <> Base.encode64("user:pass")
    assert APIResponse.status(response) == 200

    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(Page.request(page), server.cross_process_prefix <> "/empty.html")
    server_request = Task.await(task, :infinity)
    # Not sent to another origin.
    assert request_header(server_request, "authorization") == nil
    assert APIResponse.status(response) == 200
    Page.close!(page)
  end

  defp assert_post_data(method, http_method, context, server) do
    task = TestServer.wait_for_request(server, "/simple.json")
    response = request!(method, BrowserContext.request(context), "#{server.prefix}/simple.json", data: "My request")
    request = Task.await(task, :infinity)
    assert request.method == http_method
    assert request.assigns.post_body == "My request"
    assert APIResponse.status(response) == 200
    assert request.request_path == "/simple.json"
  end

  test "delete should support post data", %{context: context, server: server} do
    assert_post_data(:delete, "DELETE", context, server)
  end

  test "get should support post data", %{context: context, server: server} do
    assert_post_data(:get, "GET", context, server)
  end

  test "head should support post data", %{context: context, server: server} do
    assert_post_data(:head, "HEAD", context, server)
  end

  test "patch should support post data", %{context: context, server: server} do
    assert_post_data(:patch, "PATCH", context, server)
  end

  test "post should support post data", %{context: context, server: server} do
    assert_post_data(:post, "POST", context, server)
  end

  test "put should support post data", %{context: context, server: server} do
    assert_post_data(:put, "PUT", context, server)
  end

  test "should add default headers", %{context: context, server: server, page: page} do
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(BrowserContext.request(context), server.empty_page)
    request = Task.await(task, :infinity)
    assert request_header(request, "accept") == "*/*"
    user_agent = Page.evaluate!(page, "() => navigator.userAgent")
    assert request_header(request, "user-agent") == user_agent
    assert request_header(request, "accept-encoding") == "gzip,deflate,br"
  end

  test "should send content-length", %{context: context, server: server} do
    bytes = :binary.list_to_bin(Enum.to_list(0..255))
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.post!(BrowserContext.request(context), server.empty_page, data: {:binary, bytes})
    request = Task.await(task, :infinity)
    assert request_header(request, "content-length") == "256"
    assert request_header(request, "content-type") == "application/octet-stream"
  end

  test "should add default headers to redirects", %{context: context, server: server, page: page} do
    TestServer.set_redirect(server, "/redirect", "/empty.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(BrowserContext.request(context), "#{server.prefix}/redirect")
    request = Task.await(task, :infinity)
    assert request_header(request, "accept") == "*/*"
    user_agent = Page.evaluate!(page, "() => navigator.userAgent")
    assert request_header(request, "user-agent") == user_agent
    assert request_header(request, "accept-encoding") == "gzip,deflate,br"
  end

  test "should allow to override default headers", %{context: context, server: server} do
    task = TestServer.wait_for_request(server, "/empty.html")

    APIRequestContext.get!(BrowserContext.request(context), server.empty_page,
      headers: %{"User-Agent" => "Playwright", "Accept" => "text/html", "Accept-Encoding" => "br"}
    )

    request = Task.await(task, :infinity)
    assert request_header(request, "accept") == "text/html"
    assert request_header(request, "user-agent") == "Playwright"
    assert request_header(request, "accept-encoding") == "br"
  end

  test "should propagate custom headers with redirects", %{context: context, server: server} do
    TestServer.set_redirect(server, "/a/redirect1", "/b/c/redirect2")
    TestServer.set_redirect(server, "/b/c/redirect2", "/simple.json")

    tasks =
      for path <- ["/a/redirect1", "/b/c/redirect2", "/simple.json"], do: TestServer.wait_for_request(server, path)

    APIRequestContext.get!(BrowserContext.request(context), "#{server.prefix}/a/redirect1", headers: %{"foo" => "bar"})
    [req1, req2, req3] = Task.await_many(tasks, :infinity)
    assert request_header(req1, "foo") == "bar"
    assert request_header(req2, "foo") == "bar"
    assert request_header(req3, "foo") == "bar"
  end

  test "should propagate extra http headers with redirects", %{context: context, server: server} do
    TestServer.set_redirect(server, "/a/redirect1", "/b/c/redirect2")
    TestServer.set_redirect(server, "/b/c/redirect2", "/simple.json")
    BrowserContext.set_extra_http_headers!(context, %{"My-Secret" => "Value"})

    tasks =
      for path <- ["/a/redirect1", "/b/c/redirect2", "/simple.json"], do: TestServer.wait_for_request(server, path)

    APIRequestContext.get!(BrowserContext.request(context), "#{server.prefix}/a/redirect1")
    [req1, req2, req3] = Task.await_many(tasks, :infinity)
    assert request_header(req1, "my-secret") == "Value"
    assert request_header(req2, "my-secret") == "Value"
    assert request_header(req3, "my-secret") == "Value"
  end

  test "should throw on invalid header value", %{context: context, server: server} do
    {:error, error} =
      APIRequestContext.get(BrowserContext.request(context), "#{server.prefix}/a/redirect1",
        headers: %{"foo" => "недопустимое значение"}
      )

    assert Exception.message(error) =~ "Invalid character in header content"
  end

  test "should throw on non-http(s) protocol", %{context: context} do
    {:error, error1} = APIRequestContext.get(BrowserContext.request(context), "data:text/plain,test")
    assert Exception.message(error1) =~ ~s(Protocol "data:" not supported)
    {:error, error2} = APIRequestContext.get(BrowserContext.request(context), "file:///tmp/foo")
    assert Exception.message(error2) =~ ~s(Protocol "file:" not supported)
  end

  test "should support https", %{https_server: https_server, browser_name: browser_name} do
    # process.env['NODE_TLS_REJECT_UNAUTHORIZED'] = '0': the driver is another process, so a
    # driver of its own started with it; NODE_NO_WARNINGS for suppressCertificateWarning()
    playwright =
      start_playwright(:fetch_tls_reject_unauthorized, [
        {"NODE_TLS_REJECT_UNAUTHORIZED", "0"},
        {"NODE_NO_WARNINGS", "1"}
      ])

    browser_type =
      case browser_name do
        "chromium" -> Playwright.chromium(playwright)
        "firefox" -> Playwright.firefox(playwright)
        "webkit" -> Playwright.webkit(playwright)
      end

    browser = BrowserType.launch!(browser_type)
    context = Browser.new_context!(browser)
    response = APIRequestContext.get!(BrowserContext.request(context), https_server.empty_page)
    assert APIResponse.status(response) == 200
    Browser.close!(browser)
  end

  test "should inherit ignoreHTTPSErrors from context", %{context_factory: context_factory, https_server: https_server} do
    # contextOptions is empty here
    context = context_factory.(ignore_https_errors: true)
    response = APIRequestContext.get!(BrowserContext.request(context), https_server.empty_page)
    assert APIResponse.status(response) == 200
  end

  test "should resolve url relative to baseURL", %{server: server, context_factory: context_factory} do
    context = context_factory.(base_url: server.prefix)
    response = APIRequestContext.get!(BrowserContext.request(context), "/empty.html")
    assert APIResponse.url(response) == server.empty_page
  end

  # writeHead, then the encoder piped into res: chunked, no content-length.
  defp send_encoded(conn, encoding, body) do
    {:ok, conn} =
      conn
      |> Plug.Conn.put_resp_header("content-encoding", encoding)
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_chunked(200)
      |> Plug.Conn.chunk(body)

    conn
  end

  test "should support gzip compression", %{context: context, server: server} do
    TestServer.set_route(server, "/compressed", &send_encoded(&1, "gzip", :zlib.gzip("Hello, world!")))
    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed")
    assert APIResponse.text!(response) == "Hello, world!"
  end

  test "should support case-insensitive content-encoding", %{context: context, server: server} do
    TestServer.set_route(server, "/compressed-uppercase", &send_encoded(&1, "GZIP", :zlib.gzip("Hello, world!")))
    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed-uppercase")
    assert APIResponse.text!(response) == "Hello, world!"
  end

  test "should throw informative error on corrupted gzip body", %{context: context, server: server} do
    TestServer.set_route(server, "/corrupted", &send_encoded(&1, "gzip", "Hello, world!"))
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/corrupted")
    assert Exception.message(error) =~ "failed to decompress 'gzip' encoding"
  end

  test "should support brotli compression", %{context: context, server: server} do
    TestServer.set_route(server, "/compressed", &send_encoded(&1, "br", brotli_compress("Hello, world!")))
    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed")
    assert APIResponse.text!(response) == "Hello, world!"
  end

  test "should throw informative error on corrupted brotli body", %{context: context, server: server} do
    TestServer.set_route(server, "/corrupted", &send_encoded(&1, "br", "Hello, world!"))
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/corrupted")
    assert Exception.message(error) =~ "failed to decompress 'br' encoding"
  end

  test "should support deflate compression", %{context: context, server: server} do
    # zlib.createDeflate is the zlib format.
    TestServer.set_route(server, "/compressed", &send_encoded(&1, "deflate", :zlib.compress("Hello, world!")))
    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed")
    assert APIResponse.text!(response) == "Hello, world!"
  end

  test "should throw informative error on corrupted deflate body", %{context: context, server: server} do
    TestServer.set_route(server, "/corrupted", &send_encoded(&1, "deflate", "Hello, world!"))
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/corrupted")
    assert Exception.message(error) =~ "failed to decompress 'deflate' encoding"
  end

  defp send_head_and_hang(conn) do
    socket_write(conn, raw_head("200 OK", [{"content-length", "4096"}, {"content-type", "text/html"}]))
    wait_for_close(conn)
  end

  test "should support timeout option", %{context: context, server: server} do
    TestServer.set_route(server, "/slow", &send_head_and_hang/1)
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/slow", timeout: 10)
    assert Exception.message(error) =~ "apiRequestContext.get: Timeout 10ms exceeded"
  end

  test "should support a timeout of 0", %{context: context, server: server} do
    TestServer.set_route(server, "/slow", fn conn ->
      socket_write(conn, raw_head("200 OK", [{"content-length", "4"}, {"content-type", "text/html"}]))
      Process.sleep(50)
      socket_write(conn, "done")
      wait_for_close(conn)
    end)

    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/slow", timeout: 0)
    assert APIResponse.text!(response) == "done"
  end

  test "should respect timeout after redirects", %{context: context, server: server} do
    TestServer.set_redirect(server, "/redirect", "/slow")
    TestServer.set_route(server, "/slow", &send_head_and_hang/1)

    BrowserContext.set_default_timeout(context, 100)
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/redirect")
    assert Exception.message(error) =~ "apiRequestContext.get: Timeout 100ms exceeded"
  end

  test "should not hang on a brotli encoded Range request", %{context: context, server: server} do
    # annotation: https://github.com/microsoft/playwright/issues/18190
    # it.skip(nodeVersion.major < 18)  -- the driver's Node is recent
    encoded_request_payload = brotli_compress("A")

    TestServer.set_route(server, "/brotli", fn conn ->
      socket_write(
        conn,
        raw_head("206 Partial Content", [
          {"Content-Type", "text/plain"},
          {"content-length", "1"},
          {"Content-Encoding", "br"},
          {"content-range", "bytes 0-2/#{byte_size(encoded_request_payload)}"},
          {"Accept-Ranges", "bytes"}
        ])
      )

      socket_write(conn, binary_part(encoded_request_payload, 0, 2))
      wait_for_close(conn)
    end)

    {:error, error} =
      APIRequestContext.get(BrowserContext.request(context), server.prefix <> "/brotli",
        headers: %{"range" => "bytes=0-2"}
      )

    assert Exception.message(error) =~ ~r/Parse Error: Expected HTTP\//
  end

  test "should dispose", %{context: context, server: server} do
    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/simple.json")
    assert APIResponse.json!(response) == %{"foo" => "bar"}
    APIResponse.dispose!(response)
    {:error, error} = APIResponse.body(response)
    assert Exception.message(error) =~ "Response has been disposed"
  end

  test "should dispose when context closes", %{context: context, server: server} do
    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/simple.json")
    assert APIResponse.json!(response) == %{"foo" => "bar"}
    BrowserContext.close!(context)
    {:error, error} = APIResponse.body(response)
    assert Exception.message(error) =~ "Response has been disposed"
  end

  test "should override request parameters", %{context: context, page: page, server: server} do
    page_req = Page.expect_request!(page, "**/*", fn -> Page.goto!(page, server.empty_page) end)
    task = TestServer.wait_for_request(server, "/empty.html")

    APIRequestContext.fetch!(BrowserContext.request(context), page_req,
      method: "POST",
      headers: %{"foo" => "bar"},
      data: "data"
    )

    req = Task.await(task, :infinity)
    assert req.method == "POST"
    assert request_header(req, "foo") == "bar"
    assert req.assigns.post_body == "data"
  end

  test "should support application/x-www-form-urlencoded", %{context: context, server: server} do
    task = TestServer.wait_for_request(server, "/empty.html")

    APIRequestContext.post!(BrowserContext.request(context), server.empty_page,
      form: %{"firstName" => "John", "lastName" => "Doe", "file" => "f.js"}
    )

    req = Task.await(task, :infinity)
    assert req.method == "POST"
    assert request_header(req, "content-type") == "application/x-www-form-urlencoded"
    body = req.assigns.post_body
    params = URI.decode_query(body)
    assert request_header(req, "content-length") == to_string(byte_size(URI.encode_query(params)))
    assert params["firstName"] == "John"
    assert params["lastName"] == "Doe"
    assert params["file"] == "f.js"
  end

  test "should support application/x-www-form-urlencoded with param lists", %{context: context, server: server} do
    # FormData: a keyword list.
    form = [foo: "1"]
    form = form ++ [foo: "2"]
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.post!(BrowserContext.request(context), server.empty_page, form: form)
    req = Task.await(task, :infinity)
    assert req.method == "POST"
    assert request_header(req, "content-type") == "application/x-www-form-urlencoded"
    body = req.assigns.post_body
    assert request_header(req, "content-length") == to_string(byte_size(body))
    assert get_all(body, "foo") == ["1", "2"]
  end

  test "should encode to application/json by default", %{context: context, server: server} do
    data = %{"firstName" => "John", "lastName" => "Doe", "file" => %{"name" => "f.js"}}
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.post!(BrowserContext.request(context), server.empty_page, data: data)
    req = Task.await(task, :infinity)
    assert req.method == "POST"
    assert request_header(req, "content-type") == "application/json"
    body = req.assigns.post_body
    json = JSON.decode!(body)
    assert json == data
  end

  test "should support multipart/form-data", %{context: context, server: server} do
    form_received = TestServer.wait_for_request(server, "/empty.html")
    file = %{name: "f.js", mimeType: "text/javascript", buffer: "var x = 10;\r\n;console.log(x);"}

    response =
      APIRequestContext.post!(BrowserContext.request(context), server.empty_page,
        multipart: %{"firstName" => "John", "middleName" => "", "lastName" => "Doe", "file" => file}
      )

    server_request = Task.await(form_received, :infinity)
    parts = parse_multipart(server_request)
    fields = Map.new(fields(parts))
    files = files(parts)
    assert server_request.method == "POST"
    assert request_header(server_request, "content-type") =~ "multipart/form-data"
    assert fields["firstName"] == "John"
    assert fields["middleName"] == ""
    assert fields["lastName"] == "Doe"
    assert files["file"].filename == file.name
    assert files["file"].mimetype == file.mimeType
    assert files["file"].body == file.buffer
    assert APIResponse.status(response) == 200
  end

  test "should support multipart/form-data with ReadStream values", %{context: context, asset: asset, server: server} do
    form_received = TestServer.wait_for_request(server, "/empty.html")
    read_stream = File.stream!(asset.("simplezip.json"))

    response =
      APIRequestContext.post!(BrowserContext.request(context), server.empty_page,
        multipart: %{"firstName" => "John", "lastName" => "Doe", "readStream" => read_stream}
      )

    server_request = Task.await(form_received, :infinity)
    parts = parse_multipart(server_request)
    fields = Map.new(fields(parts))
    files = files(parts)
    assert server_request.method == "POST"
    assert request_header(server_request, "content-type") =~ "multipart/form-data"
    assert request_header(server_request, "content-length") =~ "5498"
    assert fields["firstName"] == "John"
    assert fields["lastName"] == "Doe"
    assert files["readStream"].filename == "simplezip.json"
    assert files["readStream"].mimetype == "application/json"
    assert files["readStream"].body == File.read!(asset.("simplezip.json"))
    assert APIResponse.status(response) == 200
  end

  test "should support multipart/form-data and keep the order", %{context: context, server: server} do
    # A keyword list: Elixir maps have no insertion order.
    given = [firstName: "John", lastName: "Doe", age: 27]
    given = given ++ [foo: "bar"]
    given_keys = Enum.map(Keyword.keys(given), &Atom.to_string/1)
    form_received = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.post!(BrowserContext.request(context), server.empty_page, multipart: given)
    fields = fields(parse_multipart(Task.await(form_received, :infinity)))
    actual_keys = Enum.map(fields, &elem(&1, 0))
    assert actual_keys == given_keys
    assert APIResponse.status(response) == 200
  end

  test "should support repeating names in multipart/form-data", %{context: context, server: server} do
    test_pid = self()

    TestServer.set_route(server, "/empty.html", fn req ->
      send(test_pid, {:post_body, req.assigns.post_body})

      req
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(200, "OK.")
    end)

    # FormData: a keyword list; File and Blob: FilePayload maps (a Blob's default name is "blob").
    form_data = [name: "John"]
    form_data = form_data ++ [name: "Doe"]

    form_data =
      form_data ++ [file: %{name: "f1.js", mimeType: "text/javascript", buffer: "var x = 10;\r\n;console.log(x);"}]

    form_data = form_data ++ [file: %{name: "custom_f2.txt", mimeType: "text/plain", buffer: "hello"}]
    form_data = form_data ++ [file: %{name: "blob", mimeType: "text/plain", buffer: "boo"}]

    response = APIRequestContext.post!(BrowserContext.request(context), server.empty_page, multipart: form_data)
    assert_received {:post_body, post_body}

    assert post_body =~ ~s{content-disposition: form-data; name="name"\r\n\r\nJohn}
    assert post_body =~ ~s{content-disposition: form-data; name="name"\r\n\r\nDoe}

    assert post_body =~
             ~s{content-disposition: form-data; name="file"; filename="f1.js"\r\ncontent-type: text/javascript\r\n\r\nvar x = 10;\r\n;console.log(x);}

    assert post_body =~
             ~s{content-disposition: form-data; name="file"; filename="custom_f2.txt"\r\ncontent-type: text/plain\r\n\r\nhello}

    assert post_body =~
             ~s{content-disposition: form-data; name="file"; filename="blob"\r\ncontent-type: text/plain\r\n\r\nboo}

    assert APIResponse.status(response) == 200
  end

  test "should serialize data to json regardless of content-type", %{context: context, server: server} do
    data = %{"firstName" => "John", "lastName" => "Doe"}
    task = TestServer.wait_for_request(server, "/empty.html")

    APIRequestContext.post!(BrowserContext.request(context), server.empty_page,
      headers: %{"content-type" => "unknown"},
      data: data
    )

    req = Task.await(task, :infinity)
    assert req.method == "POST"
    assert request_header(req, "content-type") == "unknown"
    body = req.assigns.post_body
    assert body == JSON.encode!(data)
  end

  test "should throw nice error on unsupported data type", %{context: context, server: server} do
    {:error, error} =
      APIRequestContext.post(BrowserContext.request(context), server.empty_page,
        headers: %{"content-type" => "application/json"},
        data: fn -> true end
      )

    assert Exception.message(error) =~ "Unexpected 'data' type"
  end

  test "context request should export same storage state as context", %{context: context, page: page, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn |> set_cookies(["a=b", "c=d"]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/setcookie.html")
    context_state = BrowserContext.storage_state!(context)
    assert length(context_state.cookies) == 2
    request_state = APIRequestContext.storage_state!(BrowserContext.request(context))
    assert request_state == context_state
    page_state = APIRequestContext.storage_state!(Page.request(page))
    assert page_state == context_state
  end

  test "should send secure cookie over http for localhost", %{page: page, server: server} do
    # it.skip(channel === 'webkit-wsl')  -- we run no channel
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn |> set_cookies(["a=v; secure"]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(Page.request(page), "#{server.prefix}/setcookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(Page.request(page), server.empty_page)
    server_request = Task.await(task, :infinity)
    assert request_header(server_request, "cookie") == "a=v"
  end

  test "should accept bool and numeric params and filter out undefined", %{page: page, server: server} do
    test_pid = self()
    # Elixir maps have no insertion order: the query follows the map's order, as the request's.
    search = URI.encode_query(%{"str" => "s", "num" => "10", "bool" => "true", "bool2" => "false"})

    TestServer.set_route(server, "/empty.html?" <> search, fn req ->
      send(test_pid, {:request, req})
      TestServer.serve_file(server, req)
    end)

    APIRequestContext.get!(Page.request(page), server.empty_page,
      params: %{"str" => "s", "num" => 10, "bool" => true, "bool2" => false, "none" => nil}
    )

    assert_received {:request, request}
    params = URI.decode_query(request.query_string)
    assert params["str"] == "s"
    assert params["num"] == "10"
    assert params["bool"] == "true"
    assert params["bool2"] == "false"
    refute Map.has_key?(params, "none")
  end

  test "should abort requests when browser context closes", %{context_factory: context_factory, server: server} do
    test_pid = self()

    TestServer.set_route(server, "/empty.html", fn conn ->
      # req.socket.on('close', resolve)
      ThousandIsland.Socket.recv(raw_socket(conn), 0, 30_000)
      send(test_pid, :connection_closed)
      destroy_socket(conn)
    end)

    context = context_factory.([])
    request_received = TestServer.wait_for_request(server, "/empty.html")
    get = Task.async(fn -> APIRequestContext.get(BrowserContext.request(context), server.empty_page) end)
    post = Task.async(fn -> APIRequestContext.post(BrowserContext.request(context), server.empty_page) end)
    Task.await(request_received, :infinity)
    BrowserContext.close!(context)
    [{:error, error}, {:error, _}] = Task.await_many([get, post], :infinity)
    assert is_exception(error)
    assert Exception.message(error) =~ ~r/Request context disposed|Target page, context or browser has been closed/
    assert_receive :connection_closed, 5000
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: chromium only")
  test "should work with connectOverCDP", %{browser_type: browser_type, server: server} do
    # `9339 + testInfo.workerIndex`: a free port (modules run in parallel).
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    browser_server = BrowserType.launch!(browser_type, args: ["--remote-debugging-port=#{port}"])

    try do
      cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
      [context] = Browser.contexts(cdp_browser)
      response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/simple.json")
      assert APIResponse.url(response) == server.prefix <> "/simple.json"
      assert APIResponse.status(response) == 200
      assert APIResponse.text!(response) == ~s({"foo": "bar"}\n)
    after
      Browser.close(browser_server)
    end
  end

  test "should support SameSite cookie attribute over https", %{
    context_factory: context_factory,
    https_server: https_server,
    browser_name: browser_name
  } do
    # Cookies with SameSite=None must also specify the Secure attribute. WebKit navigation
    # to HTTP url will fail if the response contains a cookie with Secure attribute, so
    # we do HTTPS navigation.
    context = context_factory.(ignore_https_errors: true)
    page = BrowserContext.new_page!(context)

    for value <- ["None", "Lax", "Strict"] do
      # it.step(`SameSite=${value}`)
      TestServer.set_route(https_server, "/empty.html", fn conn ->
        conn |> set_cookies(["SID=2022; Path=/; Secure; SameSite=#{value}"]) |> Plug.Conn.send_resp(200, "")
      end)

      APIRequestContext.get!(Page.request(page), https_server.empty_page)
      [cookie] = BrowserContext.cookies!(Page.context(page))

      # channel !== 'webkit-wsl': we run no channel
      if browser_name == "webkit" and windows?(),
        do: assert(cookie.sameSite == "None"),
        else: assert(cookie.sameSite == value)
    end
  end

  test "should set domain=localhost cookie", %{context: context, server: server} do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn |> set_cookies(["name=val; Domain=#{server.hostname}; Path=/;"]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(BrowserContext.request(context), server.empty_page)
    [cookie] = BrowserContext.cookies!(context)
    assert cookie
    assert cookie.name == "name"
    assert cookie.value == "val"
  end

  test "fetch should not throw on long set-cookie value", %{context: context, server: server} do
    # annotation: https://github.com/microsoft/playwright/issues/27165
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn |> set_cookies(["foo=#{String.duplicate("a", 4100)}; path=/;", "bar=val"]) |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(BrowserContext.request(context), server.empty_page, timeout: 5000)
    cookies = BrowserContext.cookies!(context)
    assert "bar" in Enum.map(cookies, & &1.name)
  end

  test "should support set-cookie with SameSite and without Secure attribute over HTTP", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # isBidi is false, we run no channel
    for value <- ["None", "Lax", "Strict"] do
      # it.step(`SameSite=${value}`)
      TestServer.set_route(server, "/empty.html", fn conn ->
        conn |> set_cookies(["SID=2022; Path=/; SameSite=#{value}"]) |> Plug.Conn.send_resp(200, "")
      end)

      APIRequestContext.get!(Page.request(page), server.empty_page)
      cookie = List.first(BrowserContext.cookies!(Page.context(page)))

      cond do
        browser_name == "chromium" and value == "None" -> refute cookie
        browser_name == "webkit" and linux?() and value == "None" -> refute cookie
        browser_name == "webkit" and windows?() -> assert cookie.sameSite == "None"
        true -> assert cookie.sameSite == value
      end
    end
  end

  test "should update host header on redirect", %{context: context, server: server} do
    # annotation: https://github.com/microsoft/playwright/issues/26743
    {:ok, redirect_count} = Agent.start_link(fn -> 0 end)

    TestServer.set_route(server, "/redirect", fn conn ->
      Agent.update(redirect_count, &(&1 + 1))
      path = if request_header(conn, "host") == URI.parse(server.prefix).authority, do: "/redirect", else: "/test"

      conn
      |> Plug.Conn.put_resp_header("host", URI.parse(server.cross_process_prefix).authority)
      |> Plug.Conn.put_resp_header("location", server.cross_process_prefix <> path)
      |> Plug.Conn.send_resp(302, "")
    end)

    TestServer.set_route(server, "/test", fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_resp(200, "Hello!")
    end)

    req_promise = TestServer.wait_for_request(server, "/test")

    response =
      APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/redirect",
        headers: %{"HosT" => URI.parse(server.prefix).authority}
      )

    assert Agent.get(redirect_count, & &1) == 2
    Expect.to_be_ok!(response)
    assert APIResponse.text!(response) == "Hello!"

    assert request_header(Task.await(req_promise, :infinity), "host") ==
             URI.parse(server.cross_process_prefix).authority
  end

  test "should not work after dispose", %{context: context, server: server} do
    # annotation: https://github.com/microsoft/playwright/issues/27822
    APIRequestContext.dispose!(BrowserContext.request(context))
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.empty_page)
    assert Exception.message(error) =~ @k_target_closed_error_message
  end

  test "should not work after context dispose", %{context: context, server: server} do
    BrowserContext.close!(context, reason: "Test ended.")
    {:error, error} = APIRequestContext.get(BrowserContext.request(context), server.empty_page)
    assert Exception.message(error) =~ "Test ended."
  end

  test "should retry on ECONNRESET", %{context: context, server: server} do
    # annotation: https://github.com/microsoft/playwright/issues/30978
    request_count = :counters.new(1, [])

    TestServer.set_route(server, "/test", fn conn ->
      :counters.add(request_count, 1, 1)

      if :counters.get(request_count, 1) <= 3 do
        destroy_socket(conn)
      else
        conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_resp(200, "Hello!")
      end
    end)

    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/test", max_retries: 3)
    assert APIResponse.status(response) == 200
    assert APIResponse.text!(response) == "Hello!"
    assert :counters.get(request_count, 1) == 4
  end

  test "should retry ECONNRESET on compressed response", %{context: context, server: server} do
    request_count = :counters.new(1, [])

    TestServer.set_route(server, "/test-gzip", fn conn ->
      :counters.add(request_count, 1, 1)

      if :counters.get(request_count, 1) <= 2,
        do: destroy_socket(conn),
        else: send_encoded(conn, "gzip", :zlib.gzip("compressed-retry-ok"))
    end)

    response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/test-gzip", max_retries: 3)
    assert APIResponse.status(response) == 200
    assert APIResponse.text!(response) == "compressed-retry-ok"
    assert :counters.get(request_count, 1) == 3
  end

  test "should retry ECONNRESET mid-stream during gzip decompression", %{context: context, server: server} do
    request_count = :counters.new(1, [])

    TestServer.set_route(server, "/test-gzip-midstream", fn conn ->
      :counters.add(request_count, 1, 1)

      if :counters.get(request_count, 1) <= 2 do
        # Send response headers to make client enter the decompression pipeline,
        # then destroy the socket. This exercises the fix: without it, the
        # pipeline error callback wraps the error, stripping .code for retry.
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_chunked(200)
        |> destroy_socket()
      else
        send_encoded(conn, "gzip", :zlib.gzip("midstream-retry-ok"))
      end
    end)

    response =
      APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/test-gzip-midstream", max_retries: 3)

    assert APIResponse.status(response) == 200
    assert APIResponse.text!(response) == "midstream-retry-ok"
    assert :counters.get(request_count, 1) == 3
  end
end
