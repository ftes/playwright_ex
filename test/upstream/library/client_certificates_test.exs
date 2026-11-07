# Servers of the spec below (outside its module: nested modules would inherit its `@upstream`).
defmodule PlaywrightEx.Library.ClientCertificatesTest.CCServer do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :ca)

  @impl true
  def call(conn, ca) do
    ssl_data = Plug.Conn.get_ssl_data(conn) || []
    alpn = if Plug.Conn.get_http_protocol(conn) == :"HTTP/2", do: "h2", else: "http/1.1"
    servername = if sni = ssl_data[:sni_hostname], do: to_string(sni), else: "false"
    parts = [{"alpn-protocol", alpn}, {"servername", servername}]
    cert = Plug.Conn.get_peer_data(conn).ssl_cert

    {status, message} =
      cond do
        cert && match?({:ok, _}, :public_key.pkix_path_validation(ca, [cert], [])) ->
          {200, "Hello #{cn(cert, :subject)}, your certificate was issued by #{cn(cert, :issuer)}!"}

        cert ->
          {403, "Sorry #{cn(cert, :subject)}, certificates from #{cn(cert, :issuer)} are not welcome here."}

        true ->
          {401, "Sorry, but you need to provide a client certificate to continue."}
      end

    parts = parts ++ [{"message", message}]

    conn
    |> Plug.Conn.put_resp_header("content-type", "text/html")
    |> Plug.Conn.send_resp(
      status,
      Enum.map_join(parts, fn {key, value} -> ~s(<div data-testid="#{key}">#{value}</div>) end)
    )
  end

  defp cn(der, field) do
    tbs = der |> :public_key.pkix_decode_cert(:otp) |> elem(1)
    {:rdnSequence, rdns} = elem(tbs, if(field == :subject, do: 6, else: 4))

    Enum.find_value(List.flatten(rdns), fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, {_, value}} -> to_string(value)
      {:AttributeTypeAndValue, {2, 5, 4, 3}, value} -> to_string(value)
      _ -> nil
    end)
  end
end

defmodule PlaywrightEx.Library.ClientCertificatesTest.Respond do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    opts[:headers]
    |> Enum.reduce(conn, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end)
    |> Plug.Conn.send_resp(opts[:status], opts[:body])
  end
end

defmodule PlaywrightEx.Library.ClientCertificatesTest do
  @upstream "tests/library/client-certificates.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.RemoteServer.ChildProcess
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestProxy
  alias PlaywrightEx.TestServer

  setup {TestProxy, :proxy_server}

  # test.extend({ startCCServer }): `start_cc_server.(options)` returns the server URL, the
  # server is stopped after the test. On Bandit: `http2: true` serves HTTP/2 only (Node's
  # `createHttp2Server` without `allowHTTP1`), `enable_http1_fallback_when_using_http2` both.
  # Node's servers do not compress responses (`compress: false`; Firefox would get zstd).
  # Node's `tlsSocket.authorized` is a path validation of the peer certificate against the CA.
  # process.env.PWTEST_UNSUPPORTED_CUSTOM_CA = ...  -- not ported: unused by the driver
  setup %{asset: asset} do
    start_cc_server = fn options ->
      options = Map.new(options)
      http2 = options[:http2] || false
      ca = asset.("client-certificates/server/server_cert.pem")

      verify_options =
        if options[:reject_unauthorized],
          do: [verify: :verify_peer, fail_if_no_peer_cert: true],
          else: [verify: :verify_peer, fail_if_no_peer_cert: false, verify_fun: {&accept_any_cert/3, nil}]

      pid =
        start_supervised!(
          {Bandit,
           plug: {PlaywrightEx.Library.ClientCertificatesTest.CCServer, ca: ca |> File.read!() |> pem_der()},
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           http_options: [compress: false],
           http_1_options: [enabled: not http2 or options[:enable_http1_fallback_when_using_http2] == true],
           http_2_options: [enabled: http2],
           thousand_island_options: [
             transport_options:
               [
                 # TLS alerts are expected here (Node logs none).
                 log_level: :warning,
                 keyfile: asset.("client-certificates/server/server_key.pem"),
                 certfile: ca,
                 cacertfile: ca
               ] ++ verify_options
           ]},
          id: :cc_server
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      host = if options[:use_fake_localhost], do: "local.playwright", else: "127.0.0.1"
      "https://#{host}:#{port}/"
    end

    %{start_cc_server: start_cc_server}
  end

  defp accept_any_cert(_cert, {:bad_cert, _}, state), do: {:valid, state}
  defp accept_any_cert(_cert, {:extension, _}, state), do: {:unknown, state}
  defp accept_any_cert(_cert, _event, state), do: {:valid, state}

  defp pem_der(pem), do: pem |> :public_key.pem_decode() |> hd() |> elem(1)

  defp origin(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  defp fake_localhost?(browser_name), do: browser_name == "webkit" and match?({:unix, :darwin}, :os.type())

  defp trusted(asset, origin) do
    %{
      origin: origin,
      certPath: asset.("client-certificates/client/trusted/cert.pem"),
      keyPath: asset.("client-certificates/client/trusted/key.pem")
    }
  end

  defp self_signed(asset, origin) do
    %{
      origin: origin,
      certPath: asset.("client-certificates/client/self-signed/cert.pem"),
      keyPath: asset.("client-certificates/client/self-signed/key.pem")
    }
  end

  @dummy_file_name __ENV__.file
  @validation_sub_tests [
    {[client_certificates: [%{origin: "test"}]], "None of cert, key, passphrase or pfx is specified"},
    {[
       client_certificates: [
         %{
           origin: "test",
           certPath: @dummy_file_name,
           keyPath: @dummy_file_name,
           pfxPath: @dummy_file_name,
           passphrase: @dummy_file_name
         }
       ]
     ], "pfx is specified together with cert, key or passphrase"}
  ]

  # The server of "should handle TLS renegotiation with client certificates", a Node.js process
  # (stopped after the test): its port.
  defp start_tls_renegotiation_server do
    {node, _cli} = PlaywrightEx.Driver.ensure_installed()
    script = Path.expand("../../support/tls_renegotiation_server.js", __DIR__)
    assets = Path.join(PlaywrightEx.Upstream.ensure!(), "tests/assets")
    {node, args, env} = ChildProcess.exit_on_stdin_eof({node, [script, assets]})
    process = ChildProcess.start(node, args, env)
    on_exit(fn -> ChildProcess.stop(process) end)

    ChildProcess.await(process, fn output ->
      case Regex.run(~r/\(port=>(\d+)\)/, output) do
        [_, port] -> {:ok, String.to_integer(port)}
        nil -> nil
      end
    end)
  end

  defp new_request(playwright, options), do: APIRequest.new_context!(Playwright.request(playwright), options)

  describe "fetch" do
    test "CC-001 validate input", %{playwright: playwright} do
      for {context_options, expected} <- @validation_sub_tests do
        {:error, error} = APIRequest.new_context(Playwright.request(playwright), context_options)
        assert error.message =~ expected
      end
    end

    test "CC-002 should fail with no client certificates provided", %{
      playwright: playwright,
      start_cc_server: start_cc_server
    } do
      server_url = start_cc_server.([])
      request = new_request(playwright, ignore_https_errors: true)
      response = APIRequestContext.get!(request, server_url)
      assert APIResponse.status(response) == 401
      assert APIResponse.text!(response) =~ "Sorry, but you need to provide a client certificate to continue."
      APIRequestContext.dispose!(request)
    end

    test "CC-003 should keep supporting http", %{playwright: playwright, server: server, asset: asset} do
      request =
        new_request(playwright,
          ignore_https_errors: true,
          client_certificates: [trusted(asset, origin(server.prefix))]
        )

      response = APIRequestContext.get!(request, server.prefix <> "/one-style.html")
      assert APIResponse.url(response) == server.prefix <> "/one-style.html"
      assert APIResponse.status(response) == 200
      assert APIResponse.text!(response) =~ "<div>hello, world!</div>"
      APIRequestContext.dispose!(request)
    end

    test "CC-004 should throw with untrusted client certs",
         %{playwright: playwright, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.([])

      request =
        new_request(playwright,
          ignore_https_errors: true,
          client_certificates: [self_signed(asset, origin(server_url))]
        )

      response = APIRequestContext.get!(request, server_url)
      assert APIResponse.url(response) == server_url
      assert APIResponse.status(response) == 403
      assert APIResponse.text!(response) =~ "Sorry Bob, certificates from Bob are not welcome here."
      APIRequestContext.dispose!(request)
    end

    test "CC-005 pass with trusted client certificates",
         %{playwright: playwright, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.([])

      request =
        new_request(playwright, ignore_https_errors: true, client_certificates: [trusted(asset, origin(server_url))])

      response = APIRequestContext.get!(request, server_url)
      assert APIResponse.url(response) == server_url
      assert APIResponse.status(response) == 200
      assert APIResponse.text!(response) =~ "Hello Alice, your certificate was issued by localhost!"
      APIRequestContext.dispose!(request)
    end

    test "CC-006 should not leak client certificate to cross-origin redirect target",
         %{playwright: playwright, start_cc_server: start_cc_server, asset: asset} do
      target_url = start_cc_server.([])

      # Standalone HTTPS server (not cert-required) that 302-redirects to the cert-required server.
      redirect_server =
        start_supervised!(
          {Bandit,
           plug:
             {PlaywrightEx.Library.ClientCertificatesTest.Respond,
              status: 302, headers: [{"location", target_url}], body: ""},
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [
             transport_options: [
               # TLS alerts are expected here (Node logs none).
               log_level: :warning,
               keyfile: asset.("client-certificates/server/server_key.pem"),
               certfile: asset.("client-certificates/server/server_cert.pem")
             ]
           ]},
          id: :redirect_server
        )

      {:ok, {_ip, redirect_port}} = ThousandIsland.listener_info(redirect_server)
      # Use 'localhost' for the redirect origin so it differs from the target's '127.0.0.1' origin
      # even though both resolve to the loopback interface and share the same trusted CA.
      redirect_url = "https://localhost:#{redirect_port}/redir"

      request =
        new_request(playwright,
          ignore_https_errors: true,
          # Cert is scoped to the redirect *origin*, not the target — it must not follow the redirect.
          client_certificates: [trusted(asset, origin(redirect_url))]
        )

      response = APIRequestContext.get!(request, redirect_url)
      assert APIResponse.url(response) == target_url
      assert APIResponse.status(response) == 401
      assert APIResponse.text!(response) =~ "you need to provide a client certificate"
      APIRequestContext.dispose!(request)
    end

    test "CC-007 pass with trusted client certificates in pfx format",
         %{playwright: playwright, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.([])

      request =
        new_request(playwright,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: origin(server_url),
              pfxPath: asset.("client-certificates/client/trusted/cert.pfx"),
              passphrase: "secure"
            }
          ]
        )

      response = APIRequestContext.get!(request, server_url)
      assert APIResponse.url(response) == server_url
      assert APIResponse.status(response) == 200
      assert APIResponse.text!(response) =~ "Hello Alice, your certificate was issued by localhost!"
      APIRequestContext.dispose!(request)
    end

    test "CC-008 pass with trusted client certificates and when a http proxy is used",
         %{playwright: playwright, start_cc_server: start_cc_server, proxy_server: proxy_server, asset: asset} do
      server_url = start_cc_server.([])
      TestProxy.forward_to(proxy_server, URI.parse(server_url).port, allow_connect_requests: true)

      request =
        new_request(playwright,
          ignore_https_errors: true,
          client_certificates: [trusted(asset, origin(server_url))],
          proxy: %{server: "localhost:#{proxy_server.port}"}
        )

      assert TestProxy.connect_hosts(proxy_server) == []
      response = APIRequestContext.get!(request, server_url)
      assert TestProxy.connect_hosts(proxy_server) == [URI.parse(server_url).authority]
      assert APIResponse.url(response) == server_url
      assert APIResponse.status(response) == 200
      assert APIResponse.text!(response) =~ "Hello Alice, your certificate was issued by localhost!"
      APIRequestContext.dispose!(request)
    end

    test "CC-009 pass with trusted client certificates and when a socks proxy is used",
         %{playwright: playwright, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.([])
      server_port = URI.parse(server_url).port

      %{proxy_server_addr: proxy_server_addr, close_proxy_server: close_proxy_server, connect_hosts: connect_hosts} =
        TestProxy.setup_socks_forwarding_server(port: 0, forward_port: server_port, allowed_target_port: server_port)

      request =
        new_request(playwright,
          ignore_https_errors: true,
          client_certificates: [trusted(asset, origin(server_url))],
          proxy: %{server: proxy_server_addr}
        )

      assert connect_hosts.() == []
      response = APIRequestContext.get!(request, server_url)
      assert connect_hosts.() == [URI.parse(server_url).authority]
      assert APIResponse.url(response) == server_url
      assert APIResponse.status(response) == 200
      assert APIResponse.text!(response) =~ "Hello Alice, your certificate was issued by localhost!"
      APIRequestContext.dispose!(request)
      close_proxy_server.()
    end

    test "CC-010 should throw a http error if the pfx passphrase is incorect",
         %{playwright: playwright, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.([])

      request =
        new_request(playwright,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: origin(server_url),
              pfxPath: asset.("client-certificates/client/trusted/cert.pfx"),
              passphrase: "this-password-is-incorrect"
            }
          ]
        )

      {:error, error} = APIRequestContext.get(request, server_url)
      assert error.message =~ "mac verify failure"
      APIRequestContext.dispose!(request)
    end

    test "CC-011 should fail with matching certificates in legacy pfx format",
         %{playwright: playwright, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.([])

      request =
        new_request(playwright,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: origin(server_url),
              pfxPath: asset.("client-certificates/client/trusted/cert-legacy.pfx"),
              passphrase: "secure"
            }
          ]
        )

      {:error, error} = APIRequestContext.get(request, server_url)
      assert error.message =~ "Unsupported TLS certificate"
      APIRequestContext.dispose!(request)
    end

    test "CC-012 should work in the browser with request interception",
         %{browser: browser, playwright: playwright, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.([])

      request =
        new_request(playwright, ignore_https_errors: true, client_certificates: [trusted(asset, origin(server_url))])

      page = Browser.new_page!(browser, ignore_https_errors: true)

      Page.route!(page, "**/*", fn route ->
        response = APIRequestContext.fetch!(request, Route.request(route))
        Route.fulfill!(route, response: response)
      end)

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
      APIRequestContext.dispose!(request)
    end
  end

  describe "browser" do
    test "CC-013 validate input", %{browser: browser} do
      for {context_options, expected} <- @validation_sub_tests do
        {:error, error} = Browser.new_context(browser, context_options)
        assert error.message =~ expected
      end
    end

    test "CC-014 should keep supporting http", %{browser: browser, server: server, asset: asset} do
      page = Browser.new_page!(browser, client_certificates: [trusted(asset, origin(server.prefix))])
      Page.goto!(page, server.prefix <> "/one-style.html")
      Expect.to_be_visible!(Page.get_by_text(page, "hello, world!"))
      Expect.to_have_css!(Page.locator(page, "body"), "background-color", "rgb(255, 192, 203)")
      Page.close!(page)
    end

    test "CC-015 should pass through to non-matching origin with self-signed cert",
         %{browser: browser, asset: asset, https_server: https_server} do
      TestServer.set_route(https_server, "/hello.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.send_resp(200, ~s(<html><body><div data-testid="message">hello</div></body></html>))
      end)

      page = Browser.new_page!(browser, client_certificates: [trusted(asset, "https://not-matching.com")])
      Page.goto!(page, https_server.prefix <> "/hello.html")
      Expect.to_have_text!(Page.get_by_test_id(page, "message"), "hello")
      Page.close!(page)
    end

    test "CC-016 should not intercept TLS for origins without a client certificate",
         %{browser: browser, asset: asset, https_server: https_server} do
      # If the proxy intercepted this origin, the browser would see its self-signed cert (CN=localhost)
      # instead of the real server cert (CN=playwright-test).
      page = Browser.new_page!(browser, client_certificates: [trusted(asset, "https://not-matching.com")])
      response = Page.goto!(page, https_server.empty_page)
      assert Response.ok(response) == true
      security_details = Response.security_details!(response)
      assert security_details.subjectName =~ "playwright-test"
      Page.close!(page)
    end

    test "CC-017 should fail with no client certificates",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [trusted(asset, "https://not-matching.com")]
        )

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Sorry, but you need to provide a client certificate to continue."
      )

      Page.close!(page)
    end

    test "CC-018 should fail with self-signed client certificates",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [self_signed(asset, origin(server_url))]
        )

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Sorry Bob, certificates from Bob are not welcome here."
      )

      Page.close!(page)
    end

    test "CC-019 should complete browser TLS handshake when server rejects client certificate after it",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(reject_unauthorized: true, use_fake_localhost: fake_localhost?(browser_name))

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [self_signed(asset, origin(server_url))]
        )

      case Page.goto(page, server_url) do
        {:error, error} ->
          # The server closed the connection with FIN after the TLS handshake.
          assert error.message =~
                   ~r/net::ERR_EMPTY_RESPONSE|NS_ERROR_NET_RESET|Connection terminated unexpectedly|The network connection was lost/

        {:ok, result} ->
          # The server reset the connection, which the proxy reports as a client certificate error.
          assert Response.status(result) == 503
          Expect.to_be_visible!(Page.get_by_text(page, "Playwright client-certificate error"))
      end

      Page.close!(page)
    end

    test "CC-020 should pass with matching certificates",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      page =
        Browser.new_page!(browser, ignore_https_errors: true, client_certificates: [trusted(asset, origin(server_url))])

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
    end

    test "CC-021 should pass with matching certificates when passing as content",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: origin(server_url),
              cert: File.read!(asset.("client-certificates/client/trusted/cert.pem")),
              key: File.read!(asset.("client-certificates/client/trusted/key.pem"))
            }
          ]
        )

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
    end

    test "CC-022 should pass with matching certificates and when a http proxy is used", %{
      browser: browser,
      start_cc_server: start_cc_server,
      asset: asset,
      browser_name: browser_name,
      proxy_server: proxy_server
    } do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))
      TestProxy.forward_to(proxy_server, URI.parse(server_url).port, allow_connect_requests: true)

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [trusted(asset, origin(server_url))],
          proxy: %{server: "localhost:#{proxy_server.port}"}
        )

      assert TestProxy.connect_hosts(proxy_server) == []
      Page.goto!(page, server_url)
      host = if fake_localhost?(browser_name), do: "localhost", else: "127.0.0.1"
      assert Enum.uniq(TestProxy.connect_hosts(proxy_server)) == ["#{host}:#{URI.parse(server_url).port}"]

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
    end

    test "CC-023 should pass with matching certificates and when a http proxy is used from env", %{
      start_cc_server: start_cc_server,
      asset: asset,
      browser_name: browser_name,
      proxy_server: proxy_server
    } do
      # deviation: test.skip(mode !== 'default'), process.env.HTTPS_PROXY = ...: the driver is
      # another process, so a driver of its own started with HTTPS_PROXY (playwright-python's way).
      # Its browser gets our environment, like upstream's `browser`, launched before the test set it.
      name = :client_certificates_https_proxy_from_env

      playwright = start_playwright(name, [{"HTTPS_PROXY", "http://localhost:#{proxy_server.port}"}])
      browser = BrowserType.launch!(PlaywrightEx.TestBrowser.browser_type(playwright), env: System.get_env())

      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))
      TestProxy.forward_to(proxy_server, URI.parse(server_url).port, allow_connect_requests: true)

      page =
        Browser.new_page!(browser, ignore_https_errors: true, client_certificates: [trusted(asset, origin(server_url))])

      assert TestProxy.connect_hosts(proxy_server) == []
      Page.goto!(page, server_url)
      host = if fake_localhost?(browser_name), do: "localhost", else: "127.0.0.1"
      assert Enum.uniq(TestProxy.connect_hosts(proxy_server)) == ["#{host}:#{URI.parse(server_url).port}"]

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
      Browser.close!(browser)
    end

    test "CC-024 should pass with matching certificates and when a http proxy is used from config but env is there", %{
      start_cc_server: start_cc_server,
      asset: asset,
      browser_name: browser_name,
      proxy_server: proxy_server
    } do
      # deviation: process.env.HTTPS_PROXY = ...: a driver of its own started with it, as in the
      # test above.
      name = :client_certificates_https_proxy_config_and_env

      playwright =
        start_playwright(name, [{"HTTPS_PROXY", "http://this-should-not-taken-into-account:4242"}])

      browser = BrowserType.launch!(PlaywrightEx.TestBrowser.browser_type(playwright), env: System.get_env())

      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))
      TestProxy.forward_to(proxy_server, URI.parse(server_url).port, allow_connect_requests: true)

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [trusted(asset, origin(server_url))],
          proxy: %{server: "localhost:#{proxy_server.port}"}
        )

      assert TestProxy.connect_hosts(proxy_server) == []
      Page.goto!(page, server_url)
      host = if fake_localhost?(browser_name), do: "localhost", else: "127.0.0.1"
      assert Enum.uniq(TestProxy.connect_hosts(proxy_server)) == ["#{host}:#{URI.parse(server_url).port}"]

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
      Browser.close!(browser)
    end

    test "CC-025 should respect launch proxy and proxy bypass", %{
      browser_type: browser_type,
      start_cc_server: start_cc_server,
      asset: asset,
      browser_name: browser_name,
      proxy_server: proxy_server
    } do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))
      %URI{host: hostname, port: port} = URI.parse(server_url)
      TestProxy.forward_to(proxy_server, port, allow_connect_requests: true)
      proxy = %{server: "localhost:#{proxy_server.port}"}
      server_host = "#{if fake_localhost?(browser_name), do: "localhost", else: "127.0.0.1"}:#{port}"
      client_certificates = [trusted(asset, origin(server_url))]
      browser = BrowserType.launch!(browser_type, proxy: proxy)

      page = Browser.new_page!(browser, ignore_https_errors: true, client_certificates: client_certificates)
      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      # Headed Chromium also sends its own background requests through the launch proxy.
      assert server_host in TestProxy.connect_hosts(proxy_server)
      Page.close!(page)

      TestProxy.clear_connect_hosts(proxy_server)

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: client_certificates,
          proxy: Map.put(proxy, :bypass, hostname)
        )

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      refute server_host in TestProxy.connect_hosts(proxy_server)
      Page.close!(page)

      Browser.close!(browser)
    end

    test "CC-026 should pass with matching certificates and when a socks proxy is used",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))
      server_port = URI.parse(server_url).port

      %{proxy_server_addr: proxy_server_addr, close_proxy_server: close_proxy_server, connect_hosts: connect_hosts} =
        TestProxy.setup_socks_forwarding_server(port: 0, forward_port: server_port, allowed_target_port: server_port)

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [trusted(asset, origin(server_url))],
          proxy: %{server: proxy_server_addr}
        )

      assert connect_hosts.() == []
      Page.goto!(page, server_url)
      host = if fake_localhost?(browser_name), do: "localhost", else: "127.0.0.1"
      assert connect_hosts.() == ["#{host}:#{server_port}"]

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
      close_proxy_server.()
    end

    test "CC-027 should not hang on tls errors during TLS 1.2 handshake",
         %{browser: browser, asset: asset, browser_name: browser_name} do
      for _tls_version <- ["TLSv1.3", "TLSv1.2"] do
        # test.step(`TLS version: ${tlsVersion}`)
        # deviation: tls.createServer({ ..., minVersion/maxVersion: tlsVersion, SNICallback: (servername,
        # cb) => cb(new Error('Connection rejected')) }): Node destroys the socket on the ClientHello,
        # before any version is agreed; here a TCP server closes it after reading it, the same bytes
        # on the wire for both versions (an `:ssl` server would send an alert instead).
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listen)

        task =
          Task.async(fn ->
            Stream.repeatedly(fn ->
              with {:ok, socket} <- :gen_tcp.accept(listen) do
                :gen_tcp.recv(socket, 0, 5000)
                :gen_tcp.close(socket)
              end
            end)
            |> Enum.find(&match?({:error, _}, &1))
          end)

        host = if fake_localhost?(browser_name), do: "local.playwright", else: "localhost"
        server_url = "https://#{host}:#{port}/"

        page =
          Browser.new_page!(browser,
            ignore_https_errors: true,
            client_certificates: [self_signed(asset, origin(server_url))]
          )

        Page.goto!(page, server_url)

        Expect.to_be_visible!(
          Page.get_by_text(
            page,
            "Playwright client-certificate error: Client network socket disconnected before secure TLS connection was established"
          )
        )

        Page.close!(page)
        :gen_tcp.close(listen)
        Task.await(task, :infinity)
      end
    end

    test "CC-028 should pass with matching certificates in pfx format",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: origin(server_url),
              pfxPath: asset.("client-certificates/client/trusted/cert.pfx"),
              passphrase: "secure"
            }
          ]
        )

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
    end

    test "CC-029 should handle TLS renegotiation with client certificates",
         %{browser: browser, asset: asset, browser_name: browser_name} do
      # deviation: createHttpsServer(...) and its request handler run in a Node.js process
      # (test/support/tls_renegotiation_server.js, upstream's code): Erlang's :ssl cannot ask
      # for a client certificate in a renegotiation.
      port = start_tls_renegotiation_server()
      host = if fake_localhost?(browser_name), do: "local.playwright", else: "localhost"
      server_url = "https://#{host}:#{port}"

      context =
        Browser.new_context!(browser,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: server_url,
              certPath: asset.("client-certificates/client/trusted/cert.pem"),
              keyPath: asset.("client-certificates/client/trusted/key.pem")
            }
          ]
        )

      page = BrowserContext.new_page!(context)

      # test.step('fetch API')
      Page.goto!(page, server_url)

      response =
        Page.evaluate!(page, """
        async () => {
          const response = await fetch('/from-fetch-api', {
            method: 'POST',
            body: 'client-request-payload'
          });
          return await response.text();
        }
        """)

      assert response ==
               Enum.join(
                 [
                   "server received: client-request-payload",
                   "0-from-server",
                   "1-from-server",
                   "2-from-server",
                   "3-from-server",
                   "server closed the connection"
                 ],
                 "\n"
               )

      # test.step('Gzip encoded CSS Stylesheet')
      Page.goto!(page, server_url)
      # The <link> would throw with net::ERR_INVALID_CHUNKED_ENCODING
      Page.set_content!(page, """
      <button>Click me</button>
      <link rel="stylesheet" href="/style.css">
      """)

      # red
      Expect.to_have_css!(Page.locator(page, "button"), "background-color", "rgb(255, 0, 0)")

      BrowserContext.close!(context)
      # await new Promise<void>(resolve => server.close(() => resolve()));  -- the process stops after the test
    end

    test "CC-030 should pass with matching certificates in pfx format when passing as content",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: origin(server_url),
              pfx: File.read!(asset.("client-certificates/client/trusted/cert.pfx")),
              passphrase: "secure"
            }
          ]
        )

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Page.close!(page)
    end

    test "CC-031 should fail with matching certificates in legacy pfx format",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      {:error, error} =
        Browser.new_page(browser,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: origin(server_url),
              pfxPath: asset.("client-certificates/client/trusted/cert-legacy.pfx"),
              passphrase: "secure"
            }
          ]
        )

      assert error.message =~ "Unsupported TLS certificate"
    end

    test "CC-032 should throw a http error if the pfx passphrase is incorect",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      {:error, error} =
        Browser.new_page(browser,
          ignore_https_errors: true,
          client_certificates: [
            %{
              origin: origin(server_url),
              pfxPath: asset.("client-certificates/client/trusted/cert.pfx"),
              passphrase: "this-password-is-incorrect"
            }
          ]
        )

      assert error.message =~ "Failed to load client certificate: mac verify failure"
    end

    test "CC-033 should pass with matching certificates on context APIRequestContext instance",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.([])

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [
            trusted(asset, origin(server_url)),
            trusted(asset, String.replace(origin(server_url), "localhost", "127.0.0.1"))
          ]
        )

      for url <- [server_url, String.replace(server_url, "localhost", "127.0.0.1")] do
        response = APIRequestContext.get!(Page.request(page), url)
        assert APIResponse.status(response) == 200
        assert APIResponse.text!(response) =~ "Hello Alice, your certificate was issued by localhost!"
      end

      Page.close!(page)
    end

    test "CC-034 should pass with matching certificates and trailing slash",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset, browser_name: browser_name} do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      page =
        Browser.new_page!(browser, ignore_https_errors: true, client_certificates: [trusted(asset, server_url)])

      Page.goto!(page, server_url)
      Expect.to_be_visible!(Page.get_by_text(page, "Hello Alice, your certificate was issued by localhost!"))
      Page.close!(page)
    end

    test "CC-035 should have ignoreHTTPSErrors=false by default",
         %{browser: browser, https_server: https_server, asset: asset, browser_name: browser_name} do
      target_url =
        if fake_localhost?(browser_name),
          do: String.replace(https_server.empty_page, "localhost", "local.playwright"),
          else: https_server.empty_page

      page = Browser.new_page!(browser, client_certificates: [trusted(asset, origin(target_url))])
      Page.goto!(page, target_url)
      Expect.to_be_visible!(Page.get_by_text(page, "Playwright client-certificate error: self-signed certificate"))
      Page.close!(page)
    end

    @tag skip:
           if(@browser_name == "webkit" and match?({:unix, :darwin}, :os.type()),
             do: "upstream skip: WebKit on macOS does not proxy localhost"
           )
    test "CC-036 support http2", %{
      browser: browser,
      start_cc_server: start_cc_server,
      asset: asset
    } do
      server_url = start_cc_server.(http2: true)

      page =
        Browser.new_page!(browser,
          ignore_https_errors: true,
          client_certificates: [trusted(asset, origin(server_url))]
        )

      Page.goto!(page, String.replace(server_url, "127.0.0.1", "local.playwright"))

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Sorry, but you need to provide a client certificate to continue."
      )

      Expect.to_have_text!(Page.get_by_test_id(page, "alpn-protocol"), "h2")
      Expect.to_have_text!(Page.get_by_test_id(page, "servername"), "local.playwright")

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Expect.to_have_text!(Page.get_by_test_id(page, "alpn-protocol"), "h2")
      Page.close!(page)
    end

    @tag skip: if(System.get_env("BROWSER", "chromium") != "chromium", do: "upstream skip: browserName !== 'chromium'")
    test "CC-037 support http2 if the browser only supports http1.1",
         %{browser_type: browser_type, start_cc_server: start_cc_server, asset: asset} do
      server_url = start_cc_server.(http2: true, enable_http1_fallback_when_using_http2: true)
      browser = BrowserType.launch!(browser_type, args: ["--disable-http2"])

      page =
        Browser.new_page!(browser, ignore_https_errors: true, client_certificates: [trusted(asset, origin(server_url))])

      Page.goto!(page, String.replace(server_url, "127.0.0.1", "local.playwright"))

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Sorry, but you need to provide a client certificate to continue."
      )

      Expect.to_have_text!(Page.get_by_test_id(page, "alpn-protocol"), "http/1.1")

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )

      Expect.to_have_text!(Page.get_by_test_id(page, "alpn-protocol"), "http/1.1")
      Browser.close!(browser)
    end

    @tag skip:
           if(@browser_name == "webkit" and match?({:unix, :darwin}, :os.type()),
             do: "upstream skip: WebKit on macOS does not proxy localhost"
           )
    test "CC-038 should return target connection errors when using http2",
         %{browser: browser, start_cc_server: start_cc_server, asset: asset} do
      # test.skip(nodeVersion.major < 20, ...)  -- the driver's Node is newer
      server_url = start_cc_server.(http2: true)
      page = Browser.new_page!(browser, client_certificates: [trusted(asset, origin(server_url))])
      Page.goto!(page, server_url)
      Expect.to_be_visible!(Page.get_by_text(page, "Playwright client-certificate error: self-signed certificate"))
      Page.close!(page)
    end

    test "CC-039 should handle rejected certificate in handshake with HTTP/2",
         %{browser: browser, asset: asset, browser_name: browser_name} do
      cert = asset.("client-certificates/server/server_cert.pem")

      server =
        start_supervised!(
          {Bandit,
           plug:
             {PlaywrightEx.Library.ClientCertificatesTest.Respond,
              status: 200, headers: [{"content-type", "text/html"}], body: "Hello world"},
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           http_1_options: [enabled: false],
           thousand_island_options: [
             transport_options: [
               # TLS alerts are expected here (Node logs none).
               log_level: :warning,
               keyfile: asset.("client-certificates/server/server_key.pem"),
               certfile: cert,
               cacertfile: cert,
               verify: :verify_peer,
               fail_if_no_peer_cert: true
             ]
           ]},
          id: :http2_server
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      server_url = "https://#{if fake_localhost?(browser_name), do: "local.playwright", else: "localhost"}:#{port}"

      context =
        Browser.new_context!(browser,
          ignore_https_errors: true,
          client_certificates: [
            trusted(asset, "https://just-there-that-the-client-certificates-proxy-server-is-getting-launched.com")
          ]
        )

      page = BrowserContext.new_page!(context)

      # This was triggering an unhandled error before.
      Page.goto(page, server_url)

      BrowserContext.close!(context)
    end
  end

  describe "browser persistentContext" do
    # test.slow()
    @tag timeout: @slow_timeout
    test "CC-040 validate input", %{browser_type: browser_type, create_user_data_dir: create_user_data_dir} do
      for {context_options, expected} <- @validation_sub_tests do
        {:error, error} = BrowserType.launch_persistent_context(browser_type, create_user_data_dir.(), context_options)
        assert error.message =~ expected
      end
    end

    test "CC-041 should pass with matching certificates",
         %{
           launch_persistent: launch_persistent,
           start_cc_server: start_cc_server,
           asset: asset,
           browser_name: browser_name
         } do
      server_url = start_cc_server.(use_fake_localhost: fake_localhost?(browser_name))

      %{page: page} =
        launch_persistent.(ignore_https_errors: true, client_certificates: [trusted(asset, origin(server_url))])

      Page.goto!(page, server_url)

      Expect.to_have_text!(
        Page.get_by_test_id(page, "message"),
        "Hello Alice, your certificate was issued by localhost!"
      )
    end
  end
end
