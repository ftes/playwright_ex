defmodule PlaywrightEx.Library.GlobalFetchCookieTest do
  @upstream "tests/library/global-fetch-cookie.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.TestServer

  # The spec overrides the `request` fixture: `playwright.request.newContext({ ignoreHTTPSErrors: true })`.
  @moduletag request: [ignore_https_errors: true]

  # res.setHeader('Set-Cookie', [...]); res.end();
  defp set_cookie(conn, cookies) do
    conn
    |> Plug.Conn.prepend_resp_headers(Enum.map(cookies, &{"set-cookie", &1}))
    |> Plug.Conn.send_resp(200, "")
  end

  # Date.prototype.toUTCString
  defp to_utc_string(date_time), do: Calendar.strftime(date_time, "%a, %d %b %Y %H:%M:%S GMT")

  defp cookie_header(conn), do: conn |> Plug.Conn.get_req_header("cookie") |> List.first()

  defp names(cookies), do: Enum.map(cookies, & &1.name)

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "should store cookie from Set-Cookie header"

  test "addCookies should add cookies to the cookie jar", %{request: request, server: server} do
    APIRequestContext.add_cookies!(request, [
      %{name: "a", value: "b", url: server.empty_page},
      %{name: "c", value: "d", domain: "localhost", path: "/input", httpOnly: true, sameSite: "Strict"},
      %{name: "e", value: "f", domain: "other.com", path: "/"}
    ])

    task = TestServer.wait_for_request(server, "/input/button.html")
    APIRequestContext.get!(request, "#{server.prefix}/input/button.html")
    server_request = Task.await(task)
    assert cookie_header(server_request) == "a=b; c=d"
    state = APIRequestContext.storage_state!(request)

    assert state.cookies == [
             %{
               name: "a",
               value: "b",
               domain: "localhost",
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: false,
               sameSite: "Lax"
             },
             %{
               name: "c",
               value: "d",
               domain: "localhost",
               path: "/input",
               expires: -1,
               httpOnly: true,
               secure: false,
               sameSite: "Strict"
             },
             %{
               name: "e",
               value: "f",
               domain: "other.com",
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: false,
               sameSite: "Lax"
             }
           ]
  end

  test "addCookies should validate cookies", %{request: request} do
    {:error, error} = APIRequestContext.add_cookies(request, [%{name: "a", value: "b"}])
    assert Exception.message(error) =~ "Cookie should have a url or a domain/path pair"
  end

  test "cookies should return cookies filtered by urls", %{request: request, server: server} do
    APIRequestContext.add_cookies!(request, [
      %{name: "a", value: "b", domain: "localhost", path: "/"},
      %{name: "c", value: "d", domain: "localhost", path: "/input"},
      %{name: "e", value: "f", domain: "one.com", path: "/"},
      %{name: "g", value: "h", domain: "two.com", path: "/", secure: true}
    ])

    assert names(APIRequestContext.cookies!(request)) == ["a", "c", "e", "g"]
    assert names(APIRequestContext.cookies!(request, server.empty_page)) == ["a"]
    assert names(APIRequestContext.cookies!(request, "#{server.prefix}/input/button.html")) == ["a", "c"]
    assert names(APIRequestContext.cookies!(request, ["http://sub.one.com/", "http://two.com/"])) == ["e"]
    assert names(APIRequestContext.cookies!(request, ["http://sub.one.com/", "https://two.com/"])) == ["e", "g"]
    assert APIRequestContext.cookies!(request, "http://other.com/") == []
  end

  test "cookies should include cookies from Set-Cookie header", %{request: request, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      set_cookie(conn, ["a=b; HttpOnly; SameSite=Strict", "c=d; path=/input"])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")

    assert APIRequestContext.cookies!(request) == [
             %{
               name: "a",
               value: "b",
               domain: "localhost",
               path: "/",
               expires: -1,
               httpOnly: true,
               secure: false,
               sameSite: "Strict"
             },
             %{
               name: "c",
               value: "d",
               domain: "localhost",
               path: "/input",
               expires: -1,
               httpOnly: false,
               secure: false,
               sameSite: "Lax"
             }
           ]
  end

  test "clearCookies should remove all cookies", %{request: request, server: server} do
    APIRequestContext.add_cookies!(request, [
      %{name: "a", value: "b", url: server.empty_page},
      %{name: "c", value: "d", domain: "one.com", path: "/"}
    ])

    APIRequestContext.clear_cookies!(request)
    assert APIRequestContext.cookies!(request) == []
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)
    assert cookie_header(server_request) == nil
  end

  test "clearCookies should filter by name, domain and path", %{request: request} do
    APIRequestContext.add_cookies!(request, [
      %{name: "session", value: "1", domain: "one.com", path: "/"},
      %{name: "session", value: "2", domain: "two.com", path: "/"},
      %{name: "session", value: "3", domain: "two.com", path: "/api"},
      %{name: "other", value: "4", domain: "one.com", path: "/"}
    ])

    values = fn -> request |> APIRequestContext.cookies!() |> Enum.map(& &1.value) |> Enum.sort() end

    APIRequestContext.clear_cookies!(request, name: "session", domain: "two.com", path: "/api")
    assert values.() == ["1", "2", "4"]

    APIRequestContext.clear_cookies!(request, domain: ~r/one\.com$/)
    assert values.() == ["2"]

    APIRequestContext.clear_cookies!(request, name: ~r/^sess/)
    assert values.() == []
  end

  test "clearCookies should remove nameless cookies by empty name", %{request: request} do
    APIRequestContext.add_cookies!(request, [
      %{name: "", value: "nameless", domain: "one.com", path: "/"},
      %{name: "session", value: "secret", domain: "one.com", path: "/"}
    ])

    APIRequestContext.clear_cookies!(request, name: "")
    assert names(APIRequestContext.cookies!(request)) == ["session"]
  end

  test "should filter outgoing cookies by path", %{request: request, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      set_cookie(conn, ["a=v; path=/input/subfolder", "b=v; path=/input", "c=v;"])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    task = TestServer.wait_for_request(server, "/input/button.html")
    APIRequestContext.get!(request, "#{server.prefix}/input/button.html")
    server_request = Task.await(task)
    assert cookie_header(server_request) == "b=v; c=v"
  end

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "should filter outgoing cookies by domain"

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "should do case-insensitive match of cookie domain"

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "should do case-insensitive match of request domain"

  test "should send secure cookie over https", %{request: request, server: server, https_server: https_server} do
    TestServer.set_route(server, "/setcookie.html", fn conn -> set_cookie(conn, ["a=v; secure", "b=v"]) end)
    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    task = TestServer.wait_for_request(https_server, "/empty.html")
    APIRequestContext.get!(request, https_server.empty_page)
    server_request = Task.await(task)
    assert cookie_header(server_request) == "a=v; b=v"
  end

  test "should send secure cookie over http for localhost", %{request: request, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn -> set_cookie(conn, ["a=v; secure", "b=v"]) end)
    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)
    assert cookie_header(server_request) == "a=v; b=v"
  end

  test "should send secure cookie over http for subdomains of localhost", %{request: request, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn -> set_cookie(conn, ["a=v; secure", "b=v"]) end)
    prefix = "http://a.b.localhost:#{server.port}"
    # { __testHookLookup } as any  -- not ported: in-process test hook; *.localhost resolves to loopback anyway
    APIRequestContext.get!(request, "#{prefix}/setcookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, "#{prefix}/empty.html")
    server_request = Task.await(task)
    assert cookie_header(server_request) == "a=v; b=v"
  end

  for host <- ["127.0.0.1", "[::1]"] do
    @tag host: host
    test "should send secure cookie over http for #{host}", %{request: request, server: server, host: host} = context do
      # The TestServer listens on 127.0.0.1 only (upstream: all interfaces): serve [::1] from a second one.
      server =
        if host == "[::1]" do
          dir_path = Path.dirname(context.asset.("empty.html"))
          TestServer.server(start_supervised!({TestServer, dir_path: dir_path, ip: {0, 0, 0, 0, 0, 0, 0, 1}}))
        else
          server
        end

      TestServer.set_route(server, "/setcookie.html", fn conn -> set_cookie(conn, ["a=v; secure", "b=v"]) end)
      prefix = "http://#{host}:#{server.port}"
      APIRequestContext.get!(request, "#{prefix}/setcookie.html")
      task = TestServer.wait_for_request(server, "/empty.html")
      APIRequestContext.get!(request, "#{prefix}/empty.html")
      server_request = Task.await(task)
      assert cookie_header(server_request) == "a=v; b=v"
      assert names(APIRequestContext.cookies!(request, "#{prefix}/")) == ["a", "b"]
    end
  end

  test "should send not expired cookies", %{request: request, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      tomorrow = DateTime.add(DateTime.utc_now(), 1, :day)
      set_cookie(conn, ["a=v", "b=v; expires=#{to_utc_string(tomorrow)}"])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)
    assert cookie_header(server_request) == "a=v; b=v"
  end

  test "should remove expired cookies", %{request: request, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      set_cookie(conn, ["a=v", "b=v; expires=#{to_utc_string(DateTime.utc_now())}"])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)
    assert cookie_header(server_request) == "a=v"
  end

  test "should remove cookie with negative max-age", %{request: request, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      set_cookie(conn, ["a=v; max-age=100000", "b=v; max-age=100000", "c=v"])
    end)

    TestServer.set_route(server, "/removecookie.html", fn conn ->
      max_age = -2 * System.system_time(:millisecond)
      set_cookie(conn, ["a=v; max-age=#{max_age}", "b=v; max-age=-1"])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    APIRequestContext.get!(request, "#{server.prefix}/removecookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)
    assert cookie_header(server_request) == "c=v"
  end

  test "should prefer max-age over expires regardless of the order", %{request: request, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43077' });
    past = "Thu, 01 Jan 1970 00:00:00 GMT"
    future = to_utc_string(DateTime.add(DateTime.utc_now(), 3600, :second))

    TestServer.set_route(server, "/setcookie.html", fn conn ->
      set_cookie(conn, [
        "a=v; max-age=3600; expires=#{past}",
        "b=v; expires=#{past}; max-age=3600",
        "c=v; max-age=-1; expires=#{future}",
        "d=v; expires=#{future}; max-age=-1"
      ])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)
    assert cookie_header(server_request) == "a=v; b=v"
  end

  test "should ignore max-age that is not a number", %{request: request, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43077' });
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      set_cookie(conn, ["a=v; max-age=-1abc", "b=v; max-age=3600abc", "c=v; max-age="])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)
    assert cookie_header(server_request) == "a=v; b=v; c=v"
    %{cookies: cookies} = APIRequestContext.storage_state!(request)
    assert Enum.map(cookies, & &1.expires) == [-1, -1, -1]
  end

  test "should remove cookie with expires far in the past", %{request: request, server: server} do
    TestServer.set_route(server, "/setcookie.html", fn conn -> set_cookie(conn, ["a=v; max-age=1000000"]) end)

    TestServer.set_route(server, "/removecookie.html", fn conn ->
      set_cookie(conn, ["a=v; expires=1 Jan 1000 00:00:00 +0000 (UTC)"])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    APIRequestContext.get!(request, "#{server.prefix}/removecookie.html")
    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)
    refute cookie_header(server_request)
  end

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "should store cookie from Set-Cookie header even if it contains equal signs"

  test "should override cookie from Set-Cookie header", %{request: request, server: server} do
    tomorrow = DateTime.add(DateTime.utc_now(), 1, :day)

    TestServer.set_route(server, "/setcookie.html", fn conn ->
      set_cookie(conn, ["a=old; expires=#{to_utc_string(tomorrow)}"])
    end)

    day_after_tomorrow = DateTime.add(tomorrow, 1, :day)
    day_after_tomorrow_in_seconds = DateTime.to_unix(day_after_tomorrow)

    TestServer.set_route(server, "/updatecookie.html", fn conn ->
      set_cookie(conn, ["a=new; expires=#{to_utc_string(day_after_tomorrow)}"])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    APIRequestContext.get!(request, "#{server.prefix}/updatecookie.html")

    state = APIRequestContext.storage_state!(request)

    assert length(state.cookies) == 1
    assert hd(state.cookies).name == "a"
    assert hd(state.cookies).value == "new"
    assert hd(state.cookies).expires == day_after_tomorrow_in_seconds
  end

  test "should override cookie from Set-Cookie header even if it expired", %{request: request, server: server} do
    tomorrow = DateTime.add(DateTime.utc_now(), 1, :day)

    TestServer.set_route(server, "/setcookie.html", fn conn ->
      set_cookie(conn, ["a=ok", "b=ok; expires=#{to_utc_string(tomorrow)}"])
    end)

    TestServer.set_route(server, "/unsetsetcookie.html", fn conn ->
      # new Date(1970, 0, 1, 0, 0, 0, 0) is local time: UTC here.
      past_date_string = to_utc_string(~U[1970-01-01 00:00:00Z])
      set_cookie(conn, ["a=; expires=#{past_date_string}", "b=; expires=#{past_date_string}"])
    end)

    APIRequestContext.get!(request, "#{server.prefix}/setcookie.html")
    APIRequestContext.get!(request, "#{server.prefix}/unsetsetcookie.html")

    task = TestServer.wait_for_request(server, "/empty.html")
    APIRequestContext.get!(request, server.empty_page)
    server_request = Task.await(task)

    refute cookie_header(server_request)
  end

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "should export cookies to storage state"

  test "should preserve origin storage on import/export of storage state", %{playwright: playwright} do
    storage_state = %{
      cookies: [
        %{
          name: "a",
          value: "b",
          domain: "a.b.one.com",
          path: "/",
          expires: -1,
          httpOnly: false,
          secure: false,
          sameSite: "Lax"
        }
      ],
      origins: [
        %{
          origin: "https://www.example.com",
          localStorage: [%{name: "name1", value: "value1"}],
          # ...{ opfs, indexedDB } (untyped, as any): the facade rejects the unknown fields.
          opfs: [
            %{path: "hello.txt", type: "file", base64: "SGVsbG8sIHdvcmxkIQ=="},
            %{path: "empty", type: "directory"}
          ],
          indexedDB: [
            %{
              name: "db",
              version: 5,
              stores: [
                %{
                  name: "store",
                  keyPath: "id",
                  autoIncrement: false,
                  indexes: [],
                  records: [%{value: %{id: "foo", name: "John Doe"}}]
                }
              ]
            }
          ]
        }
      ]
    }

    assert_raise ArgumentError, ~r/unknown field/, fn ->
      APIRequest.new_context(Playwright.request(playwright), storage_state: storage_state)
    end
  end

  @tag skip: "not ported: __testHookLookup (in-process test hook)"
  test "should send cookies from storage state"

  @tag :tmp_dir
  test "storage state should round-trip through file", %{playwright: playwright, tmp_dir: tmp_dir} do
    storage_state = %{
      cookies: [
        %{
          name: "a",
          value: "b",
          domain: "a.b.one.com",
          path: "/",
          expires: -1,
          httpOnly: false,
          secure: false,
          sameSite: "Lax"
        }
      ],
      origins: []
    }

    request1 = APIRequest.new_context!(Playwright.request(playwright), storage_state: storage_state)
    path = Path.join(tmp_dir, "storage-state.json")
    state1 = APIRequestContext.storage_state!(request1, path: path)
    assert state1 == storage_state

    written = File.read!(path)
    # JSON.stringify(state1, undefined, 2): the client writes compact JSON (Elixir's JSON has no indentation).
    assert JSON.encode!(state1) == written

    request2 = APIRequest.new_context!(Playwright.request(playwright), storage_state: path)
    state2 = APIRequestContext.storage_state!(request2)
    assert state2 == storage_state
  end

  @tag :tmp_dir
  test "should work with empty storage state", %{playwright: playwright, server: server, tmp_dir: tmp_dir} do
    storage_state = Path.join(tmp_dir, "storage-state.json")
    File.write!(storage_state, "{}")
    request1 = APIRequest.new_context!(Playwright.request(playwright), storage_state: storage_state)

    state1 = APIRequestContext.storage_state!(request1)
    assert state1 == %{cookies: [], origins: []}
    # await expect(...).toBeOK()  -- not ported: toBeOK (APIResponseAssertions); ok() is its pass condition
    assert APIResponse.ok(APIRequestContext.get!(request1, server.empty_page))
    APIRequestContext.dispose!(request1)
  end
end
