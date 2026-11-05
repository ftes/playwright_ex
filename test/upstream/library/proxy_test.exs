defmodule PlaywrightEx.Library.ProxyTest do
  @upstream "tests/library/proxy.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestProxy
  alias PlaywrightEx.TestServer

  setup {TestProxy, :proxy_server}
  setup {TestProxy, :socks_port}

  defp served_by_the_proxy(conn), do: Plug.Conn.send_resp(conn, 200, "<html><title>Served by the proxy</title></html>")

  test "should throw for bad server value", %{browser_type: browser_type} do
    # @ts-expect-error server must be a string
    {:error, error} = BrowserType.launch(browser_type, proxy: %{server: 123})
    assert error.message =~ "proxy.server: expected string, got number"
  end

  test "should use proxy @smoke", %{browser_type: browser_type, server: server} do
    TestServer.set_route(server, "/target.html", &served_by_the_proxy/1)
    browser = BrowserType.launch!(browser_type, proxy: %{server: server.host})
    page = Browser.new_page!(browser)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert Page.title!(page) == "Served by the proxy"
    Browser.close!(browser)
  end

  test "should use proxy for second page", %{browser_type: browser_type, server: server} do
    TestServer.set_route(server, "/target.html", &served_by_the_proxy/1)
    browser = BrowserType.launch!(browser_type, proxy: %{server: "localhost:#{server.port}"})

    page = Browser.new_page!(browser)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert Page.title!(page) == "Served by the proxy"

    page2 = Browser.new_page!(browser)
    Page.goto!(page2, "http://non-existent.com/target.html")
    assert Page.title!(page2) == "Served by the proxy"

    Browser.close!(browser)
  end

  test "should work with IP:PORT notion", %{browser_type: browser_type, server: server} do
    TestServer.set_route(server, "/target.html", &served_by_the_proxy/1)
    browser = BrowserType.launch!(browser_type, proxy: %{server: "127.0.0.1:#{server.port}"})
    page = Browser.new_page!(browser)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert Page.title!(page) == "Served by the proxy"
    Browser.close!(browser)
  end

  for additional_bypass <- [false, true] do
    describe "should proxy local network requests #{if additional_bypass, do: "with other bypasses", else: "by default"}" do
      for {target, description} <- [
            {"localhost", "localhost"},
            {"127.0.0.1", "loopback address"},
            {"169.254.3.4", "link-local"}
          ] do
        @tag additional_bypass: additional_bypass, target: target
        # it.skip(browserName === 'webkit' && platform === 'darwin' && ... && additionalBypass, 'Mac webkit does not proxy localhost when bypass rules are set.');
        @tag skip:
               if(
                 System.get_env("BROWSER") == "webkit" and match?({:unix, :darwin}, :os.type()) and
                   target in ["localhost", "127.0.0.1"] and additional_bypass,
                 do: "Mac webkit does not proxy localhost when bypass rules are set."
               )
        test "#{description}", %{
          browser_type: browser_type,
          server: server,
          proxy_server: proxy_server,
          additional_bypass: additional_bypass,
          target: target
        } do
          # it.skip(channel?.startsWith('msedge'), 'times out while loading the page');  -- no channel
          path = "/target-#{additional_bypass}-#{target}.html"
          TestServer.set_route(server, path, &served_by_the_proxy/1)

          url = "http://#{target}:55555#{path}"
          TestProxy.forward_to(proxy_server, server.port)

          proxy =
            if additional_bypass,
              do: %{server: "localhost:#{proxy_server.port}", bypass: "1.non.existent.domain.for.the.test"},
              else: %{server: "localhost:#{proxy_server.port}"}

          browser = BrowserType.launch!(browser_type, proxy: proxy)

          page = Browser.new_page!(browser)
          Page.goto!(page, url)
          assert url in TestProxy.request_urls(proxy_server)
          assert Page.title!(page) == "Served by the proxy"

          Page.goto(page, "http://1.non.existent.domain.for.the.test/foo.html")

          if additional_bypass,
            do: refute("http://1.non.existent.domain.for.the.test/foo.html" in TestProxy.request_urls(proxy_server)),
            else: assert("http://1.non.existent.domain.for.the.test/foo.html" in TestProxy.request_urls(proxy_server))

          Browser.close!(browser)
        end
      end
    end
  end

  for host <- ["localhost", "127.0.0.1"] do
    @host host
    test "should allow bypassing #{host} requests", %{
      browser_type: browser_type,
      server: server,
      proxy_server: proxy_server
    } do
      host = @host

      TestServer.set_route(server, "/proxied/target.html", fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html><title>Served by the server</title></html>")
      end)

      TestServer.set_route(server, "/target.html", &served_by_the_proxy/1)
      TestProxy.forward_to(proxy_server, server.port, remove_prefix: "/proxied")

      browser = BrowserType.launch!(browser_type, proxy: %{server: "localhost:#{proxy_server.port}", bypass: host})
      page = Browser.new_page!(browser)
      Page.goto!(page, "http://#{host}:#{server.port}/proxied/target.html")
      assert Page.title!(page) == "Served by the server"
      Browser.close!(browser)
    end
  end

  test "should authenticate", %{browser_type: browser_type, server: server} do
    TestServer.set_route(server, "/target.html", fn conn ->
      case Plug.Conn.get_req_header(conn, "proxy-authorization") do
        [] ->
          conn
          |> Plug.Conn.put_resp_header("proxy-authenticate", ~s(Basic realm="Access to internal site"))
          |> Plug.Conn.send_resp(407, "")

        [auth | _] ->
          Plug.Conn.send_resp(conn, 200, "<html><title>#{auth}</title></html>")
      end
    end)

    browser =
      BrowserType.launch!(browser_type, proxy: %{server: server.host, username: "user", password: "secret"})

    page = Browser.new_page!(browser)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert Page.title!(page) == "Basic " <> Base.encode64("user:secret")
    Browser.close!(browser)
  end

  test "should reconnect with credentials after CONNECT 407 closes the socket",
       %{browser_type: browser_type, https_server: https_server, proxy_server: proxy_server} do
    # Some HTTP proxies send 407 and close the socket on the first CONNECT, expecting
    # the client to reconnect on a new TCP connection with Proxy-Authorization.
    TestServer.set_route(https_server, "/target.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, "<html><title>Served by https server via proxy</title></html>")
    end)

    TestProxy.forward_to(proxy_server, https_server.port, allow_connect_requests: true)

    {:ok, connect_attempts} = Agent.start_link(fn -> %{attempts: [], closed_first_connect: false} end)

    TestProxy.set_auth_handler(proxy_server, fn req ->
      # WebKit on Windows uses libcurl and sends Proxy-Authorization preemptively
      # on every CONNECT, while libsoup on Linux/macOS sends it only after a 407.
      # Force the first CONNECT to fail regardless to deterministically exercise
      # the reconnect path on all platforms.
      if req.method != "CONNECT" or not String.starts_with?(req.headers["host"] || "", "non-existent.com") do
        true
      else
        had_auth = req.headers["proxy-authorization"] != nil

        Agent.get_and_update(connect_attempts, fn state ->
          state = %{state | attempts: state.attempts ++ [%{had_auth: had_auth}]}

          if state.closed_first_connect,
            do: {had_auth, state},
            else: {false, %{state | closed_first_connect: true}}
        end)
      end
    end)

    browser =
      BrowserType.launch!(browser_type, proxy: %{server: proxy_server.host, username: "user", password: "secret"})

    page = Browser.new_page!(browser, ignore_https_errors: true)
    Page.goto!(page, "https://non-existent.com/target.html")
    assert Page.title!(page) == "Served by https server via proxy"
    attempts = Agent.get(connect_attempts, & &1.attempts)
    assert length(attempts) >= 2
    assert Enum.any?(attempts, & &1.had_auth)
    Browser.close!(browser)
  end

  test "should work with authenticate followed by redirect", %{browser_type: browser_type, server: server} do
    has_auth = fn conn ->
      case Plug.Conn.get_req_header(conn, "proxy-authorization") do
        [] ->
          conn =
            conn
            |> Plug.Conn.put_resp_header("proxy-authenticate", ~s(Basic realm="Access to internal site"))
            |> Plug.Conn.send_resp(407, "")

          {false, conn}

        _ ->
          {true, conn}
      end
    end

    TestServer.set_route(server, "/page1.html", fn conn ->
      case has_auth.(conn) do
        {false, conn} -> conn
        {true, conn} -> conn |> Plug.Conn.put_resp_header("location", "/page2.html") |> Plug.Conn.send_resp(302, "")
      end
    end)

    TestServer.set_route(server, "/page2.html", fn conn ->
      case has_auth.(conn) do
        {false, conn} -> conn
        {true, conn} -> served_by_the_proxy(conn)
      end
    end)

    browser =
      BrowserType.launch!(browser_type, proxy: %{server: server.host, username: "user", password: "secret"})

    page = Browser.new_page!(browser)
    Page.goto!(page, "http://non-existent.com/page1.html")
    assert Page.title!(page) == "Served by the proxy"
    Browser.close!(browser)
  end

  test "should exclude patterns", %{browser_type: browser_type, server: server} do
    # it.skip(channel?.startsWith('msedge'), 'times out while loading the page');  -- no channel
    TestServer.set_route(server, "/target.html", &served_by_the_proxy/1)
    # FYI: using long and weird domain names to avoid ATT DNS hijacking
    # that resolves everything to some weird search results page.
    #
    # @see https://gist.github.com/CollinChaffin/24f6c9652efb3d6d5ef2f5502720ef00
    browser =
      BrowserType.launch!(browser_type,
        proxy: %{
          server: server.host,
          bypass: "1.non.existent.domain.for.the.test, 2.non.existent.domain.for.the.test, .another.test"
        }
      )

    page = Browser.new_page!(browser)
    Page.goto!(page, "http://0.non.existent.domain.for.the.test/target.html")
    assert Page.title!(page) == "Served by the proxy"
    Page.close!(page)

    page = Browser.new_page!(browser)
    {:error, error} = Page.goto(page, "http://1.non.existent.domain.for.the.test/target.html")
    assert error.message
    Page.close!(page)

    page = Browser.new_page!(browser)
    {:error, error} = Page.goto(page, "http://2.non.existent.domain.for.the.test/target.html")
    assert error.message
    Page.close!(page)

    page = Browser.new_page!(browser)
    {:error, error} = Page.goto(page, "http://foo.is.the.another.test/target.html")
    assert error.message
    Page.close!(page)

    page = Browser.new_page!(browser)
    Page.goto!(page, "http://3.non.existent.domain.for.the.test/target.html")
    assert Page.title!(page) == "Served by the proxy"
    Page.close!(page)

    Browser.close!(browser)
  end

  for host <- ["localhost", "127.0.0.1"] do
    @host host
    test "should bypass proxy for #{host} when #{host} is in bypass list",
         %{browser_type: browser_type, server: server, proxy_server: proxy_server} do
      host = @host
      TestProxy.forward_to(proxy_server, server.port, remove_prefix: "/proxied")

      TestServer.set_route(server, "/proxied/target.html", fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html><title>Served by the server</title></html>")
      end)

      TestServer.set_route(server, "/target.html", &served_by_the_proxy/1)
      browser = BrowserType.launch!(browser_type, proxy: %{server: "localhost:#{proxy_server.port}", bypass: host})
      page = Browser.new_page!(browser)
      Page.goto!(page, "http://#{host}:#{server.port}/proxied/target.html")
      assert Page.title!(page) == "Served by the server"
      Browser.close!(browser)
    end
  end

  test "should use socks proxy", %{browser_type: browser_type, socks_port: socks_port} do
    browser = BrowserType.launch!(browser_type, proxy: %{server: "socks5://localhost:#{socks_port}"})
    page = Browser.new_page!(browser)
    Page.goto!(page, "http://non-existent.com")
    assert Page.title!(page) == "Served by the SOCKS proxy"
    Browser.close!(browser)
  end

  test "should use socks proxy in second page", %{browser_type: browser_type, socks_port: socks_port} do
    browser = BrowserType.launch!(browser_type, proxy: %{server: "socks5://localhost:#{socks_port}"})

    page = Browser.new_page!(browser)
    Page.goto!(page, "http://non-existent.com")
    assert Page.title!(page) == "Served by the SOCKS proxy"

    page2 = Browser.new_page!(browser)
    Page.goto!(page2, "http://non-existent.com")
    assert Page.title!(page2) == "Served by the SOCKS proxy"

    Browser.close!(browser)
  end

  test "does launch without a port", %{browser_type: browser_type} do
    browser = BrowserType.launch!(browser_type, proxy: %{server: "http://localhost"})
    Browser.close!(browser)
  end

  @tag skip: "upstream fixme: Non-emulated user agent is used in proxy CONNECT"
  test "should use proxy with emulated user agent"

  test "should use SOCKS proxy for websocket requests", %{browser_type: browser_type, server: server} do
    %{proxy_server_addr: proxy_server_addr, close_proxy_server: close_proxy_server} =
      TestProxy.setup_socks_forwarding_server(port: 0, forward_port: server.port, allowed_target_port: 1337)

    browser = BrowserType.launch!(browser_type, proxy: %{server: proxy_server_addr})
    TestServer.send_on_web_socket_connection(server, "incoming")
    TestServer.set_route(server, "/target.html", &served_by_the_proxy/1)

    page = Browser.new_page!(browser)

    # Hosts get resolved by the client
    Page.goto!(page, "http://fake-localhost-127-0-0-1.nip.io:1337/target.html")
    assert Page.title!(page) == "Served by the proxy"

    value =
      Page.evaluate!(page, """
      () => {
        let cb;
        const result = new Promise(f => cb = f);
        const ws = new WebSocket('ws://fake-localhost-127-0-0-1.nip.io:1337/ws');
        ws.addEventListener('message', data => { ws.close(); cb(data.data); });
        return result;
      }
      """)

    assert value == "incoming"

    Browser.close!(browser)
    close_proxy_server.()
  end

  test "should use http proxy for websocket requests",
       %{browser_name: browser_name, browser_type: browser_type, server: server, proxy_server: proxy_server} do
    # it.skip(isMac && macVersion === 13, 'Times out on Mac 13');
    TestProxy.forward_to(proxy_server, server.port, allow_connect_requests: true)
    browser = BrowserType.launch!(browser_type, proxy: %{server: "localhost:#{proxy_server.port}"})

    TestServer.send_on_web_socket_connection(server, "incoming")
    TestServer.set_route(server, "/target.html", &served_by_the_proxy/1)

    page = Browser.new_page!(browser)

    Page.goto!(page, "http://fake-localhost-127-0-0-1.nip.io:1337/target.html")
    assert Page.title!(page) == "Served by the proxy"

    value =
      Page.evaluate!(page, """
      () => {
        let cb;
        const result = new Promise(f => cb = f);
        const ws = new WebSocket('ws://fake-localhost-127-0-0-1.nip.io:1337/ws');
        ws.addEventListener('message', data => { ws.close(); cb(data.data); });
        return result;
      }
      """)

    assert value == "incoming"

    # WebKit does not use CONNECT for websockets, but other browsers do.
    if browser_name == "webkit" do
      is_windows = match?({:win32, _}, :os.type())

      assert if(is_windows, do: "/ws", else: "ws://fake-localhost-127-0-0-1.nip.io:1337/ws") in TestProxy.ws_urls(
               proxy_server
             )
    else
      assert "fake-localhost-127-0-0-1.nip.io:1337" in TestProxy.connect_hosts(proxy_server)
    end

    Browser.close!(browser)
  end
end
