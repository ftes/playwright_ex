defmodule PlaywrightEx.Library.BrowsercontextProxyTest do
  @upstream "tests/library/browsercontext-proxy.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestProxy
  alias PlaywrightEx.TestServer

  @browser_name System.get_env("BROWSER", "chromium")

  setup {TestProxy, :proxy_server}
  setup {TestProxy, :socks_port}

  setup %{server: server} do
    TestServer.set_route(server, "/target.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, "<html><title>Served by the proxy</title></html>")
    end)

    :ok
  end

  # proxyServer.setAuthHandler(req => { auth = req.headers['proxy-authorization']; return !!auth; })
  defp record_auth(proxy_server) do
    test_pid = self()

    TestProxy.set_auth_handler(proxy_server, fn req ->
      auth = req.headers["proxy-authorization"]
      send(test_pid, {:auth, auth})
      auth != nil
    end)
  end

  # The last recorded `auth`.
  defp last_auth(acc \\ :none) do
    receive do
      {:auth, auth} -> last_auth(auth)
    after
      0 -> acc
    end
  end

  test "should work when passing the proxy only on the context level",
       %{browser_type: browser_type, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port)
    # proxy: undefined
    browser = BrowserType.launch!(browser_type)

    try do
      context = Browser.new_context!(browser, proxy: %{server: proxy_server.host})

      page = BrowserContext.new_page!(context)
      Page.goto!(page, "http://non-existent.com/target.html")
      assert "http://non-existent.com/target.html" in TestProxy.request_urls(proxy_server)
      assert Page.title!(page) == "Served by the proxy"
    after
      Browser.close!(browser)
    end
  end

  for launch_proxy <- ["per-context", "http://per-context"] do
    @tag launch_proxy: launch_proxy
    test "should ignore legacy '#{launch_proxy}' launch proxy", %{
      browser_type: browser_type,
      server: server,
      proxy_server: proxy_server,
      launch_proxy: launch_proxy
    } do
      TestProxy.forward_to(proxy_server, server.port, allow_connect_requests: true)
      browser = BrowserType.launch!(browser_type, proxy: %{server: launch_proxy})

      try do
        context = Browser.new_context!(browser, proxy: %{server: proxy_server.host})
        page = BrowserContext.new_page!(context)
        Page.goto!(page, "http://non-existent.com/target.html")
        assert Page.title!(page) == "Served by the proxy"
        response = APIRequestContext.get!(BrowserContext.request(context), "http://non-existent.com/target.html")
        assert APIResponse.text!(response) =~ "Served by the proxy"
        assert "non-existent.com:80" in TestProxy.connect_hosts(proxy_server)

        direct_context = Browser.new_context!(browser)
        direct_page = BrowserContext.new_page!(direct_context)
        Page.goto!(direct_page, server.prefix <> "/target.html")
        assert Page.title!(direct_page) == "Served by the proxy"

        direct_response =
          APIRequestContext.get!(BrowserContext.request(direct_context), server.prefix <> "/target.html")

        assert APIResponse.ok(direct_response) == true
      after
        Browser.close!(browser)
      end
    end
  end

  test "should throw for bad server value", %{browser: browser} do
    # contextFactory(options).catch(e => e)
    {:error, error} = Browser.new_context(browser, proxy: %{server: 123})
    assert error.message =~ "proxy.server: expected string, got number"
  end

  test "should use proxy", %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port)
    context = context_factory.(proxy: %{server: proxy_server.host})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert "http://non-existent.com/target.html" in TestProxy.request_urls(proxy_server)
    assert Page.title!(page) == "Served by the proxy"
    BrowserContext.close!(context)
  end

  test "should send secure cookies to subdomain.localhost", %{
    context_factory: context_factory,
    browser_name: browser_name,
    server: server,
    proxy_server: proxy_server
  } do
    is_windows = match?({:win32, _}, :os.type())
    TestProxy.forward_to(proxy_server, server.port)
    context = context_factory.(proxy: %{server: proxy_server.host})

    TestServer.set_route(server, "/set-cookie.html", fn conn ->
      conn
      |> Plug.Conn.prepend_resp_headers([
        {"set-cookie", "non-secure=1; HttpOnly"},
        {"set-cookie", "secure=1; HttpOnly; Secure"}
      ])
      |> Plug.Conn.send_resp(200, "")
    end)

    TestServer.set_route(server, "/read-cookie.html", fn conn ->
      [cookie] = Plug.Conn.get_req_header(conn, "cookie")
      cookies = cookie |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.sort() |> Enum.join("; ")

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<div>Cookie: #{cookies}</div>")
    end)

    page = BrowserContext.new_page!(context)

    Page.goto!(page, "http://subdomain.localhost/set-cookie.html")

    cookies = BrowserContext.cookies!(context, "http://subdomain.localhost")

    # channel === 'webkit-wsl'  -- no channel
    assert Enum.map(cookies, &Map.take(&1, [:name, :domain])) ==
             [%{name: "non-secure", domain: "subdomain.localhost"}] ++
               if(browser_name == "webkit" and not is_windows,
                 do: [],
                 else: [%{name: "secure", domain: "subdomain.localhost"}]
               )

    Page.goto!(page, "http://subdomain.localhost/read-cookie.html")

    Expect.to_have_text!(
      Page.locator(page, "div"),
      if(browser_name == "webkit", do: "Cookie: non-secure=1", else: "Cookie: non-secure=1; secure=1")
    )

    BrowserContext.close!(context)
  end

  # annotation: https://github.com/microsoft/playwright/issues/18362
  # it.fixme(browserName === 'webkit' && (isLinux || channel === 'webkit-wsl'));
  @tag skip:
         if(@browser_name == "webkit" and match?({:unix, :linux}, :os.type()), do: "upstream fixme: webkit on Linux")
  test "should set cookie for top-level domain",
       %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port, allow_connect_requests: true)
    context = context_factory.(proxy: %{server: proxy_server.host})

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", "name=val; Domain=codes; Path=/;") |> Plug.Conn.send_resp(200, "")
    end)

    APIRequestContext.get!(BrowserContext.request(context), "http://codes/empty.html")
    [cookie | _] = BrowserContext.cookies!(context)
    assert cookie
    assert cookie.name == "name"
    assert cookie.value == "val"
    BrowserContext.close!(context)
  end

  for additional_bypass <- [false, true] do
    describe "should proxy local network requests #{if additional_bypass, do: "with other bypasses", else: "by default"}" do
      for {target, description} <- [
            {"localhost", "localhost"},
            {"127.0.0.1", "loopback address"},
            {"169.254.3.4", "link-local"}
          ] do
        @tag additional_bypass: additional_bypass, target: target
        @tag skip:
               (cond do
                  not (@browser_name == "webkit" and match?({:unix, :darwin}, :os.type()) and
                           target in ["localhost", "127.0.0.1"]) ->
                    nil

                  additional_bypass ->
                    "upstream skip: Mac webkit does not proxy localhost when bypass rules are set"

                  true ->
                    "env: Mac webkit (macOS 26) bypasses the proxy for localhost and 127.0.0.1 (upstream client too)"
                end)
        test "#{description}", %{
          context_factory: context_factory,
          server: server,
          proxy_server: proxy_server,
          additional_bypass: additional_bypass,
          target: target
        } do
          path = "/target-#{additional_bypass}-#{target}.html"

          TestServer.set_route(server, path, fn conn ->
            Plug.Conn.send_resp(conn, 200, "<html><title>Served by the proxy</title></html>")
          end)

          url = "http://#{target}:55555#{path}"
          TestProxy.forward_to(proxy_server, server.port)

          context =
            context_factory.(
              proxy:
                if(additional_bypass,
                  do: %{server: proxy_server.host, bypass: "1.non.existent.domain.for.the.test"},
                  else: %{server: proxy_server.host}
                )
            )

          page = BrowserContext.new_page!(context)
          Page.goto!(page, url)
          assert url in TestProxy.request_urls(proxy_server)
          assert Page.title!(page) == "Served by the proxy"

          Page.goto(page, "http://1.non.existent.domain.for.the.test/foo.html")

          if additional_bypass,
            do: refute("http://1.non.existent.domain.for.the.test/foo.html" in TestProxy.request_urls(proxy_server)),
            else: assert("http://1.non.existent.domain.for.the.test/foo.html" in TestProxy.request_urls(proxy_server))

          BrowserContext.close!(context)
        end
      end
    end
  end

  # it.fail(channel === 'webkit-wsl', ...)  -- no channel
  test "should use ipv6 proxy", %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    # it.fail(browserName === 'firefox' && !isBidi, 'page.goto: NS_ERROR_UNKNOWN_HOST')
    expected_failure(@browser_name == "firefox", fn ->
      TestProxy.forward_to(proxy_server, server.port)
      context = context_factory.(proxy: %{server: "[0:0:0:0:0:0:0:1]:#{proxy_server.port}"})
      page = BrowserContext.new_page!(context)
      Page.goto!(page, "http://non-existent.com/target.html")
      assert "http://non-existent.com/target.html" in TestProxy.request_urls(proxy_server)
      assert Page.title!(page) == "Served by the proxy"
      BrowserContext.close!(context)
    end)
  end

  test "should use proxy twice", %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port)
    context = context_factory.(proxy: %{server: proxy_server.host})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert "http://non-existent.com/target.html" in TestProxy.request_urls(proxy_server)
    Page.goto!(page, "http://non-existent-2.com/target.html")
    assert "http://non-existent-2.com/target.html" in TestProxy.request_urls(proxy_server)
    assert Page.title!(page) == "Served by the proxy"
    BrowserContext.close!(context)
  end

  test "should use proxy for second page",
       %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port)
    context = context_factory.(proxy: %{server: proxy_server.host})

    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert "http://non-existent.com/target.html" in TestProxy.request_urls(proxy_server)
    assert Page.title!(page) == "Served by the proxy"

    page2 = BrowserContext.new_page!(context)
    TestProxy.clear_request_urls(proxy_server)
    Page.goto!(page2, "http://non-existent.com/target.html")
    assert "http://non-existent.com/target.html" in TestProxy.request_urls(proxy_server)
    assert Page.title!(page2) == "Served by the proxy"

    BrowserContext.close!(context)
  end

  test "should use proxy for https urls",
       %{context_factory: context_factory, https_server: https_server, proxy_server: proxy_server} do
    TestServer.set_route(https_server, "/target.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, "<html><title>Served by https server via proxy</title></html>")
    end)

    TestProxy.forward_to(proxy_server, https_server.port, allow_connect_requests: true)
    context = context_factory.(ignore_https_errors: true, proxy: %{server: proxy_server.host})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://non-existent.com/target.html")
    assert "non-existent.com:443" in TestProxy.connect_hosts(proxy_server)
    assert Page.title!(page) == "Served by https server via proxy"
    BrowserContext.close!(context)
  end

  test "should work with IP:PORT notion", %{
    context_factory: context_factory,
    server: server,
    proxy_server: proxy_server
  } do
    TestProxy.forward_to(proxy_server, server.port)
    context = context_factory.(proxy: %{server: "127.0.0.1:#{proxy_server.port}"})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert "http://non-existent.com/target.html" in TestProxy.request_urls(proxy_server)
    assert Page.title!(page) == "Served by the proxy"
    BrowserContext.close!(context)
  end

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

  test "should authenticate", %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port)
    record_auth(proxy_server)
    context = context_factory.(proxy: %{server: proxy_server.host, username: "user", password: "secret"})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert "http://non-existent.com/target.html" in TestProxy.request_urls(proxy_server)
    assert last_auth() == "Basic " <> Base.encode64("user:secret")
    assert Page.title!(page) == "Served by the proxy"
    BrowserContext.close!(context)
  end

  test "should authenticate with empty password",
       %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port)
    record_auth(proxy_server)
    context = context_factory.(proxy: %{server: proxy_server.host, username: "user", password: ""})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert last_auth() == "Basic " <> Base.encode64("user:")
    assert Page.title!(page) == "Served by the proxy"
    BrowserContext.close!(context)
  end

  test "should isolate proxy credentials between contexts",
       %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port)
    record_auth(proxy_server)

    context = context_factory.(proxy: %{server: proxy_server.host, username: "user1", password: "secret1"})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert last_auth() == "Basic " <> Base.encode64("user1:secret1")
    assert Page.title!(page) == "Served by the proxy"
    BrowserContext.close!(context)

    # auth = undefined
    last_auth()

    context = context_factory.(proxy: %{server: proxy_server.host, username: "user2", password: "secret2"})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert Page.title!(page) == "Served by the proxy"
    assert last_auth() == "Basic " <> Base.encode64("user2:secret2")
    BrowserContext.close!(context)
  end

  test "should exclude patterns", %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port)
    # FYI: using long and weird domain names to avoid ATT DNS hijacking
    # that resolves everything to some weird search results page.
    #
    # @see https://gist.github.com/CollinChaffin/24f6c9652efb3d6d5ef2f5502720ef00
    context =
      context_factory.(
        proxy: %{
          server: proxy_server.host,
          bypass: "1.non.existent.domain.for.the.test, 2.non.existent.domain.for.the.test, .another.test"
        }
      )

    non_favicon_urls = fn ->
      proxy_server |> TestProxy.request_urls() |> Enum.reject(&String.contains?(&1, "favicon"))
    end

    TestProxy.clear_request_urls(proxy_server)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://0.non.existent.domain.for.the.test/target.html")
    assert "http://0.non.existent.domain.for.the.test/target.html" in TestProxy.request_urls(proxy_server)
    assert Page.title!(page) == "Served by the proxy"
    Page.close!(page)

    for url <- [
          "http://1.non.existent.domain.for.the.test/target.html",
          "http://2.non.existent.domain.for.the.test/target.html",
          "http://foo.is.the.another.test/target.html"
        ] do
      TestProxy.clear_request_urls(proxy_server)
      page = BrowserContext.new_page!(context)
      {:error, error} = Page.goto(page, url)
      assert non_favicon_urls.() == []
      assert error.message
      Page.close!(page)
    end

    TestProxy.clear_request_urls(proxy_server)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://3.non.existent.domain.for.the.test/target.html")
    assert "http://3.non.existent.domain.for.the.test/target.html" in non_favicon_urls.()
    assert Page.title!(page) == "Served by the proxy"
    Page.close!(page)

    BrowserContext.close!(context)
  end

  test "should use socks proxy", %{context_factory: context_factory, socks_port: socks_port} do
    context = context_factory.(proxy: %{server: "socks5://localhost:#{socks_port}"})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com")
    assert Page.title!(page) == "Served by the SOCKS proxy"
    BrowserContext.close!(context)
  end

  test "should use socks proxy in second page", %{context_factory: context_factory, socks_port: socks_port} do
    context = context_factory.(proxy: %{server: "socks5://localhost:#{socks_port}"})

    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com")
    assert Page.title!(page) == "Served by the SOCKS proxy"

    page2 = BrowserContext.new_page!(context)
    Page.goto!(page2, "http://non-existent.com")
    assert Page.title!(page2) == "Served by the SOCKS proxy"

    BrowserContext.close!(context)
  end

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
