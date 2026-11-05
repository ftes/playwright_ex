defmodule PlaywrightEx.Library.BrowsercontextProxyTest do
  @upstream "tests/library/browsercontext-proxy.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @no_proxy_server "not ported: proxyServer fixture (TestProxy, tests/config/proxy.ts) is not in the test server"
  @no_socks_server "not ported: socksPort fixture (SOCKS server, tests/config/serverFixtures.ts) is not in the test server"

  setup %{server: server} do
    TestServer.set_route(server, "/target.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, "<html><title>Served by the proxy</title></html>")
    end)

    :ok
  end

  @tag skip: @no_proxy_server
  test "should work when passing the proxy only on the context level"

  for launch_proxy <- ["per-context", "http://per-context"] do
    @tag skip: @no_proxy_server
    test "should ignore legacy '#{launch_proxy}' launch proxy"
  end

  test "should throw for bad server value", %{browser: browser} do
    # contextFactory(options).catch(e => e)
    {:error, error} = Browser.new_context(browser, proxy: %{server: 123})
    assert error.message =~ "proxy.server: expected string, got number"
  end

  @tag skip: @no_proxy_server
  test "should use proxy"

  @tag skip: @no_proxy_server
  test "should send secure cookies to subdomain.localhost"

  @tag skip: @no_proxy_server
  test "should set cookie for top-level domain"

  for additional_bypass <- [false, true] do
    describe "should proxy local network requests #{if additional_bypass, do: "with other bypasses", else: "by default"}" do
      for description <- ["localhost", "loopback address", "link-local"] do
        @tag skip: @no_proxy_server
        test "#{description}"
      end
    end
  end

  @tag skip: @no_proxy_server
  test "should use ipv6 proxy"

  @tag skip: @no_proxy_server
  test "should use proxy twice"

  @tag skip: @no_proxy_server
  test "should use proxy for second page"

  @tag skip: @no_proxy_server
  test "should use proxy for https urls"

  @tag skip: @no_proxy_server
  test "should work with IP:PORT notion"

  test "should throw for socks5 authentication", %{browser: browser} do
    {:error, error} =
      Browser.new_context(browser, proxy: %{server: "socks5://localhost:1234", username: "user", password: "secret"})

    assert error.message =~ "Browser does not support socks5 proxy authentication"
  end

  test "should throw for socks4 authentication", %{browser: browser} do
    {:error, error} =
      Browser.new_context(browser, proxy: %{server: "socks4://localhost:1234", username: "user", password: "secret"})

    assert error.message =~ "Socks4 proxy protocol does not support authentication"
  end

  @tag skip: @no_proxy_server
  test "should authenticate"

  @tag skip: @no_proxy_server
  test "should authenticate with empty password"

  @tag skip: @no_proxy_server
  test "should isolate proxy credentials between contexts"

  @tag skip: @no_proxy_server
  test "should exclude patterns"

  @tag skip: @no_socks_server
  test "should use socks proxy"

  @tag skip: @no_socks_server
  test "should use socks proxy in second page"

  test "does launch without a port", %{context_factory: context_factory} do
    context = context_factory.(proxy: %{server: "http://localhost"})
    BrowserContext.close!(context)
  end

  # annotation: https://github.com/microsoft/playwright/issues/31525
  test "should isolate proxy credentials between contexts on navigation", %{
    context_factory: context_factory,
    server: server
  } do
    TestServer.set_route(server, "/target.html", fn conn ->
      case Plug.Conn.get_req_header(conn, "proxy-authorization") do
        [] ->
          conn
          |> Plug.Conn.put_resp_header("proxy-authenticate", ~s(Basic realm="proxy"))
          |> Plug.Conn.send_resp(407, "Proxy authorization required")

        [auth_header | _] ->
          [_, encoded] = String.split(auth_header, " ")
          [username | _] = encoded |> Base.decode64!() |> String.split(":")

          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.send_resp(200, "Hello <div data-testid=user>#{username}</div>!\n")
      end
    end)

    context1 = context_factory.(proxy: %{server: server.prefix, username: "user1", password: "secret1"})
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, "http://non-existent.com/target.html")
    Expect.to_have_text!(Page.get_by_test_id(page1, "user"), "user1")

    context2 = context_factory.(proxy: %{server: server.prefix, username: "user2", password: "secret2"})
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, "http://non-existent.com/target.html")
    Expect.to_have_text!(Page.get_by_test_id(page2, "user"), "user2")

    Page.goto!(page1, "http://non-existent.com/target.html")
    Expect.to_have_text!(Page.get_by_test_id(page1, "user"), "user1")
  end
end
