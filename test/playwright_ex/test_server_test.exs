defmodule PlaywrightEx.TestServerTest do
  # No browser test reaches the server before Page is ported, so this checks it with :httpc.
  use ExUnit.Case, async: true

  alias PlaywrightEx.TestServer

  setup_all do
    assets = Path.join(PlaywrightEx.Upstream.ensure!(), "tests/assets")
    server = TestServer.server(start_supervised!({TestServer, dir_path: assets}, id: :server))
    TestServer.enable_http_cache(server, Path.join(assets, "cached"))

    https_server =
      TestServer.server(
        start_supervised!({TestServer, dir_path: assets, ssl_options: TestServer.cert_options()}, id: :https_server)
      )

    %{server: server, https_server: https_server}
  end

  setup %{server: server}, do: TestServer.reset(server)

  defp request(url, opts \\ []) do
    method = Keyword.get(opts, :method, :get)
    headers = for {k, v} <- Keyword.get(opts, :headers, []), do: {to_charlist(k), to_charlist(v)}

    request =
      if body = opts[:body],
        do: {to_charlist(url), headers, ~c"text/plain", body},
        else: {to_charlist(url), headers}

    http_opts = [autoredirect: false, ssl: [verify: :verify_none]]
    {:ok, {{_, status, _}, headers, body}} = :httpc.request(method, request, http_opts, body_format: :binary)
    {status, Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}
  end

  test "listens on both loopback addresses", %{server: server} do
    for ip <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      {:ok, socket} = :gen_tcp.connect(ip, server.port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /empty.html HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")
      assert {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0)
      :gen_tcp.close(socket)
    end
  end

  test "URL constants", %{server: server} do
    assert server.prefix == "http://localhost:#{server.port}"
    assert server.cross_process_prefix == "http://127.0.0.1:#{server.port}"
    assert server.empty_page == "#{server.prefix}/empty.html"
    assert server.host == "localhost:#{server.port}"
  end

  test "serves assets, 404 otherwise", %{server: server} do
    assert {200, headers, ""} = request(server.empty_page)
    assert headers["content-type"] == "text/html; charset=utf-8"
    assert headers["cache-control"] == "no-cache, no-store"

    assert {404, _, "File not found: " <> _} = request(server.prefix <> "/nope.html")
  end

  test "HTTP cache for the cached prefix", %{server: server} do
    assert {200, %{"last-modified" => _, "cache-control" => "public, max-age=31536000, no-cache"}, _} =
             request(server.prefix <> "/cached/one-style.html")

    assert {304, _, ""} = request(server.prefix <> "/cached/one-style.html", headers: [{"if-modified-since", "x"}])
  end

  test "routes, content, redirects", %{server: server} do
    TestServer.set_route(server, "/echo?x=1", fn conn -> Plug.Conn.send_resp(conn, 201, conn.assigns.post_body) end)
    assert {201, _, "hello"} = request(server.prefix <> "/echo?x=1", method: :post, body: "hello")

    TestServer.set_content(server, "/content", "<p>hi</p>", "text/html")
    assert {200, %{"content-type" => "text/html"}, "<!DOCTYPE html><p>hi</p>"} = request(server.prefix <> "/content")

    TestServer.set_extra_headers(server, "/from", %{"X-Extra" => "1"})
    TestServer.set_redirect(server, "/from", "/empty.html")
    assert {302, %{"location" => "/empty.html", "x-extra" => "1"}, _} = request(server.prefix <> "/from")
  end

  test "wait_for_request resolves with the request", %{server: server} do
    waiting = TestServer.wait_for_request(server, "/empty.html")
    request(server.empty_page, headers: [{"foo", "bar"}])
    conn = Task.await(waiting)
    assert Plug.Conn.get_req_header(conn, "foo") == ["bar"]
    assert conn.method == "GET"
  end

  test "auth, gzip, csp, reset", %{server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    assert {401, %{"www-authenticate" => ~s(Basic realm="Secure Area")}, _} = request(server.empty_page)

    assert {200, _, _} =
             request(server.empty_page, headers: [{"authorization", "Basic " <> Base.encode64("user:pass")}])

    TestServer.enable_gzip(server, "/one-style.css")
    TestServer.set_csp(server, "/one-style.css", "default-src 'self'")
    assert {200, headers, body} = request(server.prefix <> "/one-style.css")
    assert headers["content-encoding"] == "gzip"
    assert headers["content-security-policy"] == "default-src 'self'"
    assert :zlib.gunzip(body) =~ "body"

    TestServer.reset(server)
    assert {200, _, _} = request(server.empty_page)
  end

  test "https", %{https_server: https_server} do
    assert https_server.prefix == "https://localhost:#{https_server.port}"
    assert {200, _, _} = request(https_server.empty_page)
  end
end
