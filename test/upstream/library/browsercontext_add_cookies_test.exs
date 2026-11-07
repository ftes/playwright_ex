defmodule PlaywrightEx.Library.BrowsercontextAddCookiesTest do
  @upstream "tests/library/browsercontext-add-cookies.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  defp windows?, do: match?({:win32, _}, :os.type())
  defp linux?, do: match?({:unix, :linux}, :os.type())
  defp darwin?, do: match?({:unix, :darwin}, :os.type())

  # `new Set(cookies)` equality: order-insensitive.
  defp sort_by_name(cookies), do: Enum.sort_by(cookies, & &1.name)

  # `(browserName === 'webkit' && isWindows && channel !== 'webkit-wsl') ? 'None' : x` (no channel here).
  defp same_site(browser_name, value), do: if(browser_name == "webkit" and windows?(), do: "None", else: value)

  test "CO-019 should work @smoke", %{context: context, page: page, server: server} do
    Page.goto!(page, server.empty_page)

    BrowserContext.add_cookies!(context, [
      %{
        url: server.empty_page,
        name: "password",
        value: "123456"
      }
    ])

    assert Page.evaluate!(page, "() => document.cookie") == "password=123456"
  end

  test "CO-020 should work with expires=-1", %{context: context, page: page} do
    BrowserContext.add_cookies!(context, [
      %{
        name: "username",
        value: "John Doe",
        domain: "www.example.com",
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: false,
        sameSite: "Lax"
      }
    ])

    Page.route!(page, "**/*", fn route ->
      Route.fulfill(route, body: "<html></html>")
    end)

    Page.goto!(page, "https://www.example.com")
    assert Page.evaluate!(page, "() => document.cookie") == "username=John Doe"
  end

  test "CO-021 should add cookies with empty value", %{context: context, page: page} do
    BrowserContext.add_cookies!(context, [
      %{
        name: "marker",
        value: "",
        domain: "www.example.com",
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: false,
        sameSite: "Lax"
      }
    ])

    Page.route!(page, "**/*", fn route ->
      Route.fulfill(route, body: "<html></html>")
    end)

    Page.goto!(page, "https://www.example.com")
    assert Page.evaluate!(page, "() => document.cookie") == "marker="
  end

  test "CO-022 should set cookies with SameSite attribute and no secure attribute", %{
    context: context,
    browser_name: browser_name
  } do
    # Use domain instead of URL to ensure that the `secure` attribute is not set.
    BrowserContext.add_cookies!(context, [
      %{
        domain: "foo.com",
        path: "/",
        name: "same-site-unset",
        value: "1"
      },
      %{
        domain: "foo.com",
        path: "/",
        name: "same-site-none",
        value: "1",
        sameSite: "None"
      },
      %{
        domain: "foo.com",
        path: "/",
        name: "same-site-lax",
        value: "1",
        sameSite: "Lax"
      },
      %{
        domain: "foo.com",
        path: "/",
        name: "same-site-strict",
        value: "1",
        sameSite: "Strict"
      }
    ])

    cookies = BrowserContext.cookies!(context, ["https://foo.com"])

    expected =
      [
        %{
          name: "same-site-unset",
          value: "1",
          domain: "foo.com",
          path: "/",
          expires: -1,
          httpOnly: false,
          secure: false,
          sameSite: default_same_site_cookie_value(browser_name)
        }
      ] ++
        if(browser_name == "chromium" or (browser_name == "webkit" and linux?()),
          do: [],
          else: [
            %{
              name: "same-site-none",
              value: "1",
              domain: "foo.com",
              path: "/",
              expires: -1,
              httpOnly: false,
              secure: false,
              sameSite: "None"
            }
          ]
        ) ++
        [
          %{
            name: "same-site-lax",
            value: "1",
            domain: "foo.com",
            path: "/",
            expires: -1,
            httpOnly: false,
            secure: false,
            sameSite: same_site(browser_name, "Lax")
          },
          %{
            name: "same-site-strict",
            value: "1",
            domain: "foo.com",
            path: "/",
            expires: -1,
            httpOnly: false,
            secure: false,
            sameSite: same_site(browser_name, "Strict")
          }
        ]

    assert sort_by_name(cookies) == sort_by_name(expected)
  end

  test "CO-023 should roundtrip cookie", %{context: context, page: page, server: server} do
    Page.goto!(page, server.empty_page)
    # @see https://en.wikipedia.org/wiki/Year_2038_problem
    # `+(new Date('1/1/2038'))` (local time there, UTC here: any date past 2038 does).
    date = DateTime.to_unix(~U[2038-01-01 00:00:00Z], :millisecond)

    document_cookie =
      Page.evaluate!(
        page,
        """
        timestamp => {
          const date = new Date(timestamp);
          document.cookie = `username=John Doe;expires=${date.toUTCString()}`;
          return document.cookie;
        }
        """,
        date
      )

    assert document_cookie == "username=John Doe"
    cookies = BrowserContext.cookies!(context)
    BrowserContext.clear_cookies!(context)
    assert BrowserContext.cookies!(context) == []
    BrowserContext.add_cookies!(context, cookies)
    # Slightly different rounding on chromium win.
    normalized_expires = fn cookies -> Enum.map(cookies, &%{&1 | expires: floor(&1.expires)}) end
    assert normalized_expires.(BrowserContext.cookies!(context)) == normalized_expires.(cookies)
  end

  test "CO-024 should send cookie header", %{server: server, context: context} do
    me = self()

    TestServer.set_route(server, "/empty.html", fn conn ->
      send(me, {:cookie, header(conn, "cookie")})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    BrowserContext.add_cookies!(context, [%{url: server.empty_page, name: "cookie", value: "value"}])
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert_received {:cookie, "cookie=value"}
  end

  test "CO-025 should isolate cookies in browser contexts", %{context: context, server: server, browser: browser} do
    another_context = Browser.new_context!(browser)
    BrowserContext.add_cookies!(context, [%{url: server.empty_page, name: "isolatecookie", value: "page1value"}])

    BrowserContext.add_cookies!(another_context, [%{url: server.empty_page, name: "isolatecookie", value: "page2value"}])

    cookies1 = BrowserContext.cookies!(context)
    cookies2 = BrowserContext.cookies!(another_context)
    assert length(cookies1) == 1
    assert length(cookies2) == 1
    assert hd(cookies1).name == "isolatecookie"
    assert hd(cookies1).value == "page1value"
    assert hd(cookies2).name == "isolatecookie"
    assert hd(cookies2).value == "page2value"
    BrowserContext.close!(another_context)
  end

  test "CO-026 should isolate session cookies", %{context: context, server: server, browser: browser} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "session=value")
      |> Plug.Conn.send_resp(200, "")
    end)

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/setcookie.html")

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    cookies = BrowserContext.cookies!(context)
    assert length(cookies) == 1
    assert Enum.map_join(cookies, ",", & &1.value) == "value"

    context2 = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context2)
    Page.goto!(page, server.empty_page)
    cookies = BrowserContext.cookies!(context2)
    assert (List.first(cookies) && hd(cookies).name) == nil
    BrowserContext.close!(context2)
  end

  test "CO-027 should isolate persistent cookies", %{context: context, server: server, browser: browser} do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "persistent=persistent-value; max-age=3600")
      |> Plug.Conn.send_resp(200, "")
    end)

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/setcookie.html")

    context1 = context
    context2 = Browser.new_context!(browser)
    page1 = BrowserContext.new_page!(context1)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page1, server.empty_page)
    Page.goto!(page2, server.empty_page)
    cookies1 = BrowserContext.cookies!(context1)
    cookies2 = BrowserContext.cookies!(context2)
    assert length(cookies1) == 1
    assert hd(cookies1).name == "persistent"
    assert hd(cookies1).value == "persistent-value"
    assert cookies2 == []
    BrowserContext.close!(context2)
  end

  test "CO-028 should isolate send cookie header", %{server: server, context: context, browser: browser} do
    me = self()

    TestServer.set_route(server, "/empty.html", fn conn ->
      send(me, {:cookie, header(conn, "cookie") || ""})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    BrowserContext.add_cookies!(context, [%{url: server.empty_page, name: "sendcookie", value: "value"}])

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert_received {:cookie, "sendcookie=value"}

    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert_received {:cookie, ""}
    BrowserContext.close!(context)
  end

  # playwrightTest.slow()
  @tag timeout: @slow_timeout
  test "CO-029 should isolate cookies between launches", %{browser_type: browser_type, server: server} do
    browser1 = BrowserType.launch!(browser_type)
    context1 = Browser.new_context!(browser1)

    BrowserContext.add_cookies!(context1, [
      %{
        url: server.empty_page,
        name: "cookie-in-context-1",
        value: "value",
        expires: System.os_time(:millisecond) / 1000 + 10_000
      }
    ])

    Browser.close!(browser1)

    browser2 = BrowserType.launch!(browser_type)
    context2 = Browser.new_context!(browser2)
    cookies = BrowserContext.cookies!(context2)
    assert cookies == []
    Browser.close!(browser2)
  end

  test "CO-030 should set multiple cookies", %{context: context, page: page, server: server} do
    Page.goto!(page, server.empty_page)

    BrowserContext.add_cookies!(context, [
      %{
        url: server.empty_page,
        name: "multiple-1",
        value: "123456"
      },
      %{
        url: server.empty_page,
        name: "multiple-2",
        value: "bar"
      }
    ])

    assert Page.evaluate!(page, """
           () => {
             const cookies = document.cookie.split(';');
             return cookies.map(cookie => cookie.trim()).sort();
           }
           """) == [
             "multiple-1=123456",
             "multiple-2=bar"
           ]
  end

  test "CO-031 should have |expires| set to |-1| for session cookies", %{context: context, server: server} do
    BrowserContext.add_cookies!(context, [
      %{
        url: server.empty_page,
        name: "expires",
        value: "123456"
      }
    ])

    cookies = BrowserContext.cookies!(context)
    assert hd(cookies).expires == -1
  end

  test "CO-032 should set cookie with reasonable defaults", %{
    context: context,
    server: server,
    browser_name: browser_name
  } do
    BrowserContext.add_cookies!(context, [
      %{
        url: server.empty_page,
        name: "defaults",
        value: "123456"
      }
    ])

    cookies = BrowserContext.cookies!(context)

    assert Enum.sort_by(cookies, & &1.name) == [
             %{
               name: "defaults",
               value: "123456",
               domain: server.hostname,
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: false,
               sameSite: default_same_site_cookie_value(browser_name)
             }
           ]
  end

  test "CO-033 should set a cookie with a path", %{
    context: context,
    page: page,
    server: server,
    browser_name: browser_name
  } do
    Page.goto!(page, server.prefix <> "/grid.html")

    BrowserContext.add_cookies!(context, [
      %{
        domain: server.hostname,
        path: "/grid.html",
        name: "gridcookie",
        value: "GRID",
        sameSite: "Lax"
      }
    ])

    assert BrowserContext.cookies!(context) == [
             %{
               name: "gridcookie",
               value: "GRID",
               domain: server.hostname,
               path: "/grid.html",
               expires: -1,
               httpOnly: false,
               secure: false,
               sameSite: same_site(browser_name, "Lax")
             }
           ]

    assert Page.evaluate!(page, "document.cookie") == "gridcookie=GRID"
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "document.cookie") == ""
    Page.goto!(page, server.prefix <> "/grid.html")
    assert Page.evaluate!(page, "document.cookie") == "gridcookie=GRID"
  end

  test "CO-034 should not set a cookie with blank page URL", %{context: context, server: server} do
    {:error, error} =
      BrowserContext.add_cookies(context, [
        %{url: server.empty_page, name: "example-cookie", value: "best"},
        %{url: "about:blank", name: "example-cookie-blank", value: "best"}
      ])

    assert Exception.message(error) =~ ~s(Blank page can not have cookie "example-cookie-blank")
  end

  test "CO-035 should not set a cookie on a data URL page", %{context: context} do
    {:error, error} =
      BrowserContext.add_cookies(context, [%{url: "data:,Hello%2C%20World!", name: "example-cookie", value: "best"}])

    assert Exception.message(error) =~ ~s(Data URL page can not have cookie "example-cookie")
  end

  test "CO-036 should default to setting secure cookie for HTTPS websites", %{
    context: context,
    page: page,
    server: server
  } do
    Page.goto!(page, server.empty_page)
    secure_url = "https://example.com"

    BrowserContext.add_cookies!(context, [
      %{
        url: secure_url,
        name: "foo",
        value: "bar"
      }
    ])

    [cookie] = BrowserContext.cookies!(context, secure_url)
    assert cookie.secure == true
  end

  test "CO-037 should be able to set unsecure cookie for HTTP website", %{context: context, page: page, server: server} do
    Page.goto!(page, server.empty_page)
    http_url = "http://example.com"

    BrowserContext.add_cookies!(context, [
      %{
        url: http_url,
        name: "foo",
        value: "bar"
      }
    ])

    [cookie] = BrowserContext.cookies!(context, http_url)
    assert cookie.secure == false
  end

  test "CO-038 should set a cookie on a different domain", %{
    context: context,
    page: page,
    server: server,
    browser_name: browser_name
  } do
    Page.goto!(page, server.empty_page)

    BrowserContext.add_cookies!(context, [
      %{
        url: "https://www.example.com",
        name: "example-cookie",
        value: "best",
        sameSite: "Lax"
      }
    ])

    assert Page.evaluate!(page, "document.cookie") == ""

    assert BrowserContext.cookies!(context, "https://www.example.com") == [
             %{
               name: "example-cookie",
               value: "best",
               domain: "www.example.com",
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: true,
               sameSite: same_site(browser_name, "Lax")
             }
           ]
  end

  test "CO-039 should set cookies for a frame", %{context: context, page: page, server: server} do
    Page.goto!(page, server.empty_page)

    BrowserContext.add_cookies!(context, [
      %{url: server.prefix, name: "frame-cookie", value: "value"}
    ])

    Page.evaluate!(
      page,
      """
      src => {
        let fulfill;
        const promise = new Promise(x => fulfill = x);
        const iframe = document.createElement('iframe');
        document.body.appendChild(iframe);
        iframe.onload = fulfill;
        iframe.src = src;
        return promise;
      }
      """,
      server.prefix <> "/grid.html"
    )

    assert page |> Page.frames() |> Enum.at(1) |> Frame.evaluate!("document.cookie") == "frame-cookie=value"
  end

  test "CO-040 should allow unnamed cookies", %{
    page: page,
    context: context,
    server: server,
    browser_name: browser_name
  } do
    TestServer.set_route(server, "/cookies", fn conn ->
      Plug.Conn.send_resp(conn, 200, header(conn, "cookie") || "undefined-on-server")
    end)

    BrowserContext.add_cookies!(context, [
      %{
        url: server.empty_page,
        name: "",
        value: "unnamed-via-add-cookies"
      }
    ])

    # Round-trip behavior
    resp = Page.goto!(page, server.prefix <> "/cookies")

    # expect.soft: plain assertions (no soft asserts).
    if browser_name == "webkit" and darwin?() do
      assert Response.text!(resp) == "undefined-on-server"
      assert Page.evaluate!(page, "document.cookie") == ""
    else
      assert Response.text!(resp) == "unnamed-via-add-cookies"
      assert Page.evaluate!(page, "document.cookie") == "unnamed-via-add-cookies"
    end

    # Within PW behavior
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => document.cookie = '=unnamed-via-js;'")
    BrowserContext.add_cookies!(context, BrowserContext.cookies!(context))

    if browser_name == "webkit" and darwin?(),
      do: assert(Page.evaluate!(page, "document.cookie") == ""),
      else: assert(Page.evaluate!(page, "document.cookie") == "unnamed-via-js")
  end

  test "CO-041 should set secure cookies on secure WebSocket", %{
    context_factory: context_factory,
    https_server: https_server
  } do
    me = self()

    TestServer.once_web_socket_connection(https_server, fn _ws, conn ->
      send(me, {:received_web_socket_headers, conn})
    end)

    context = context_factory.(ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, https_server.empty_page)

    BrowserContext.add_cookies!(context, [
      %{domain: URI.parse(https_server.prefix).host, path: "/", name: "foo", value: "bar", secure: true}
    ])

    Page.evaluate!(page, "hostname => new WebSocket(`wss://${hostname}/ws`)", https_server.host)
    assert_receive {:received_web_socket_headers, conn}, 5000
    assert header(conn, "cookie") == "foo=bar"
  end
end
