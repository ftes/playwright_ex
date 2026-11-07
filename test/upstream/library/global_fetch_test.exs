defmodule PlaywrightEx.Library.GlobalFetchTest do
  @upstream "tests/library/global-fetch.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.TestServer

  # const it = base.extend({ context: ... throw })  -- no `context`/`page` fixture without the `:page` tag
  # it.skip(({ mode }) => mode !== 'default');  -- always the default mode

  defp new_context(playwright, options \\ []), do: APIRequest.new_context!(Playwright.request(playwright), options)

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  # `server.setRoute(path, (req, res) => {})`: the request hangs.
  defp hang(_conn), do: Process.sleep(:infinity)

  # `req => req.socket.on('close', resolve)`: no response; the read returns when the client
  # closes the connection.
  defp notify_on_close(%Plug.Conn{adapter: {Bandit.Adapter, adapter}} = conn, pid) do
    ThousandIsland.Socket.recv(adapter.transport.socket, 0, 30_000)
    send(pid, :connection_closed)
    ThousandIsland.Socket.close(adapter.transport.socket)
    Process.exit(self(), :kill)
    conn
  end

  # Node's `req.socket` tricks (`destroy`, `resetAndDestroy`, `rawHeaders`, not reading the
  # body) have no Plug counterpart: a raw TCP server on 127.0.0.1 calls
  # `handler.(socket, head)` for each connection, in turn, with the request head read.
  defp raw_server(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    start_supervised!({Task, fn -> accept_loop(listen, handler) end}, id: :raw_server)
    port
  end

  defp accept_loop(listen, handler) do
    {:ok, socket} = :gen_tcp.accept(listen)
    handler.(socket, read_head(socket, ""))
    accept_loop(listen, handler)
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5000) do
        {:ok, data} -> read_head(socket, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  # `os.arch()`
  defp node_arch do
    case :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd() do
      "aarch64" -> "arm64"
      "x86_64" -> "x64"
      arch -> arch
    end
  end

  for method <- ~w(fetch delete get head patch post put) do
    @method method
    test "FE-001 #{method} should work @smoke", %{playwright: playwright, server: server} do
      request = new_context(playwright)
      response = apply(APIRequestContext, :"#{@method}!", [request, server.prefix <> "/simple.json"])
      assert APIResponse.url(response) == server.prefix <> "/simple.json"
      assert APIResponse.status(response) == 200
      assert APIResponse.status_text(response) == "OK"
      assert APIResponse.ok(response)
      assert APIResponse.headers(response)["content-type"] == "application/json; charset=utf-8"
      # Plug lowercases response header names (upstream: `Content-Type`).
      assert %{name: "content-type", value: "application/json; charset=utf-8"} in APIResponse.headers_array(response)
      assert APIResponse.text!(response) == if("head" == @method, do: "", else: ~s({"foo": "bar"}\n))
      APIRequestContext.dispose!(request)
    end
  end

  test "FE-002 should dispose global request", %{playwright: playwright, server: server} do
    request = new_context(playwright)
    response = APIRequestContext.get!(request, server.prefix <> "/simple.json")
    assert APIResponse.json!(response) == %{"foo" => "bar"}
    APIRequestContext.dispose!(request)
    {:error, error} = APIResponse.body(response)
    assert Exception.message(error) =~ "Response has been disposed"
    APIRequestContext.dispose!(request)
  end

  test "FE-003 should support global userAgent option", %{playwright: playwright, server: server} do
    request = new_context(playwright, user_agent: "My Agent")
    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task, :infinity)
    assert APIResponse.ok(response)
    assert APIResponse.url(response) == server.empty_page
    assert header(server_request, "user-agent") == "My Agent"
    APIRequestContext.dispose!(request)
  end

  test "FE-004 should support global timeout option", %{playwright: playwright, server: server} do
    request = new_context(playwright, timeout: 100)
    TestServer.set_route(server, "/empty.html", &hang/1)
    {:error, error} = APIRequestContext.get(request, server.empty_page)
    assert Exception.message(error) =~ "apiRequestContext.get: Timeout 100ms exceeded"
    APIRequestContext.dispose!(request)
  end

  test "FE-005 should propagate extra http headers with redirects", %{playwright: playwright, server: server} do
    TestServer.set_redirect(server, "/a/redirect1", "/b/c/redirect2")
    TestServer.set_redirect(server, "/b/c/redirect2", "/simple.json")
    request = new_context(playwright, extra_http_headers: %{"My-Secret" => "Value"})
    task1 = TestServer.wait_for_request(server, "/a/redirect1")
    task2 = TestServer.wait_for_request(server, "/b/c/redirect2")
    task3 = TestServer.wait_for_request(server, "/simple.json")
    APIRequestContext.get!(request, "#{server.prefix}/a/redirect1")
    [req1, req2, req3] = Task.await_many([task1, task2, task3], :infinity)
    assert header(req1, "my-secret") == "Value"
    assert header(req2, "my-secret") == "Value"
    assert header(req3, "my-secret") == "Value"
    APIRequestContext.dispose!(request)
  end

  test "FE-006 should preserve authorization on same-origin redirect but strip on cross-origin",
       %{playwright: playwright, server: server} do
    TestServer.set_redirect(server, "/same/redirect", "/same/dest")
    TestServer.set_redirect(server, "/cross/redirect", server.cross_process_prefix <> "/cross/dest")
    request = new_context(playwright, extra_http_headers: %{"Authorization" => "Bearer secret"})

    task = TestServer.wait_for_request(server, "/same/dest")
    APIRequestContext.get!(request, "#{server.prefix}/same/redirect")
    same_dest_req = Task.await(task, :infinity)
    assert header(same_dest_req, "authorization") == "Bearer secret"

    task = TestServer.wait_for_request(server, "/cross/dest")
    APIRequestContext.get!(request, "#{server.prefix}/cross/redirect")
    cross_dest_req = Task.await(task, :infinity)
    assert header(cross_dest_req, "authorization") == nil

    APIRequestContext.dispose!(request)
  end

  test "FE-007 should support global httpCredentials option", %{playwright: playwright, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    request1 = new_context(playwright)
    response1 = APIRequestContext.get!(request1, server.empty_page)
    assert APIResponse.status(response1) == 401
    APIRequestContext.dispose!(request1)

    request2 = new_context(playwright, http_credentials: %{username: "user", password: "pass"})
    response2 = APIRequestContext.get!(request2, server.empty_page)
    assert APIResponse.status(response2) == 200
    APIRequestContext.dispose!(request2)
  end

  test "FE-008 should return error with wrong credentials", %{playwright: playwright, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    request = new_context(playwright, http_credentials: %{username: "user", password: "wrong"})
    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.status(response) == 401
    APIRequestContext.dispose!(request)
  end

  test "FE-009 should work with correct credentials and matching origin", %{playwright: playwright, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    request = new_context(playwright, http_credentials: %{username: "user", password: "pass", origin: server.prefix})
    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.status(response) == 200
    APIRequestContext.dispose!(request)
  end

  test "FE-010 should work with correct credentials and matching origin case insensitive",
       %{playwright: playwright, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")

    request =
      new_context(playwright,
        http_credentials: %{username: "user", password: "pass", origin: String.upcase(server.prefix)}
      )

    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.status(response) == 200
    APIRequestContext.dispose!(request)
  end

  test "FE-011 should return error with correct credentials and mismatching scheme",
       %{playwright: playwright, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")

    request =
      new_context(playwright,
        http_credentials: %{
          username: "user",
          password: "pass",
          origin: String.replace(server.prefix, "http://", "https://", global: false)
        }
      )

    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.status(response) == 401
    APIRequestContext.dispose!(request)
  end

  test "FE-012 should return error with correct credentials and mismatching hostname",
       %{playwright: playwright, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    hostname = URI.parse(server.prefix).host
    origin = String.replace(server.prefix, hostname, "mismatching-hostname", global: false)
    request = new_context(playwright, http_credentials: %{username: "user", password: "pass", origin: origin})
    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.status(response) == 401
    APIRequestContext.dispose!(request)
  end

  test "FE-013 should return error with correct credentials and mismatching port", %{
    playwright: playwright,
    server: server
  } do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    origin = String.replace(server.prefix, to_string(server.port), to_string(server.port + 1), global: false)
    request = new_context(playwright, http_credentials: %{username: "user", password: "pass", origin: origin})
    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.status(response) == 401
    APIRequestContext.dispose!(request)
  end

  test "FE-014 should support WWW-Authenticate: Basic", %{playwright: playwright, server: server} do
    test_pid = self()

    TestServer.set_route(server, "/empty.html", fn conn ->
      case header(conn, "authorization") do
        nil ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", "Basic")
          |> Plug.Conn.send_resp(401, "HTTP Error 401 Unauthorized: Access is denied")

        authorization ->
          send(test_pid, {:credentials, Base.decode64!(Enum.at(String.split(authorization, " "), 1) || "")})

          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.send_resp(200, "")
      end
    end)

    request = new_context(playwright, http_credentials: %{username: "user", password: "pass"})
    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.status(response) == 200
    assert_receive {:credentials, credentials}
    assert credentials == "user:pass"
    APIRequestContext.dispose!(request)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/30534' }
  test "FE-015 should support HTTPCredentials.send", %{playwright: playwright, server: server} do
    request =
      new_context(playwright,
        http_credentials: %{username: "user", password: "pass", origin: String.upcase(server.prefix), send: "always"}
      )

    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task, :infinity)
    assert header(server_request, "authorization") == "Basic " <> Base.encode64("user:pass")
    assert APIResponse.status(response) == 200

    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(request, server.cross_process_prefix <> "/empty.html")
    server_request = Task.await(task, :infinity)
    # Not sent to another origin.
    assert header(server_request, "authorization") == nil
    assert APIResponse.status(response) == 200

    APIRequestContext.dispose!(request)
  end

  test "FE-016 should support multiple httpCredentials", %{playwright: playwright, server: server} do
    TestServer.set_auth(server, "/empty.html", "user1", "pass1")

    request =
      new_context(playwright,
        http_credentials: [
          %{username: "user1", password: "pass1", origin: server.prefix},
          %{username: "user2", password: "pass2", origin: server.cross_process_prefix}
        ]
      )

    response1 = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.status(response1) == 200
    # Wrong credentials are picked for the other origin.
    response2 = APIRequestContext.get!(request, server.cross_process_prefix <> "/empty.html")
    assert APIResponse.status(response2) == 401
    APIRequestContext.dispose!(request)
  end

  test "FE-017 should support HTTPCredentials.send with multiple httpCredentials", %{
    playwright: playwright,
    server: server
  } do
    request =
      new_context(playwright,
        http_credentials: [
          %{username: "user1", password: "pass1", origin: server.prefix, send: "always"},
          %{username: "user2", password: "pass2", origin: server.cross_process_prefix, send: "unauthorized"}
        ]
      )

    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task, :infinity)
    assert header(server_request, "authorization") == "Basic " <> Base.encode64("user1:pass1")
    assert APIResponse.status(response) == 200

    task = TestServer.wait_for_request(server, "/empty.html")
    response = APIRequestContext.get!(request, server.cross_process_prefix <> "/empty.html")
    server_request = Task.await(task, :infinity)
    # This origin has send: 'unauthorized', so credentials are not sent proactively.
    assert header(server_request, "authorization") == nil
    assert APIResponse.status(response) == 200

    APIRequestContext.dispose!(request)
  end

  test "FE-018 should support global ignoreHTTPSErrors option", %{playwright: playwright, https_server: https_server} do
    request = new_context(playwright, ignore_https_errors: true)
    response = APIRequestContext.get!(request, https_server.empty_page)
    assert APIResponse.status(response) == 200
    APIRequestContext.dispose!(request)
  end

  test "FE-019 should propagate ignoreHTTPSErrors on redirects", %{playwright: playwright, https_server: https_server} do
    TestServer.set_redirect(https_server, "/redir", "/empty.html")
    request = new_context(playwright)
    response = APIRequestContext.get!(request, https_server.prefix <> "/redir", ignore_https_errors: true)
    assert APIResponse.status(response) == 200
    APIRequestContext.dispose!(request)
  end

  test "FE-020 should return server address from response", %{playwright: playwright, server: server} do
    request = new_context(playwright)
    # The second request reuses the keep-alive socket and should report the address as well.
    for _ <- 1..2 do
      response = APIRequestContext.get!(request, server.empty_page)
      addr = APIResponse.server_addr!(response)
      assert addr.ipAddress =~ ~r/^(127\.0\.0\.1|::1)$/
      assert addr.port == server.port
    end

    APIRequestContext.dispose!(request)
  end

  @security_details %{
    issuer: "playwright-test",
    protocol: "TLSv1.3",
    subjectName: "playwright-test",
    validFrom: 1_691_708_270,
    validTo: 2_007_068_270
  }

  test "FE-021 should return security details from response", %{playwright: playwright, https_server: https_server} do
    request = new_context(playwright, ignore_https_errors: true)
    # The second request reuses the keep-alive socket and should report the details as well.
    for _ <- 1..2 do
      response = APIRequestContext.get!(request, https_server.empty_page)
      assert APIResponse.security_details!(response) == @security_details
    end

    APIRequestContext.dispose!(request)
  end

  test "FE-022 should return security details for a resumed TLS session", %{
    playwright: playwright,
    https_server: https_server
  } do
    expected = @security_details
    request = new_context(playwright, ignore_https_errors: true)
    # 'Connection: close' drops the socket, so the next request opens a new one and resumes
    # the cached TLS session. A resumed session does not carry the server certificate.
    first = APIRequestContext.get!(request, https_server.empty_page, headers: %{"connection" => "close"})
    assert APIResponse.security_details!(first) == expected
    second = APIRequestContext.get!(request, https_server.empty_page)
    assert APIResponse.security_details!(second) == expected
    APIRequestContext.dispose!(request)
  end

  test "FE-023 should return null security details for http response", %{playwright: playwright, server: server} do
    request = new_context(playwright)
    response = APIRequestContext.get!(request, server.empty_page)
    assert APIResponse.security_details!(response) == nil
    APIRequestContext.dispose!(request)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/41815' }
  test "FE-024 should return security details for certificate with multiple CN attributes",
       %{playwright: playwright, asset: asset} do
    # utils.createHttpsServer(...); server.listen(0, '127.0.0.1')  -- a TestServer with that certificate
    ssl_options = [
      keyfile: to_charlist(asset.("multi-value-rdn/key.pem")),
      certfile: to_charlist(asset.("multi-value-rdn/cert.pem"))
    ]

    server =
      TestServer.server(
        start_supervised!({TestServer, dir_path: asset.("."), ssl_options: ssl_options}, id: :multi_value_rdn)
      )

    TestServer.set_route(server, "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(%{ok: true}))
    end)

    request = new_context(playwright, ignore_https_errors: true)
    response = APIRequestContext.get!(request, "https://localhost:#{server.port}/")
    assert APIResponse.status(response) == 200
    security_details = APIResponse.security_details!(response)
    assert security_details.subjectName == "localhost"
    assert security_details.issuer == "localhost"
    APIRequestContext.dispose!(request)
  end

  test "FE-025 should resolve url relative to global baseURL option", %{playwright: playwright, server: server} do
    request = new_context(playwright, base_url: server.prefix)
    response = APIRequestContext.get!(request, "/empty.html")
    assert APIResponse.url(response) == server.empty_page
    APIRequestContext.dispose!(request)
  end

  test "FE-026 should fallback to given URL if baseURL is bogus", %{playwright: playwright, server: server} do
    request = new_context(playwright, base_url: "bogus")
    response = APIRequestContext.get!(request, server.prefix <> "/empty.html")
    assert APIResponse.url(response) == server.empty_page
    APIRequestContext.dispose!(request)
  end

  test "FE-027 should set playwright as user-agent", %{playwright: playwright, server: server} do
    request = new_context(playwright)
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task, :infinity)

    user_agent_masked =
      server_request
      |> header("user-agent")
      |> String.replace(node_arch(), "<ARCH>", global: false)
      |> String.replace(PlaywrightEx.Driver.version(), "X.X.X", global: false)
      |> String.replace(~r/\d+/, "X")

    tokens = if System.get_env("CI") in [nil, ""], do: [], else: ["CI/X"]
    suffix = if tokens != [], do: " #{Enum.join(tokens, " ")}", else: ""
    # The driver runs with PW_LANG_NAME=elixir, which getEmbedderName() does not know (upstream: node/X.X).
    embedder = "unknown/unknown"

    case :os.type() do
      {:win32, _} ->
        assert user_agent_masked == "Playwright/X.X.X (<ARCH>; windows X.X) #{embedder}" <> suffix

      {:unix, :linux} ->
        # on ubuntu: distro is 'ubuntu' and version is 'X.X'
        # on manjaro: distro is 'Manjaro' and version is 'unknown'
        assert String.replace(user_agent_masked, ~r/<ARCH>; \w+ [^)]+/, "<ARCH>; distro version", global: false) ==
                 "Playwright/X.X.X (<ARCH>; distro version) #{embedder}" <> suffix

      {:unix, :darwin} ->
        assert user_agent_masked == "Playwright/X.X.X (<ARCH>; macOS X.X) #{embedder}" <> suffix
    end

    APIRequestContext.dispose!(request)
  end

  test "FE-028 should be able to construct with context options"

  test "FE-029 should return empty body", %{playwright: playwright, server: server} do
    request = new_context(playwright)
    response = APIRequestContext.get!(request, server.empty_page)
    body = APIResponse.body!(response)
    assert byte_size(body) == 0
    assert APIResponse.text!(response) == ""
    APIRequestContext.dispose!(request)
  end

  test "FE-030 should abort requests when context is disposed", %{playwright: playwright, server: server} do
    test_pid = self()
    TestServer.set_route(server, "/empty.html", &notify_on_close(&1, test_pid))
    request = new_context(playwright)
    wait = TestServer.wait_for_request(server, "/empty.html")

    tasks = [
      Task.async(fn -> APIRequestContext.get(request, server.empty_page) end),
      Task.async(fn -> APIRequestContext.post(request, server.empty_page) end),
      Task.async(fn -> APIRequestContext.delete(request, server.empty_page) end)
    ]

    Task.await(wait, :infinity)
    APIRequestContext.dispose!(request)

    for result <- Task.await_many(tasks, :infinity) do
      assert {:error, error} = result
      assert Exception.message(error) =~ "Request context disposed."
    end

    assert_receive :connection_closed, 5000
    APIRequestContext.dispose!(request)
  end

  test "FE-031 should abort redirected requests when context is disposed", %{playwright: playwright, server: server} do
    TestServer.set_redirect(server, "/redirect", "/test")
    test_pid = self()
    TestServer.set_route(server, "/test", &notify_on_close(&1, test_pid))
    request = new_context(playwright)
    wait = TestServer.wait_for_request(server, "/test")
    task = Task.async(fn -> APIRequestContext.get(request, server.prefix <> "/redirect") end)
    Task.await(wait, :infinity)
    APIRequestContext.dispose!(request)
    assert {:error, result} = Task.await(task, :infinity)
    assert Exception.message(result) =~ ~r/Request context disposed|Target page, context or browser has been closed/
    assert_receive :connection_closed, 5000
    APIRequestContext.dispose!(request)
  end

  test "FE-032 should remove content-length from redirected post requests", %{playwright: playwright, server: server} do
    TestServer.set_redirect(server, "/redirect", "/empty.html")
    request = new_context(playwright)
    task1 = TestServer.wait_for_request(server, "/redirect")
    task2 = TestServer.wait_for_request(server, "/empty.html")
    result = APIRequestContext.post!(request, server.prefix <> "/redirect", data: %{"foo" => "bar"})
    [req1, req2] = Task.await_many([task1, task2], :infinity)
    assert APIResponse.status(result) == 200
    assert header(req1, "content-length") == "13"
    assert header(req2, "content-length") == nil
    APIRequestContext.dispose!(request)
  end

  # JS `null` is `:null`.
  serialization = [
    {"object", %{"foo" => "bar"}},
    {"array", ["foo", "bar", 2021]},
    {"string", "foo"},
    {"string (falsey)", ""},
    {"bool", true},
    {"bool (false)", false},
    {"number", 2021},
    {"number (falsey)", 0},
    {"null", :null},
    {"literal string undefined", "undefined"}
  ]

  for {type, value} <- serialization do
    @value value
    # JSON.stringify(value)
    @stringified_value if(value == :null, do: "null", else: JSON.encode!(value))
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43388' }
    test "FE-033 should json stringify #{type} body when content-type is application/json",
         %{playwright: playwright, server: server} do
      request = new_context(playwright)

      for content_type <- ["application/json", "Application/JSON; charset=utf-8"] do
        task = TestServer.wait_for_request(server, "/empty.html")

        APIRequestContext.post!(request, server.empty_page,
          headers: %{"content-type" => content_type},
          data: @value
        )

        req = Task.await(task, :infinity)
        body = req.assigns.post_body
        assert body == @stringified_value
      end

      APIRequestContext.dispose!(request)
    end

    test "FE-034 should not double stringify #{type} body when content-type is application/json",
         %{playwright: playwright, server: server} do
      request = new_context(playwright)
      task = TestServer.wait_for_request(server, "/empty.html")

      APIRequestContext.post!(request, server.empty_page,
        headers: %{"content-type" => "application/json"},
        data: @stringified_value
      )

      req = Task.await(task, :infinity)
      body = req.assigns.post_body
      assert body == @stringified_value
      APIRequestContext.dispose!(request)
    end
  end

  test "FE-035 should accept already serialized data as Buffer when content-type is application/json",
       %{playwright: playwright, server: server} do
    request = new_context(playwright)
    value = JSON.encode!(JSON.encode!(%{"foo" => "bar"}))
    task = TestServer.wait_for_request(server, "/empty.html")

    APIRequestContext.post!(request, server.empty_page,
      headers: %{"content-type" => "application/json"},
      data: {:binary, value}
    )

    req = Task.await(task, :infinity)
    body = req.assigns.post_body
    assert body == value
    APIRequestContext.dispose!(request)
  end

  test "FE-036 should have nice toString", %{playwright: playwright, server: server} do
    request = new_context(playwright)

    response =
      APIRequestContext.post!(request, server.empty_page,
        headers: %{"content-type" => "application/json"},
        data: "My post data"
      )

    str = inspect(response)
    assert str =~ "APIResponse: 200 OK"
    for %{name: name, value: value} <- APIResponse.headers_array(response), do: assert(str =~ "  #{name}: #{value}")
    APIRequestContext.dispose!(request)
  end

  test "FE-037 should not fail on empty body with encoding", %{playwright: playwright, server: server} do
    request = new_context(playwright)

    for method <- ["head", "put"], encoding <- ["br", "gzip", "deflate"] do
      TestServer.set_route(server, "/empty.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", encoding)
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        # writeHead + res.end(): chunked, no content-length.
        |> Plug.Conn.send_chunked(200)
      end)

      response = apply(APIRequestContext, :"#{method}!", [request, server.empty_page])
      assert APIResponse.status(response) == 200
      assert byte_size(APIResponse.body!(response)) == 0
    end

    APIRequestContext.dispose!(request)
  end

  test "FE-038 should return body for failing requests", %{playwright: playwright, server: server} do
    request = new_context(playwright)

    for method <- ["head", "put", "trace"] do
      TestServer.set_route(server, "/empty.html", fn conn ->
        # 'Content-Length': 10  -- set by Bandit
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(404, "Not found.")
      end)

      response = APIRequestContext.fetch!(request, server.empty_page, method: method)
      assert APIResponse.status(response) == 404
      # HEAD response returns empty body in node http module.
      assert APIResponse.text!(response) == if(method == "head", do: "", else: "Not found.")
    end

    APIRequestContext.dispose!(request)
  end

  @http_methods ["GET", "PUT", "POST", "OPTIONS", "HEAD", "PATCH"]

  defp set_redirects(server, count) do
    paths = ["/a/redirect1" | for(i <- 2..count//1, do: "/b/c/redirect#{i}")] ++ ["/simple.json"]
    for [from, to] <- Enum.chunk_every(paths, 2, 1, :discard), do: TestServer.set_redirect(server, from, to)
  end

  test "FE-039 should throw an error when maxRedirects is exceeded", %{playwright: playwright, server: server} do
    set_redirects(server, 4)

    request = new_context(playwright)

    for method <- @http_methods, max_redirects <- [1, 2, 3] do
      {:error, error} =
        APIRequestContext.fetch(request, "#{server.prefix}/a/redirect1", method: method, max_redirects: max_redirects)

      assert Exception.message(error) =~ "Max redirect count exceeded"
    end

    APIRequestContext.dispose!(request)
  end

  test "FE-040 should not follow redirects when maxRedirects is set to 0", %{playwright: playwright, server: server} do
    set_redirects(server, 2)

    request = new_context(playwright)

    for method <- @http_methods do
      response = APIRequestContext.fetch!(request, "#{server.prefix}/a/redirect1", method: method, max_redirects: 0)
      assert APIResponse.headers(response)["location"] == "/b/c/redirect2"
      assert APIResponse.status(response) == 302
    end

    APIRequestContext.dispose!(request)
  end

  test "FE-041 should throw an error when maxRedirects is less than 0", %{playwright: playwright, server: server} do
    set_redirects(server, 2)

    request = new_context(playwright)

    for method <- @http_methods do
      {:error, error} =
        APIRequestContext.fetch(request, "#{server.prefix}/a/redirect1", method: method, max_redirects: -1)

      assert Exception.message(error) =~ "'maxRedirects' must be greater than or equal to '0'"
    end

    APIRequestContext.dispose!(request)
  end

  test "FE-042 should not follow redirects when maxRedirects is set to 0 in newContext",
       %{playwright: playwright, server: server} do
    set_redirects(server, 2)

    request = new_context(playwright, max_redirects: 0)

    for method <- @http_methods do
      response = APIRequestContext.fetch!(request, "#{server.prefix}/a/redirect1", method: method)
      assert APIResponse.headers(response)["location"] == "/b/c/redirect2"
      assert APIResponse.status(response) == 302
    end

    APIRequestContext.dispose!(request)
  end

  test "FE-043 should follow redirects up to maxRedirects limit set in newContext", %{
    playwright: playwright,
    server: server
  } do
    set_redirects(server, 4)

    for max_redirects <- [1, 2, 3, 4] do
      request = new_context(playwright, max_redirects: max_redirects)

      for method <- @http_methods do
        if max_redirects < 4 do
          {:error, error} = APIRequestContext.fetch(request, "#{server.prefix}/a/redirect1", method: method)
          assert Exception.message(error) =~ "Max redirect count exceeded"
        else
          response = APIRequestContext.fetch!(request, "#{server.prefix}/a/redirect1", method: method)
          assert APIResponse.status(response) == 200
        end
      end

      APIRequestContext.dispose!(request)
    end
  end

  test "FE-044 should use maxRedirects from fetch when provided, overriding newContext",
       %{playwright: playwright, server: server} do
    set_redirects(server, 4)

    request = new_context(playwright, max_redirects: 1)

    for method <- @http_methods do
      response = APIRequestContext.fetch!(request, "#{server.prefix}/a/redirect1", method: method, max_redirects: 4)
      assert APIResponse.status(response) == 200
    end

    APIRequestContext.dispose!(request)
  end

  test "FE-045 should keep headers capitalization", %{playwright: playwright} do
    # serverRequest.rawHeaders  -- Plug lowercases header names: a raw server reads them.
    test_pid = self()

    port =
      raw_server(fn socket, head ->
        send(test_pid, {:raw_request, head})
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.close(socket)
      end)

    request = new_context(playwright)

    response =
      APIRequestContext.get!(request, "http://127.0.0.1:#{port}/empty.html", headers: %{"X-fOo" => "vaLUE"})

    assert_receive {:raw_request, raw_headers}
    assert APIResponse.ok(response)
    assert raw_headers =~ "X-fOo"
    assert raw_headers =~ "vaLUE"
    APIRequestContext.dispose!(request)
  end

  test "FE-046 should serialize post data on the client"

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/27822' }
  test "FE-047 should throw after dispose", %{playwright: playwright, server: server} do
    request = new_context(playwright)
    APIRequestContext.dispose!(request)
    {:error, error} = APIRequestContext.get(request, server.empty_page)
    assert Exception.message(error) =~ "Target page, context or browser has been closed"
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/30978' }
  test "FE-048 should retry ECONNRESET", %{playwright: playwright} do
    request = new_context(playwright)
    request_count = :counters.new(1, [])

    port =
      raw_server(fn socket, _head ->
        :counters.add(request_count, 1, 1)

        # if (requestCount++ < 3) req.socket.destroy();
        if :counters.get(request_count, 1) <= 3 do
          :gen_tcp.close(socket)
        else
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 6\r\n\r\nHello!")
          :gen_tcp.close(socket)
        end
      end)

    response = APIRequestContext.fetch!(request, "http://127.0.0.1:#{port}/test", max_retries: 3)
    assert APIResponse.status(response) == 200
    assert APIResponse.text!(response) == "Hello!"
    assert :counters.get(request_count, 1) == 4
    APIRequestContext.dispose!(request)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42532' }
  test "FE-049 should expose node error code on network errors", %{playwright: playwright} do
    # Reset the connection so that node reports a system error instead of a plain 'socket hang up'.
    # req.socket.resetAndDestroy()  -- linger 0 makes close send a RST
    port =
      raw_server(fn socket, _head ->
        :inet.setopts(socket, linger: {true, 0})
        :gen_tcp.close(socket)
      end)

    request = new_context(playwright)
    {:error, error} = APIRequestContext.get(request, "http://127.0.0.1:#{port}/reset", max_retries: 0)
    assert Exception.message(error) =~ "ECONNRESET"
    assert error.code == "ECONNRESET"
    assert Map.get(error, :syscall) == nil
    assert Map.get(error, :errno) == nil
    APIRequestContext.dispose!(request)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42532' }
  test "FE-050 should append node error code to the message", %{playwright: playwright} do
    # Node reports this one as a plain 'socket hang up' that does not mention the code.
    port = raw_server(fn socket, _head -> :gen_tcp.close(socket) end)
    request = new_context(playwright)
    {:error, error} = APIRequestContext.get(request, "http://127.0.0.1:#{port}/hangup", max_retries: 0)
    assert Exception.message(error) =~ "socket hang up (ECONNRESET)"
    assert error.code == "ECONNRESET"
    APIRequestContext.dispose!(request)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42074' }
  test "FE-051 should not crash when server refuses body before reading it", %{playwright: playwright} do
    # Respond without reading the body, then reset. Node emits a late write
    # EPIPE/ECONNRESET on the request socket; without a listener that becomes an
    # unhandled 'error' and kills the process.
    port =
      raw_server(fn socket, _head ->
        Process.sleep(50)
        body = JSON.encode!(%{error: "too large"})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 413 Payload Too Large\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"
        )

        :gen_tcp.close(socket)
      end)

    request = new_context(playwright)
    # Large body so the client is still writing when the reset lands.
    # Prefer CROSS_PROCESS_PREFIX (127.0.0.1) over PREFIX (localhost/::1) for a stable race.
    result =
      APIRequestContext.post(request, "http://127.0.0.1:#{port}/refuse",
        data: {:binary, :binary.copy("x", 20 * 1024 * 1024)},
        headers: %{"content-type" => "text/plain"},
        max_retries: 0
      )

    case result do
      {:error, error} ->
        assert Exception.message(error) =~ ~r/apiRequestContext\.post|ECONNRESET|EPIPE|ECONNABORTED|socket/i

      {:ok, response} ->
        assert APIResponse.status(response) == 413
        assert APIResponse.text!(response) == JSON.encode!(%{error: "too large"})
    end

    APIRequestContext.dispose!(request)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/34204' }
  test "FE-052 should throw when failOnStatusCode is set to true inside APIRequest context options",
       %{playwright: playwright, server: server} do
    request = new_context(playwright, fail_on_status_code: true)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(404, "Not found.")
    end)

    {:error, error} = APIRequestContext.fetch(request, server.empty_page)
    assert Exception.message(error) =~ "404 Not Found"
    APIRequestContext.dispose!(request)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/34204' }
  test "FE-053 should not throw when failOnStatusCode is set to false inside APIRequest context options",
       %{playwright: playwright, server: server} do
    request = new_context(playwright, fail_on_status_code: false)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(404, "Not found.")
    end)

    response = APIRequestContext.fetch!(request, server.empty_page)
    assert APIResponse.status(response) == 404
    APIRequestContext.dispose!(request)
  end
end
