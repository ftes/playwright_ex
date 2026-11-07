defmodule PlaywrightEx.Library.BrowsercontextCookiesTest do
  @upstream "tests/library/browsercontext-cookies.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  @moduletag :page

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  defp windows?, do: match?({:win32, _}, :os.type())
  defp linux?, do: match?({:unix, :linux}, :os.type())

  # `(browserName === 'webkit' && isWindows && channel !== 'webkit-wsl') ? 'None' : 'Lax'`
  defp lax(browser_name), do: if(browser_name == "webkit" and windows?(), do: "None", else: "Lax")

  defp set_cookie_route(server, path, cookie) do
    TestServer.set_route(server, path, fn conn ->
      conn |> Plug.Conn.put_resp_header("set-cookie", cookie) |> Plug.Conn.send_resp(200, "")
    end)
  end

  test "CO-001 should return no cookies in pristine browser context", %{context: context} do
    assert BrowserContext.cookies!(context) == []
  end

  test "CO-002 should get a cookie @smoke", %{
    context: context,
    page: page,
    server: server,
    browser_name: browser_name
  } do
    Page.goto!(page, server.empty_page)

    document_cookie =
      Page.evaluate!(page, """
      () => {
        document.cookie = 'username=John Doe';
        return document.cookie;
      }
      """)

    assert document_cookie == "username=John Doe"

    assert BrowserContext.cookies!(context) == [
             %{
               name: "username",
               value: "John Doe",
               domain: server.hostname,
               path: "/",
               expires: -1,
               httpOnly: false,
               secure: false,
               sameSite: default_same_site_cookie_value(browser_name)
             }
           ]
  end

  test "CO-003 should get a non-session cookie", %{
    context: context,
    page: page,
    server: server,
    browser_name: browser_name
  } do
    Page.goto!(page, server.empty_page)
    # @see https://en.wikipedia.org/wiki/Year_2038_problem
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
    assert length(cookies) == 1

    # expect.anything()
    assert hd(cookies).expires != nil

    assert %{hd(cookies) | expires: :anything} == %{
             name: "username",
             value: "John Doe",
             domain: server.hostname,
             path: "/",
             # We will check this separately.
             expires: :anything,
             httpOnly: false,
             secure: false,
             sameSite: default_same_site_cookie_value(browser_name)
           }

    # Browsers start to cap cookies with 400 days max expires value.
    # See https://github.com/httpwg/http-extensions/pull/1732
    # Chromium patch: https://chromium.googlesource.com/chromium/src/+/aaa5d2b55478eac2ee642653dcd77a50ac3faff6
    # We want to make sure that expires date is at least 400 days in future.
    four_hundred_days = 1000 * 60 * 60 * 24 * 400
    # relax condition a bit to make sure test is not flaky.
    five_minutes = 1000 * 60 * 5

    assert hd(cookies).expires >
             (System.system_time(:millisecond) + four_hundred_days - five_minutes) / 1000
  end

  test "CO-004 should allow adding cookies with >400 days expiration", %{
    context: context,
    server: server
  } do
    # Browsers start to cap cookies with 400 days max expires value.
    # See https://github.com/httpwg/http-extensions/pull/1732
    # Chromium patch: https://chromium.googlesource.com/chromium/src/+/aaa5d2b55478eac2ee642653dcd77a50ac3faff6
    expire = System.system_time(:millisecond) / 1000 + 401 * 24 * 3600

    BrowserContext.add_cookies!(context, [
      %{
        name: "username",
        value: "John Doe",
        domain: server.hostname,
        path: "/",
        expires: expire,
        httpOnly: false,
        secure: false,
        sameSite: "Lax"
      }
    ])

    cookies = BrowserContext.cookies!(context)
    assert length(cookies) == 1
    assert %{name: "username", value: "John Doe", domain: domain, path: "/"} = hd(cookies)
    assert domain == server.hostname
    assert hd(cookies).expires > 0
    assert hd(cookies).expires <= expire
  end

  test "CO-005 should properly report httpOnly cookie", %{context: context, page: page, server: server} do
    set_cookie_route(server, "/empty.html", "name=value;HttpOnly; Path=/")
    Page.goto!(page, server.empty_page)
    cookies = BrowserContext.cookies!(context)
    assert length(cookies) == 1
    assert hd(cookies).httpOnly == true
  end

  test "CO-006 should properly report \"Strict\" sameSite cookie", %{
    context: context,
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # it.fail(browserName === 'webkit' && platform === 'win32' && channel !== 'webkit-wsl')
    expected_failure(browser_name == "webkit" and windows?(), fn ->
      set_cookie_route(server, "/empty.html", "name=value;SameSite=Strict")
      Page.goto!(page, server.empty_page)
      cookies = BrowserContext.cookies!(context)
      assert length(cookies) == 1
      assert hd(cookies).sameSite == "Strict"
    end)
  end

  test "CO-007 should properly report \"Lax\" sameSite cookie", %{
    context: context,
    page: page,
    server: server,
    browser_name: browser_name
  } do
    # it.fail(browserName === 'webkit' && platform === 'win32' && channel !== 'webkit-wsl')
    expected_failure(browser_name == "webkit" and windows?(), fn ->
      set_cookie_route(server, "/empty.html", "name=value;SameSite=Lax")
      Page.goto!(page, server.empty_page)
      cookies = BrowserContext.cookies!(context)
      assert length(cookies) == 1
      assert hd(cookies).sameSite == "Lax"
    end)
  end

  test "CO-008 should get multiple cookies", %{
    context: context,
    page: page,
    server: server,
    browser_name: browser_name
  } do
    Page.goto!(page, server.empty_page)

    document_cookie =
      Page.evaluate!(page, """
      () => {
        document.cookie = 'username=John Doe';
        document.cookie = 'password=1234';
        return document.cookie.split('; ').sort().join('; ');
      }
      """)

    cookies = MapSet.new(BrowserContext.cookies!(context))
    assert document_cookie == "password=1234; username=John Doe"

    assert cookies ==
             MapSet.new([
               %{
                 name: "password",
                 value: "1234",
                 domain: server.hostname,
                 path: "/",
                 expires: -1,
                 httpOnly: false,
                 secure: false,
                 sameSite: default_same_site_cookie_value(browser_name)
               },
               %{
                 name: "username",
                 value: "John Doe",
                 domain: server.hostname,
                 path: "/",
                 expires: -1,
                 httpOnly: false,
                 secure: false,
                 sameSite: default_same_site_cookie_value(browser_name)
               }
             ])
  end

  test "CO-009 should get cookies from multiple urls", %{context: context, browser_name: browser_name} do
    BrowserContext.add_cookies!(context, [
      %{url: "https://foo.com", name: "doggo", value: "woofs", sameSite: "None"},
      %{url: "https://bar.com", name: "catto", value: "purrs", sameSite: "Lax"},
      %{url: "https://baz.com", name: "birdo", value: "tweets", sameSite: "Lax"}
    ])

    cookies = MapSet.new(BrowserContext.cookies!(context, ["https://foo.com", "https://baz.com"]))

    assert cookies ==
             MapSet.new([
               %{
                 name: "birdo",
                 value: "tweets",
                 domain: "baz.com",
                 path: "/",
                 expires: -1,
                 httpOnly: false,
                 secure: true,
                 sameSite: lax(browser_name)
               },
               %{
                 name: "doggo",
                 value: "woofs",
                 domain: "foo.com",
                 path: "/",
                 expires: -1,
                 httpOnly: false,
                 secure: true,
                 sameSite: "None"
               }
             ])
  end

  test "CO-010 should work with subdomain cookie", %{context: context, browser_name: browser_name} do
    BrowserContext.add_cookies!(context, [
      %{
        domain: ".foo.com",
        path: "/",
        name: "doggo",
        value: "woofs",
        sameSite: "Lax",
        secure: true
      }
    ])

    expected = [
      %{
        name: "doggo",
        value: "woofs",
        domain: ".foo.com",
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: true,
        sameSite: lax(browser_name)
      }
    ]

    assert BrowserContext.cookies!(context, "https://foo.com") == expected
    assert BrowserContext.cookies!(context, "https://sub.foo.com") == expected
  end

  test "CO-012 should return cookies with empty value", %{context: context, page: page, server: server} do
    set_cookie_route(server, "/empty.html", "name=;Path=/")
    Page.goto!(page, server.empty_page)
    cookies = BrowserContext.cookies!(context)
    assert [%{name: "name", value: ""}] = cookies
  end

  test "CO-013 should return secure cookies based on HTTP(S) protocol", %{
    context: context,
    browser_name: browser_name
  } do
    BrowserContext.add_cookies!(context, [
      %{url: "https://foo.com", name: "doggo", value: "woofs", sameSite: "Lax", secure: true},
      %{url: "http://foo.com", name: "catto", value: "purrs", sameSite: "Lax", secure: false}
    ])

    catto = %{
      name: "catto",
      value: "purrs",
      domain: "foo.com",
      path: "/",
      expires: -1,
      httpOnly: false,
      secure: false,
      sameSite: lax(browser_name)
    }

    cookies = MapSet.new(BrowserContext.cookies!(context, "https://foo.com"))

    assert cookies ==
             MapSet.new([
               catto,
               %{
                 name: "doggo",
                 value: "woofs",
                 domain: "foo.com",
                 path: "/",
                 expires: -1,
                 httpOnly: false,
                 secure: true,
                 sameSite: lax(browser_name)
               }
             ])

    assert BrowserContext.cookies!(context, "http://foo.com/") == [catto]
  end

  for host <- ["127.0.0.1", "[::1]"] do
    @host host
    test "CO-014 should return secure cookies for http #{host}", %{context: context} do
      host = @host

      BrowserContext.add_cookies!(context, [
        %{name: "a", value: "v", domain: host, path: "/", secure: true}
      ])

      assert Enum.map(BrowserContext.cookies!(context, "http://#{host}/"), & &1.name) == ["a"]
    end
  end

  test "CO-015 should add cookies with an expiration", %{context: context} do
    expires = floor(System.system_time(:millisecond) / 1000) + 3600

    BrowserContext.add_cookies!(context, [
      %{url: "https://foo.com", name: "doggo", value: "woofs", sameSite: "None", expires: expires}
    ])

    cookies = BrowserContext.cookies!(context, ["https://foo.com"])
    assert length(cookies) == 1

    assert cookies == [
             %{
               name: "doggo",
               value: "woofs",
               domain: "foo.com",
               path: "/",
               expires: expires,
               httpOnly: false,
               secure: true,
               sameSite: "None"
             }
           ]

    # Rollover to 5-digit year
    BrowserContext.add_cookies!(context, [
      # Fri, 31 Dec 9999 23:59:59 +0000 (UTC)
      %{
        url: "https://foo.com",
        name: "doggo",
        value: "woofs",
        sameSite: "None",
        expires: 253_402_300_799
      }
    ])

    assert {:error, error} =
             BrowserContext.add_cookies(context, [
               # Sat,  1 Jan 1000 00:00:00 +0000 (UTC)
               %{
                 url: "https://foo.com",
                 name: "doggo",
                 value: "woofs",
                 sameSite: "None",
                 expires: 253_402_300_800
               }
             ])

    assert Exception.message(error) =~ ~r/Cookie should have a valid expires/

    assert {:error, error} =
             BrowserContext.add_cookies(context, [
               %{
                 url: "https://foo.com",
                 name: "doggo",
                 value: "woofs",
                 sameSite: "None",
                 expires: -42
               }
             ])

    assert Exception.message(error) =~ ~r/Cookie should have a valid expires/
  end

  @tag skip:
         if(System.get_env("BROWSER", "chromium") == "chromium",
           do: "upstream skip: requestStorageAccess API is not available in Chromium"
         )
  test "CO-016 should support requestStorageAccess", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    set_cookie_route(server, "/set-cookie.html", "name=value; Path=/")
    # Navigate once to the domain as top level.
    Page.goto!(page, server.cross_process_prefix <> "/set-cookie.html")
    Page.goto!(page, server.empty_page)

    Page.set_content!(
      page,
      ~s(<iframe src="#{server.cross_process_prefix <> "/empty.html"}"></iframe>)
    )

    frame = Enum.at(Page.frames(page), 1)

    fetch_cookie = fn ->
      server_request = TestServer.wait_for_request(server, "/title.html")
      Frame.evaluate!(frame, "() => fetch('/title.html')")
      header(Task.await(server_request, :infinity), "cookie")
    end

    if browser_name == "firefox" do
      Utils.assert_truthy(Frame.evaluate!(frame, "() => document.hasStorageAccess()"))
      assert fetch_cookie.() == "name=value"
    else
      if browser_name == "webkit" and linux?(),
        do: Utils.assert_truthy(Frame.evaluate!(frame, "() => document.hasStorageAccess()")),
        else: Utils.assert_falsy(Frame.evaluate!(frame, "() => document.hasStorageAccess()"))

      if windows?() and browser_name == "webkit",
        do: assert(fetch_cookie.() == "name=value"),
        else: refute(fetch_cookie.())

      Utils.assert_truthy(Frame.evaluate!(frame, "() => document.requestStorageAccess().then(() => true, e => false)"))

      Utils.assert_truthy(Frame.evaluate!(frame, "() => document.hasStorageAccess()"))

      if browser_name == "webkit" and linux?(),
        do: assert(fetch_cookie.() == nil),
        else: assert(fetch_cookie.() == "name=value")
    end
  end

  test "CO-017 should parse cookie with large Max-Age correctly", %{
    server: server,
    page: page,
    browser_name: browser_name
  } do
    TestServer.set_route(server, "/foobar", fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "set-cookie",
        "cookie1=value1; Path=/; Expires=Thu, 08 Sep 2270 15:06:12 GMT; Max-Age=7776000000"
      )
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.prefix <> "/foobar")
    assert Page.evaluate!(page, "() => document.cookie") == "cookie1=value1"

    cookies = BrowserContext.cookies!(Page.context(page))
    # expect.any(Number)
    assert Enum.all?(cookies, &is_number(&1.expires))

    assert Enum.map(cookies, &%{&1 | expires: :any_number}) == [
             %{
               name: "cookie1",
               value: "value1",
               domain: server.hostname,
               path: "/",
               expires: :any_number,
               httpOnly: false,
               secure: false,
               sameSite: default_same_site_cookie_value(browser_name)
             }
           ]
  end

  test "CO-018 iframe should inherit cookies from parent", %{page: page} do
    Page.route!(page, "**/*", fn route, request ->
      if String.contains?(Request.url(request), "sub.example.test") do
        Route.fulfill!(route,
          body: """
              <p id="result"></p>
              <script>document.getElementById('result').textContent = document.cookie || 'no cookies';</script>
          """,
          content_type: "text/html"
        )
      else
        Route.fulfill!(route,
          headers: %{"set-cookie" => "testCookie=value; SameSite=Lax; Domain=example.test"},
          content_type: "text/html",
          body: """
              <p id="result"></p>
              <script>document.getElementById('result').textContent = document.cookie || 'no cookies';</script>
              <iframe src="http://sub.example.test"></iframe>
          """
        )
      end
    end)

    Page.goto!(page, "http://example.test")

    Expect.to_contain_text!(Page.locator(page, "body"), "testCookie=value")

    Expect.to_contain_text!(
      page |> Page.frame_locator("iframe") |> FrameLocator.locator("body"),
      "testCookie=value"
    )
  end
end
