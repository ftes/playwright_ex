defmodule PlaywrightEx.Library.FetchProxyTest do
  @upstream "tests/library/fetch-proxy.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.TestProxy
  alias PlaywrightEx.TestServer

  # it.skip(({ mode }) => mode !== 'default');  -- always the default mode

  setup {TestProxy, :proxy_server}
  setup {TestProxy, :socks_port}

  test "PR-041 context request should pick up proxy credentials",
       %{browser_type: browser_type, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port, allow_connect_requests: true)
    test_pid = self()

    TestProxy.set_auth_handler(proxy_server, fn req ->
      header = req.headers["proxy-authorization"]
      # Browser can issue various unrelated requests over the proxy,
      # but we are only interested in our own request.
      if "non-existent.com:80" in TestProxy.connect_hosts(proxy_server), do: send(test_pid, {:auth, header})
      header != nil
    end)

    browser =
      BrowserType.launch!(browser_type,
        proxy: %{server: "localhost:#{proxy_server.port}", username: "user", password: "secret"}
      )

    context = Browser.new_context!(browser)
    response = APIRequestContext.get!(BrowserContext.request(context), "http://non-existent.com/simple.json")
    assert "non-existent.com:80" in TestProxy.connect_hosts(proxy_server)
    assert_receive {:auth, auth}
    assert auth == "Basic " <> Base.encode64("user:secret")
    assert APIResponse.json!(response) == %{"foo" => "bar"}
    Browser.close!(browser)
  end

  test "PR-042 global request should pick up proxy credentials",
       %{playwright: playwright, server: server, proxy_server: proxy_server} do
    TestProxy.forward_to(proxy_server, server.port, allow_connect_requests: true)
    test_pid = self()

    TestProxy.set_auth_handler(proxy_server, fn req ->
      auth = req.headers["proxy-authorization"]
      send(test_pid, {:auth, auth})
      auth != nil
    end)

    request =
      APIRequest.new_context!(Playwright.request(playwright),
        proxy: %{server: "localhost:#{proxy_server.port}", username: "user", password: "secret"}
      )

    response = APIRequestContext.get!(request, "http://non-existent.com/simple.json")
    assert "non-existent.com:80" in TestProxy.connect_hosts(proxy_server)
    # `auth` holds the last request's header.
    assert last_auth() == "Basic " <> Base.encode64("user:secret")
    assert APIResponse.json!(response) == %{"foo" => "bar"}
    APIRequestContext.dispose!(request)
  end

  defp last_auth(last \\ nil) do
    receive do
      {:auth, auth} -> last_auth(auth)
    after
      0 -> last
    end
  end

  test "PR-043 should work with context level proxy",
       %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    TestServer.set_route(server, "/target.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, "<title>Served by the proxy</title>")
    end)

    TestProxy.forward_to(proxy_server, server.port, allow_connect_requests: true)
    context = context_factory.(proxy: %{server: "localhost:#{proxy_server.port}"})

    request_task = TestServer.wait_for_request(server, "/target.html")
    response = APIRequestContext.get!(BrowserContext.request(context), "http://non-existent.com/target.html")
    request = Task.await(request_task, :infinity)
    assert APIResponse.status(response) == 200
    assert request.request_path == "/target.html"
  end

  test "PR-044 should support proxy.bypass", %{
    context_factory: context_factory,
    server: server,
    proxy_server: proxy_server
  } do
    TestServer.set_route(server, "/target.html", fn conn -> Plug.Conn.send_resp(conn, 200, "Served by the proxy") end)
    # FYI: using long and weird domain names to avoid ATT DNS hijacking
    # that resolves everything to some weird search results page.
    #
    # @see https://gist.github.com/CollinChaffin/24f6c9652efb3d6d5ef2f5502720ef00
    TestProxy.forward_to(proxy_server, server.port, allow_connect_requests: true)

    context =
      context_factory.(
        proxy: %{
          server: "localhost:#{proxy_server.port}",
          bypass: "1.non.existent.domain.for.the.test, 2.non.existent.domain.for.the.test, .another.test"
        }
      )

    request = BrowserContext.request(context)

    res = APIRequestContext.get!(request, server.cross_process_prefix <> "/target.html")
    assert APIResponse.text!(res) =~ "Served by the proxy"
    assert URI.parse(server.cross_process_prefix).authority in TestProxy.connect_hosts(proxy_server)
    TestProxy.clear_connect_hosts(proxy_server)

    res = APIRequestContext.get!(request, "http://0.non.existent.domain.for.the.test/target.html")
    assert APIResponse.text!(res) =~ "Served by the proxy"
    TestProxy.clear_connect_hosts(proxy_server)

    {:error, error} = APIRequestContext.get(request, "http://1.non.existent.domain.for.the.test/target.html")
    assert error.message
    assert TestProxy.connect_hosts(proxy_server) == []

    {:error, error} = APIRequestContext.get(request, "http://2.non.existent.domain.for.the.test/target.html")
    assert error.message
    assert TestProxy.connect_hosts(proxy_server) == []

    {:error, error} = APIRequestContext.get(request, "http://foo.is.the.another.test/target.html")
    assert error.message
    assert TestProxy.connect_hosts(proxy_server) == []

    res = APIRequestContext.get!(request, "http://3.non.existent.domain.for.the.test/target.html")
    assert APIResponse.text!(res) =~ "Served by the proxy"
  end

  @tag skip: if(System.get_env("INSIDE_DOCKER", "") != "", do: "upstream skip: connect ECONNREFUSED 127.0.0.1:<port>")
  test "PR-045 should use socks proxy", %{playwright: playwright, server: server, socks_port: socks_port} do
    request =
      APIRequest.new_context!(Playwright.request(playwright), proxy: %{server: "socks5://localhost:#{socks_port}"})

    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.text!(response) =~ "Served by the SOCKS proxy"
  end

  test "PR-046 should send correct ALPN protocol to HTTPS proxy", %{playwright: playwright, server: server} do
    # it.skip(nodeVersion.major < 22, 'ALPNCallback is supported starting from Node 22');
    # https.createServer({ ALPNCallback }): the protocols the client offers in its hello.
    {:ok, listen} =
      :ssl.listen(0, TestServer.cert_options() ++ [handshake: :hello, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :ssl.sockname(listen)
    test_pid = self()

    start_supervised!({Task,
     fn ->
       {:ok, socket} = :ssl.transport_accept(listen)
       {:ok, socket, %{alpn: alpn}} = :ssl.handshake(socket, 5000)
       send(test_pid, {:offered_protocols, for(<<len, name::binary-size(len) <- alpn || "">>, do: name)})
       {:ok, socket} = :ssl.handshake_continue(socket, [], 5000)
       # No 'connect' listener: Node destroys the socket.
       :ssl.close(socket)
     end})

    request =
      APIRequest.new_context!(Playwright.request(playwright),
        proxy: %{server: "https://localhost:#{port}"},
        ignore_https_errors: true
      )

    assert {:error, _} = APIRequestContext.get(request, server.empty_page)

    assert_receive {:offered_protocols, offered_protocols}
    assert "http/1.1" in offered_protocols

    :ssl.close(listen)
    APIRequestContext.dispose!(request)
  end

  test "PR-047 should apply proxy.bypass to redirect targets",
       %{context_factory: context_factory, server: server, proxy_server: proxy_server} do
    cross_process_host = URI.parse(server.cross_process_prefix).authority
    # it.skip(crossProcessHost === server.HOST, 'Needs two different host names for the same server');
    refute cross_process_host == server.host

    TestProxy.forward_to(proxy_server, server.port, allow_connect_requests: true)
    TestServer.set_redirect(server, "/redirect-to-cross-process", server.cross_process_prefix <> "/simple.json")
    TestServer.set_redirect(server, "/redirect-to-same-origin", server.prefix <> "/simple.json")
    context = context_factory.(proxy: %{server: "localhost:#{proxy_server.port}", bypass: server.hostname})
    request = BrowserContext.request(context)

    # Bypassed first hop redirects to a host that must go through the proxy.
    response = APIRequestContext.get!(request, server.prefix <> "/redirect-to-cross-process")
    assert APIResponse.url(response) == server.cross_process_prefix <> "/simple.json"
    assert APIResponse.json!(response) == %{"foo" => "bar"}
    assert TestProxy.connect_hosts(proxy_server) == [cross_process_host]
    TestProxy.clear_connect_hosts(proxy_server)

    # Proxied first hop redirects to a bypassed host.
    response = APIRequestContext.get!(request, server.cross_process_prefix <> "/redirect-to-same-origin")
    assert APIResponse.url(response) == server.prefix <> "/simple.json"
    assert APIResponse.json!(response) == %{"foo" => "bar"}
    assert TestProxy.connect_hosts(proxy_server) == [cross_process_host]
  end
end
