defmodule PlaywrightEx.Library.BrowsercontextCookiesThirdPartyTest do
  @upstream "tests/library/browsercontext-cookies-third-party.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @browser_name System.get_env("BROWSER", "chromium")

  # contextTest's `context`/`page` with `test.use({ ignoreHTTPSErrors: true })`; `contextFactory`
  # gets it too (upstream's runner applies it to every context it creates).
  setup %{context_factory: context_factory} do
    context_factory = fn options ->
      context_factory.(Keyword.merge([ignore_https_errors: true], options))
    end

    context = context_factory.([])
    %{context_factory: context_factory, context: context, page: BrowserContext.new_page!(context)}
  end

  setup %{https_server: https_server, browser_name: browser_name} do
    origin1 = https_server.prefix
    origin2 = https_server.cross_process_prefix

    %{
      urls: %{
        origin1: origin1,
        origin2: origin2,
        read_origin1: origin1 <> "/read-cookie.html",
        read_origin2_origin1: origin2 <> "/frame-read-cookie.html",
        read_origin1_origin1: origin1 <> "/frame-read-cookie.html",
        read_origin1_origin2_origin1: origin1 <> "/nested-frame-read-cookie.html",
        set_origin1: origin1 <> "/set-cookie.html",
        set_origin2_origin1: origin2 <> "/frame-set-cookie.html",
        set_origin1_origin2_origin1: origin1 <> "/nested-frame-set-cookie.html"
      },
      webkit_partitions: browser_name == "webkit" and mac?() and mac_version() >= 26
    }
  end

  defp mac?, do: match?({:unix, :darwin}, :os.type())
  defp linux?, do: match?({:unix, :linux}, :os.type())

  # platformFixtures `macVersion`: Darwin 25 = macOS 26.
  defp mac_version do
    {darwin_major, _, _} = :os.version()
    if darwin_major >= 25, do: darwin_major + 1, else: darwin_major - 9
  end

  # browserTest `allowsThirdParty`.
  defp allows_third_party(browser_name), do: browser_name == "firefox"

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  defp html(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, body)

  defp add_common_cookie_handlers(https_server, urls) do
    # '/set-cookie.html' handlers are added in the tests.
    TestServer.set_route(https_server, "/read-cookie.html", fn conn ->
      cookies =
        case header(conn, "cookie") do
          nil ->
            "undefined"

          cookie ->
            cookie
            |> String.split(";")
            |> Enum.map(&String.trim/1)
            |> Enum.sort()
            |> Enum.join("; ")
        end

      html(conn, "Received cookie: #{cookies}")
    end)

    TestServer.set_route(https_server, "/frame-set-cookie.html", fn conn ->
      html(conn, "<iframe src='#{urls.origin1}/set-cookie.html'></iframe>")
    end)

    TestServer.set_route(https_server, "/frame-read-cookie.html", fn conn ->
      html(conn, "<iframe src='#{urls.origin1}/read-cookie.html'></iframe>")
    end)

    # Nested cross-origin iframe:
    #   main frame: (origin1 or origin2) -> iframe1: origin2 -> iframe2: origin1
    TestServer.set_route(https_server, "/nested-frame-set-cookie.html", fn conn ->
      html(conn, "<iframe src='#{urls.origin2}/frame-set-cookie.html'></iframe>")
    end)

    TestServer.set_route(https_server, "/nested-frame-read-cookie.html", fn conn ->
      html(conn, "<iframe src='#{urls.origin2}/frame-read-cookie.html'></iframe>")
    end)
  end

  defp body_text(page), do: Locator.text_content!(Page.locator(page, "body"))

  defp frame_body(page),
    do: page |> Page.locator("iframe") |> Locator.content_frame() |> FrameLocator.locator("body")

  defp nested_frame_body(page) do
    page
    |> Page.locator("iframe")
    |> Locator.content_frame()
    |> FrameLocator.locator("iframe")
    |> Locator.content_frame()
    |> FrameLocator.locator("body")
  end

  # findCookie + expectPartitionKey
  defp expect_partition_key(cookies, name, partition_key) do
    cookie = Enum.find(cookies, &(&1.name == name))
    assert cookie, "Cookie #{name} not found in #{inspect(cookies, pretty: true)}"

    if partition_key != cookie[:partitionKey],
      do:
        flunk(
          "Cookie #{name} has partitionKey #{inspect(cookie[:partitionKey])} but expected #{inspect(partition_key)}."
        )
  end

  # '/set-cookie.html' setting `<name><suffix>=value; ... Partitioned;` and `<name>-non-partitioned=value`.
  defp set_partitioned_cookies(https_server, suffix) do
    TestServer.set_route(https_server, "/set-cookie.html", fn conn ->
      name = if header(conn, "referer"), do: "frame", else: "top-level"

      conn
      |> Plug.Conn.prepend_resp_headers([
        {"set-cookie", "#{name}#{suffix}=value; SameSite=None; Path=/; Secure; Partitioned;"},
        {"set-cookie", "#{name}-non-partitioned=value; SameSite=None; Path=/; Secure;"}
      ])
      |> Plug.Conn.send_resp(200, "")
    end)
  end

  defp run_non_partitioned_test(page, https_server, browser_name, urls) do
    add_common_cookie_handlers(https_server, urls)

    TestServer.set_route(https_server, "/set-cookie.html", fn conn ->
      name = if header(conn, "referer"), do: "frame", else: "top-level"

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "#{name}=value; SameSite=None; Path=/; Secure;")
      |> html("")
    end)

    Page.goto!(page, urls.set_origin1)
    Page.goto!(page, urls.read_origin1)
    assert body_text(page) == "Received cookie: top-level=value"

    Page.goto!(page, urls.read_origin2_origin1)
    frame_body = frame_body(page)

    # WebKit does not support third-party cookies without a 'Partition' attribute.
    if browser_name == "webkit" and mac?(),
      do: Expect.to_have_text!(frame_body, "Received cookie: undefined"),
      else: Expect.to_have_text!(frame_body, "Received cookie: top-level=value")

    # Set cookie and do second navigation.
    Page.goto!(page, urls.set_origin2_origin1)
    Page.goto!(page, urls.read_origin2_origin1)

    expected_third_party = "Received cookie: " <> non_partitioned_third_party(browser_name)
    Expect.to_have_text!(frame_body, expected_third_party, timeout: 1000)

    # Check again the top-level cookie.
    Page.goto!(page, urls.read_origin1)

    expected_top_level = non_partitioned_top_level(browser_name)
    assert body_text(page) == expected_top_level

    %{expected_top_level: expected_top_level, expected_third_party: expected_third_party}
  end

  defp non_partitioned_third_party(browser_name) do
    cond do
      browser_name == "webkit" and mac?() -> "undefined"
      browser_name == "webkit" and linux?() -> "top-level=value"
      true -> "frame=value; top-level=value"
    end
  end

  defp non_partitioned_top_level(browser_name) do
    if browser_name == "webkit" and (mac?() or linux?()),
      do: "Received cookie: top-level=value",
      else: "Received cookie: frame=value; top-level=value"
  end

  test "CO-052 third party non-partitioned cookies", %{
    page: page,
    browser_name: browser_name,
    https_server: https_server,
    urls: urls
  } do
    run_non_partitioned_test(page, https_server, browser_name, urls)
  end

  test "CO-053 save/load third party non-partitioned cookies", %{
    page: page,
    browser_name: browser_name,
    https_server: https_server,
    context_factory: context_factory,
    urls: urls
  } do
    # Run the test to populate the cookies.
    %{expected_top_level: expected_top_level, expected_third_party: expected_third_party} =
      run_non_partitioned_test(page, https_server, browser_name, urls)

    check_cookies = fn page ->
      # Check top-level cookie first.
      Page.goto!(page, urls.read_origin1)
      assert body_text(page) == expected_top_level

      # Check third-party cookie.
      Page.goto!(page, urls.read_origin2_origin1)
      Expect.to_have_text!(frame_body(page), expected_third_party)
    end

    check_cookies.(page)

    # test.step('export via cookies/addCookies')
    cookies = BrowserContext.cookies!(Page.context(page))
    context2 = context_factory.([])
    BrowserContext.add_cookies!(context2, cookies)
    check_cookies.(BrowserContext.new_page!(context2))

    # test.step('export via storageState')
    storage_state = BrowserContext.storage_state!(Page.context(page))
    context3 = context_factory.(storage_state: storage_state)
    check_cookies.(BrowserContext.new_page!(context3))
  end

  defp run_partitioned_test(page, https_server, browser_name, webkit_partitions, urls) do
    add_common_cookie_handlers(https_server, urls)

    TestServer.set_route(https_server, "/set-cookie.html", fn conn ->
      name = if header(conn, "referer"), do: "frame", else: "top-level"

      conn
      |> Plug.Conn.prepend_resp_headers([
        {"set-cookie", "#{name}-partitioned=value; SameSite=None; Path=/; Secure; Partitioned;"},
        {"set-cookie", "#{name}-non-partitioned=value; SameSite=None; Path=/; Secure;"}
      ])
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, urls.set_origin1)
    Page.goto!(page, urls.read_origin1)

    assert body_text(page) ==
             "Received cookie: top-level-non-partitioned=value; top-level-partitioned=value"

    Page.goto!(page, urls.read_origin2_origin1)
    frame_body = frame_body(page)

    # Firefox cookie partitioning is disabled in Firefox(Juggler).
    # Upstream to-do: reenable cookie partitioning?
    # Linux and Windows WebKit builds do not partition third-party cookies at all.
    if browser_name == "firefox" or (browser_name == "webkit" and !mac?()) do
      Expect.to_have_text!(
        frame_body,
        "Received cookie: top-level-non-partitioned=value; top-level-partitioned=value"
      )
    else
      run_partitioned_test_partitioning(page, frame_body, browser_name, webkit_partitions, urls)
    end
  end

  defp run_partitioned_test_partitioning(page, frame_body, browser_name, webkit_partitions, urls) do
    if browser_name == "webkit" do
      # WebKit will only send 'Partitioned' third-party cookies exactly matching the partition.
      Expect.to_have_text!(frame_body, "Received cookie: undefined")
    else
      # For non-partitioned cookies, the cookie is sent to the iframe right away,
      # if third-party cookies are supported by the browser.
      Expect.to_have_text!(frame_body, "Received cookie: top-level-non-partitioned=value")
    end

    # First navigation:
    # - no cookie sent, as it was only set on the top-level site
    # - sets the third-party cookie for the top-level context
    # Second navigation:
    # - sends the cookie as it was just set for the (top-level site, iframe url) partition.
    Page.goto!(page, urls.set_origin2_origin1)
    Page.goto!(page, urls.read_origin2_origin1)

    cond do
      browser_name == "webkit" and webkit_partitions ->
        Expect.to_have_text!(frame_body, "Received cookie: frame-partitioned=value")

      browser_name == "webkit" ->
        Expect.to_have_text!(frame_body, "Received cookie: undefined")

      true ->
        Expect.to_have_text!(
          frame_body,
          "Received cookie: frame-non-partitioned=value; frame-partitioned=value; top-level-non-partitioned=value"
        )
    end
  end

  test "CO-054 third party 'Partitioned;' cookies", %{
    page: page,
    browser_name: browser_name,
    https_server: https_server,
    webkit_partitions: webkit_partitions,
    urls: urls
  } do
    run_partitioned_test(page, https_server, browser_name, webkit_partitions, urls)
  end

  @tag skip:
         (cond do
            @browser_name == "firefox" ->
              "upstream fixme: Firefox cookie partitioning is disabled in Firefox(Juggler)."

            @browser_name == "webkit" and not match?({:unix, :darwin}, :os.type()) ->
              "upstream fixme: Linux and Windows WebKit builds do not partition third-party cookies at all."

            true ->
              false
          end)
  test "CO-055 save/load third party 'Partitioned;' cookies", %{
    page: page,
    browser_name: browser_name,
    https_server: https_server,
    webkit_partitions: webkit_partitions,
    context_factory: context_factory,
    urls: urls
  } do
    run_partitioned_test(page, https_server, browser_name, webkit_partitions, urls)

    check_cookies = fn page ->
      # Check top-level cookie first.
      Page.goto!(page, urls.read_origin1)

      expected_top_level =
        if browser_name == "webkit" and mac?(),
          do: "Received cookie: top-level-non-partitioned=value; top-level-partitioned=value",
          else:
            "Received cookie: frame-non-partitioned=value; top-level-non-partitioned=value; top-level-partitioned=value"

      assert body_text(page) == expected_top_level

      # Check third-party cookie.
      Page.goto!(page, urls.read_origin2_origin1)

      expected_third_party =
        cond do
          browser_name == "webkit" and webkit_partitions ->
            "Received cookie: frame-partitioned=value"

          browser_name == "webkit" ->
            "Received cookie: undefined"

          true ->
            "Received cookie: frame-non-partitioned=value; frame-partitioned=value; top-level-non-partitioned=value"
        end

      Expect.to_have_text!(frame_body(page), expected_third_party, timeout: 1000)

      # read-origin1-origin2-origin1.html
      Page.goto!(page, urls.read_origin1_origin2_origin1)

      expected_third_party =
        if browser_name == "webkit",
          do: "Received cookie: top-level-non-partitioned=value; top-level-partitioned=value",
          else: "Received cookie: frame-non-partitioned=value; top-level-non-partitioned=value"

      Expect.to_have_text!(nested_frame_body(page), expected_third_party, timeout: 1000)
    end

    check_cookies.(page)

    check_storage_cookies = fn cookies ->
      webkit_no_partition = browser_name == "webkit" and !webkit_partitions

      expect_partition_key(
        cookies,
        "top-level-partitioned",
        if(webkit_no_partition, do: nil, else: "https://localhost")
      )

      expect_partition_key(cookies, "top-level-non-partitioned", nil)

      if webkit_no_partition do
        refute Enum.find(cookies, &(&1.name == "frame-partitioned"))
        refute Enum.find(cookies, &(&1.name == "frame-non-partitioned"))
      else
        expect_partition_key(cookies, "frame-partitioned", "https://127.0.0.1")

        if browser_name == "webkit",
          do: refute(Enum.find(cookies, &(&1.name == "frame-non-partitioned"))),
          else: expect_partition_key(cookies, "frame-non-partitioned", nil)
      end
    end

    check_storage_cookies.(BrowserContext.cookies!(Page.context(page)))
    check_storage_cookies.(BrowserContext.storage_state!(Page.context(page)).cookies)

    # test.step('export via cookies/addCookies')
    cookies = BrowserContext.cookies!(Page.context(page))
    context2 = context_factory.([])
    BrowserContext.add_cookies!(context2, cookies)
    check_cookies.(BrowserContext.new_page!(context2))

    # test.step('export via storageState')
    storage_state = BrowserContext.storage_state!(Page.context(page))
    context3 = context_factory.(storage_state: storage_state)
    check_cookies.(BrowserContext.new_page!(context3))
  end

  test "CO-056 add 'Partitioned;' cookie via API", %{
    page: page,
    context: context,
    browser_name: browser_name,
    https_server: https_server,
    webkit_partitions: webkit_partitions,
    urls: urls
  } do
    add_common_cookie_handlers(https_server, urls)

    BrowserContext.add_cookies!(context, [
      %{
        name: "top-level-partitioned",
        value: "value",
        domain: https_server.hostname,
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: true,
        sameSite: "None",
        partitionKey: "https://localhost",
        _crHasCrossSiteAncestor: false
      },
      %{
        name: "top-level-non-partitioned",
        value: "value",
        domain: https_server.hostname,
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: true,
        sameSite: "None"
      },
      %{
        name: "frame-partitioned",
        value: "value",
        domain: https_server.hostname,
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: true,
        sameSite: "None",
        partitionKey: "https://127.0.0.1",
        _crHasCrossSiteAncestor: true
      },
      %{
        name: "frame-non-partitioned",
        value: "value",
        domain: https_server.hostname,
        path: "/",
        expires: -1,
        httpOnly: false,
        secure: true,
        sameSite: "None"
      }
    ])

    check_cookies = fn page ->
      # Check top-level cookie first.
      Page.goto!(page, urls.read_origin1)

      expected_top_level =
        cond do
          browser_name == "webkit" and mac?() and !webkit_partitions ->
            "Received cookie: frame-non-partitioned=value; top-level-non-partitioned=value"

          (browser_name == "webkit" and !webkit_partitions) or browser_name == "firefox" ->
            "Received cookie: frame-non-partitioned=value; frame-partitioned=value; top-level-non-partitioned=value; top-level-partitioned=value"

          true ->
            "Received cookie: frame-non-partitioned=value; top-level-non-partitioned=value; top-level-partitioned=value"
        end

      assert body_text(page) == expected_top_level

      # Check third-party cookie.
      Page.goto!(page, urls.read_origin2_origin1)

      expected_third_party =
        "Received cookie: " <>
          cond do
            webkit_partitions ->
              "frame-partitioned=value"

            browser_name == "webkit" and mac?() ->
              "undefined"

            browser_name == "chromium" ->
              "frame-non-partitioned=value; frame-partitioned=value; top-level-non-partitioned=value"

            # Firefox(Juggler) and WebKit on Linux/Windows do not partition third-party cookies.
            true ->
              "frame-non-partitioned=value; frame-partitioned=value; top-level-non-partitioned=value; top-level-partitioned=value"
          end

      Expect.to_have_text!(frame_body(page), expected_third_party, timeout: 1000)

      # read-origin1-origin2-origin1.html
      Page.goto!(page, urls.read_origin1_origin2_origin1)

      frame_body =
        page
        |> Page.locator("iframe")
        |> Locator.content_frame()
        |> FrameLocator.locator("iframe")
        |> Locator.content_frame()
        |> FrameLocator.locator("body")

      expected_third_party =
        "Received cookie: " <>
          cond do
            webkit_partitions ->
              "frame-non-partitioned=value; top-level-non-partitioned=value; top-level-partitioned=value"

            browser_name == "webkit" and mac?() ->
              "frame-non-partitioned=value; top-level-non-partitioned=value"

            browser_name in ["webkit", "firefox"] ->
              "frame-non-partitioned=value; frame-partitioned=value; top-level-non-partitioned=value; top-level-partitioned=value"

            true ->
              "frame-non-partitioned=value; top-level-non-partitioned=value"
          end

      Expect.to_have_text!(frame_body, expected_third_party, timeout: 1000)
    end

    check_cookies.(page)
  end

  test "CO-057 same origin third party 'Partitioned;' cookie with different origin intermediate iframe", %{
    page: page,
    https_server: https_server,
    context_factory: context_factory,
    urls: urls
  } do
    add_common_cookie_handlers(https_server, urls)
    set_partitioned_cookies(https_server, "-partitioned")
    # main frame: origin1 -> iframe1: origin2 -> iframe2: origin1
    # In this case the cookie in iframe2 is a third-party partitioned cookie, even though
    # it's the same origin as the main frame.
    Page.goto!(page, urls.set_origin1_origin2_origin1)

    check_cookies = fn page ->
      Page.goto!(page, urls.read_origin1_origin2_origin1)

      Expect.to_have_text!(
        nested_frame_body(page),
        "Received cookie: frame-non-partitioned=value; frame-partitioned=value"
      )
    end

    check_cookies.(page)

    # test.step('export via cookies/addCookies')
    cookies = BrowserContext.cookies!(Page.context(page))
    context2 = context_factory.([])
    BrowserContext.add_cookies!(context2, cookies)
    check_cookies.(BrowserContext.new_page!(context2))

    # test.step('export via storageState')
    storage_state = BrowserContext.storage_state!(Page.context(page))
    context3 = context_factory.(storage_state: storage_state)
    check_cookies.(BrowserContext.new_page!(context3))
  end

  @tag :tmp_dir
  test "CO-058 top level 'Partitioned;' cookie and same origin iframe", %{
    page: page,
    browser_name: browser_name,
    https_server: https_server,
    context_factory: context_factory,
    urls: urls,
    tmp_dir: tmp_dir
  } do
    add_common_cookie_handlers(https_server, urls)
    set_partitioned_cookies(https_server, "")

    # Same origin iframe cookies are partitioned the same way as top-level cookies.
    Page.goto!(page, urls.set_origin1)
    BrowserContext.storage_state!(Page.context(page), path: Path.join(tmp_dir, "state2.json"))

    check_cookies = fn page ->
      # Check top-level cookie first.
      Page.goto!(page, urls.read_origin1)
      assert body_text(page) == "Received cookie: top-level-non-partitioned=value; top-level=value"

      # Same origin iframe.
      Page.goto!(page, urls.read_origin1_origin1)

      Expect.to_have_text!(frame_body(page), "Received cookie: top-level-non-partitioned=value; top-level=value",
        timeout: 1000
      )

      # Check third-party cookie.
      # main frame: origin1 -> iframe1: origin2 -> iframe2: origin1
      Page.goto!(page, urls.read_origin1_origin2_origin1)

      expected_third_party =
        "Received cookie: " <>
          if(browser_name == "chromium",
            do: "top-level-non-partitioned=value",
            else: "top-level-non-partitioned=value; top-level=value"
          )

      Expect.to_have_text!(nested_frame_body(page), expected_third_party, timeout: 1000)
    end

    check_cookies.(page)

    # test.step('export via cookies/addCookies')
    cookies = BrowserContext.cookies!(Page.context(page))
    context2 = context_factory.([])
    BrowserContext.add_cookies!(context2, cookies)
    check_cookies.(BrowserContext.new_page!(context2))

    # test.step('export via storageState')
    storage_state = BrowserContext.storage_state!(Page.context(page))
    context3 = context_factory.(storage_state: storage_state)
    check_cookies.(BrowserContext.new_page!(context3))
  end

  @tag skip:
         if(System.get_env("BROWSER") == "webkit" and match?({:unix, :darwin}, :os.type()),
           do: "upstream fixme: webkit on mac"
         )
  test "CO-059 should be able to send third party cookies via an iframe", %{
    browser: browser,
    https_server: https_server
  } do
    context = Browser.new_context!(browser, ignore_https_errors: true)

    try do
      page = BrowserContext.new_page!(context)
      Page.goto!(page, https_server.empty_page)

      BrowserContext.add_cookies!(context, [
        %{
          domain: URI.parse(https_server.cross_process_prefix).host,
          path: "/",
          name: "cookie1",
          value: "yes",
          httpOnly: true,
          secure: true,
          sameSite: "None"
        }
      ])

      response = TestServer.wait_for_request(https_server, "/grid.html")

      Page.set_content!(
        page,
        ~s(<iframe src="#{https_server.cross_process_prefix}/grid.html"></iframe>)
      )

      assert header(Task.await(response, :infinity), "cookie") == "cookie1=yes"
    after
      BrowserContext.close!(context)
    end
  end

  test "CO-060 should(not) block third party cookies - persistent context", %{
    https_server: https_server,
    launch_persistent: launch_persistent,
    browser_name: browser_name
  } do
    # Upstream's runner applies `test.use` options to every context it creates (runBeforeCreateBrowserContext).
    %{page: page, context: context} = launch_persistent.(ignore_https_errors: true)
    test_third_party_cookies_are_blocked(page, context, https_server, browser_name)
  end

  test "CO-061 should(not) block third party cookies - ephemeral context", %{
    page: page,
    context: context,
    https_server: https_server,
    browser_name: browser_name
  } do
    test_third_party_cookies_are_blocked(page, context, https_server, browser_name)
  end

  defp test_third_party_cookies_are_blocked(page, context, server, browser_name) do
    allows_third_party = allows_third_party(browser_name)
    Page.goto!(page, server.empty_page)

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
      server.cross_process_prefix <> "/grid.html"
    )

    document_cookie =
      Frame.evaluate!(Enum.at(Page.frames(page), 1), """
      () => {
        document.cookie = 'username=John Doe';
        return document.cookie;
      }
      """)

    Page.wait_for_timeout!(page, 2000)
    assert document_cookie == if(allows_third_party, do: "username=John Doe", else: "")
    cookies = BrowserContext.cookies!(context, server.cross_process_prefix <> "/grid.html")

    if allows_third_party do
      assert cookies == [
               %{
                 domain: "127.0.0.1",
                 expires: -1,
                 httpOnly: false,
                 name: "username",
                 path: "/",
                 sameSite: default_same_site_cookie_value(browser_name),
                 secure: false,
                 value: "John Doe"
               }
             ]
    else
      assert cookies == []
    end
  end

  @tag skip: if(System.get_env("BROWSER") == "webkit", do: "upstream skip: No third party cookies in WebKit")
  test "CO-062 should not block third party SameSite=None cookies", %{
    context_factory: context_factory,
    https_server: https_server
  } do
    context = context_factory.(ignore_https_errors: true)
    page = BrowserContext.new_page!(context)

    TestServer.set_route(https_server, "/empty.html", fn conn ->
      html(conn, ~s(<iframe src="#{https_server.cross_process_prefix}/grid.html"></iframe>))
    end)

    TestServer.set_route(https_server, "/grid.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "set-cookie",
        "a=b; Path=/; Max-Age=3600; SameSite=None; Secure"
      )
      |> html("""
      Hello world
          <script>
          setTimeout(() => fetch('/json'), 1000);
          </script>
      """)
    end)

    test = self()

    TestServer.set_route(https_server, "/json", fn conn ->
      send(test, {:cookie, header(conn, "cookie")})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.goto!(page, https_server.empty_page)
    assert_receive {:cookie, cookie}, 5000
    assert cookie == "a=b"
  end
end
