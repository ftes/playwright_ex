defmodule PlaywrightEx.Library.BrowsercontextCredentialsTest do
  @upstream "tests/library/browsercontext-credentials.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer

  # base.extend({ failsOn401: browserName === 'chromium' && !isHeadlessShell }):
  # headless chromium is the headless shell.
  setup do
    %{fails_on_401: false}
  end

  # page.goto(url).catch(e => e)
  defp response_or_error(result) do
    case result do
      {:ok, response} -> response
      {:error, error} -> error
    end
  end

  defp assert_fails_on_401(response_or_error, fails_on_401) do
    if fails_on_401,
      do: assert(response_or_error.message =~ "net::ERR_INVALID_AUTH_CREDENTIALS"),
      else: assert(Response.status(response_or_error) == 401)
  end

  test "should fail without credentials", %{browser: browser, server: server, fails_on_401: fails_on_401} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    response_or_error = response_or_error(Page.goto(page, server.empty_page))
    assert_fails_on_401(response_or_error, fails_on_401)
  end

  test "should work with setHTTPCredentials", %{browser: browser, server: server, fails_on_401: fails_on_401} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    response_or_error = response_or_error(Page.goto(page, server.empty_page))
    assert_fails_on_401(response_or_error, fails_on_401)

    BrowserContext.set_http_credentials!(context, %{username: "user", password: "pass"})
    response_or_error = Page.reload!(page)
    assert Response.status(response_or_error) == 200
    BrowserContext.close!(context)
  end

  test "should work with setHTTPCredentials and multiple credentials", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user1", "pass1")
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    BrowserContext.set_http_credentials!(context, [
      %{username: "user1", password: "pass1", origin: server.prefix},
      %{username: "user2", password: "pass2", origin: server.cross_process_prefix}
    ])

    response1 = Page.goto!(page, server.empty_page)
    assert Response.status(response1) == 200
    # Wrong credentials are picked for the other origin.
    response2 = Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert Response.status(response2) == 401
    BrowserContext.close!(context)
  end

  test "should work with correct credentials @smoke", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    context = Browser.new_context!(browser, http_credentials: %{username: "user", password: "pass"})
    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    BrowserContext.close!(context)
  end

  test "should fail with wrong credentials", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    context = Browser.new_context!(browser, http_credentials: %{username: "foo", password: "bar"})
    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 401
    BrowserContext.close!(context)
  end

  test "should return resource body", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/playground.html", "user", "pass")
    context = Browser.new_context!(browser, http_credentials: %{username: "user", password: "pass"})
    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.prefix <> "/playground.html")
    assert Response.status(response) == 200
    assert Page.title!(page) == "Playground"
    assert Response.body!(response) =~ "Playground"
    BrowserContext.close!(context)
  end

  test "should work with a single credential in an array", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    context = Browser.new_context!(browser, http_credentials: [%{username: "user", password: "pass"}])
    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    BrowserContext.close!(context)
  end

  test "should work with multiple credentials for different origins", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user1", "pass1")

    context =
      Browser.new_context!(browser,
        http_credentials: [
          %{username: "user1", password: "pass1", origin: server.prefix},
          %{username: "user2", password: "pass2", origin: server.cross_process_prefix}
        ]
      )

    page = BrowserContext.new_page!(context)
    response1 = Page.goto!(page, server.empty_page)
    assert Response.status(response1) == 200
    # Wrong credentials are picked for the other origin.
    response2 = Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert Response.status(response2) == 401
    BrowserContext.close!(context)
  end

  test "should fall back to credentials without origin", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")

    context =
      Browser.new_context!(browser,
        http_credentials: [
          %{username: "user2", password: "pass2", origin: server.cross_process_prefix},
          %{username: "user", password: "pass"}
        ]
      )

    page = BrowserContext.new_page!(context)
    response1 = Page.goto!(page, server.empty_page)
    assert Response.status(response1) == 200
    # First matching entry has wrong credentials for this origin.
    response2 = Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert Response.status(response2) == 401
    BrowserContext.close!(context)
  end

  test "should use the first matching credential", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")

    context =
      Browser.new_context!(browser,
        http_credentials: [
          %{username: "wrong", password: "wrong"},
          %{username: "user", password: "pass", origin: server.prefix}
        ]
      )

    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 401
    BrowserContext.close!(context)
  end

  test "should work with correct credentials and matching origin", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")

    context =
      Browser.new_context!(browser, http_credentials: %{username: "user", password: "pass", origin: server.prefix})

    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    BrowserContext.close!(context)
  end

  test "should work with correct credentials and matching origin case insensitive", %{
    browser: browser,
    server: server
  } do
    TestServer.set_auth(server, "/empty.html", "user", "pass")

    context =
      Browser.new_context!(browser,
        http_credentials: %{username: "user", password: "pass", origin: String.upcase(server.prefix)}
      )

    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    BrowserContext.close!(context)
  end

  test "should fail with correct credentials and mismatching scheme", %{
    browser: browser,
    server: server,
    fails_on_401: fails_on_401
  } do
    TestServer.set_auth(server, "/empty.html", "user", "pass")

    context =
      Browser.new_context!(browser,
        http_credentials: %{
          username: "user",
          password: "pass",
          origin: String.replace(server.prefix, "http://", "https://", global: false)
        }
      )

    page = BrowserContext.new_page!(context)
    response_or_error = response_or_error(Page.goto(page, server.empty_page))
    assert_fails_on_401(response_or_error, fails_on_401)
    BrowserContext.close!(context)
  end

  test "should fail with correct credentials and mismatching hostname", %{
    browser: browser,
    server: server,
    fails_on_401: fails_on_401
  } do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    hostname = URI.parse(server.prefix).host
    origin = String.replace(server.prefix, hostname, "mismatching-hostname", global: false)

    context =
      Browser.new_context!(browser, http_credentials: %{username: "user", password: "pass", origin: origin})

    page = BrowserContext.new_page!(context)
    response_or_error = response_or_error(Page.goto(page, server.empty_page))
    assert_fails_on_401(response_or_error, fails_on_401)
    BrowserContext.close!(context)
  end

  test "should fail with correct credentials and mismatching port", %{
    browser: browser,
    server: server,
    fails_on_401: fails_on_401
  } do
    TestServer.set_auth(server, "/empty.html", "user", "pass")
    origin = String.replace(server.prefix, to_string(server.port), to_string(server.port + 1), global: false)

    context =
      Browser.new_context!(browser, http_credentials: %{username: "user", password: "pass", origin: origin})

    page = BrowserContext.new_page!(context)
    response_or_error = response_or_error(Page.goto(page, server.empty_page))
    assert_fails_on_401(response_or_error, fails_on_401)
    BrowserContext.close!(context)
  end

  test "should not override Authorization header set by the page", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/empty.html", "user", "pass")

    TestServer.set_route(server, "/echo-auth", fn conn ->
      body =
        case Plug.Conn.get_req_header(conn, "authorization") do
          [authorization | _] -> authorization
          [] -> "<none>"
        end

      Plug.Conn.send_resp(conn, 200, body)
    end)

    context = Browser.new_context!(browser, http_credentials: %{username: "user", password: "pass"})
    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200

    received =
      Page.evaluate!(page, """
      async () => {
        const response = await fetch('/echo-auth', { headers: { 'Authorization': 'Bearer my-own-app-token' } });
        return await response.text();
      }
      """)

    assert received == "Bearer my-own-app-token"
    BrowserContext.close!(context)
  end
end
