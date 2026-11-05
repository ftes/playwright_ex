defmodule PlaywrightEx.Library.BrowsercontextLocaleTest do
  @upstream "tests/library/browsercontext-locale.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  test "should affect accept-language header @smoke", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, locale: "fr-CH")
    page = BrowserContext.new_page!(context)
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    request = Task.await(request, :infinity)
    assert String.slice(header(request, "accept-language"), 0, 5) == "fr-CH"
    BrowserContext.close!(context)
  end

  test "should affect navigator.language", %{browser: browser} do
    context = Browser.new_context!(browser, locale: "fr-FR")
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "() => navigator.language") == "fr-FR"
    BrowserContext.close!(context)
  end

  test "should format number", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, locale: "en-US")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => (1000000.50).toLocaleString()") == "1,000,000.5"
    BrowserContext.close!(context)

    context = Browser.new_context!(browser, locale: "fr-FR")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => (1000000.50).toLocaleString().replace(/\\s/g, ' ')") == "1 000 000,5"
    BrowserContext.close!(context)
  end

  test "should format date", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, locale: "en-US", timezone_id: "America/Los_Angeles")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    formatted = "Sat Nov 19 2016 10:12:34 GMT-0800 (Pacific Standard Time)"
    assert Page.evaluate!(page, "() => new Date(1479579154987).toString()") == formatted
    BrowserContext.close!(context)

    context = Browser.new_context!(browser, locale: "de-DE", timezone_id: "Europe/Berlin")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    formatted = "Sat Nov 19 2016 19:12:34 GMT+0100 (Mitteleuropäische Normalzeit)"
    assert Page.evaluate!(page, "() => new Date(1479579154987).toString()") == formatted
    BrowserContext.close!(context)
  end

  test "should format number in popups", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, locale: "fr-FR")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => window.open(url)", server.prefix <> "/formatted-number.html")
      end)

    Page.wait_for_load_state!(popup, :domcontentloaded)
    result = Page.evaluate!(popup, ~s|window["result"]|)
    assert result == "1 000 000,5"
    BrowserContext.close!(context)
  end

  test "should affect navigator.language in popups", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, locale: "fr-FR")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => window.open(url)", server.prefix <> "/formatted-number.html")
      end)

    Page.wait_for_load_state!(popup, :domcontentloaded)
    result = Page.evaluate!(popup, "window.initialNavigatorLanguage")
    assert result == "fr-FR"
    BrowserContext.close!(context)
  end

  test "should work for multiple pages sharing same process", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, locale: "ru-RU")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => { window.open(url); }", server.empty_page)
      end)

    Page.expect_popup!(popup, fn ->
      Page.evaluate!(popup, "url => { window.open(url); }", server.empty_page)
    end)

    BrowserContext.close!(context)
  end

  # it.slow()
  @tag timeout: @slow_timeout
  test "should be isolated between contexts", %{browser: browser} do
    context1 = Browser.new_context!(browser, locale: "en-US")
    # By default firefox limits number of child web processes to 8.
    1..8
    |> Enum.map(fn _ -> Task.async(fn -> BrowserContext.new_page!(context1) end) end)
    |> Task.await_many(60_000)

    context2 = Browser.new_context!(browser, locale: "ru-RU")
    page2 = BrowserContext.new_page!(context2)

    locale_number = "() => (1000000.50).toLocaleString()"

    numbers =
      context1
      |> BrowserContext.pages()
      |> Enum.map(fn page -> Task.async(fn -> Page.evaluate!(page, locale_number) end) end)
      |> Task.await_many(60_000)

    Enum.each(numbers, fn value -> assert value == "1,000,000.5" end)
    assert Page.evaluate!(page2, locale_number) == "1\u00A0000\u00A0000,5"

    [context1, context2]
    |> Enum.map(&Task.async(fn -> BrowserContext.close!(&1) end))
    |> Task.await_many(60_000)
  end

  test "should not change default locale in another context", %{browser: browser} do
    get_context_locale = fn context ->
      page = BrowserContext.new_page!(context)
      Page.evaluate!(page, "() => (new Intl.NumberFormat()).resolvedOptions().locale")
    end

    context = Browser.new_context!(browser)
    default_locale = get_context_locale.(context)
    BrowserContext.close!(context)

    locale_override = if default_locale == "es-MX", do: "de-DE", else: "es-MX"

    context = Browser.new_context!(browser, locale: locale_override)
    assert get_context_locale.(context) == locale_override
    BrowserContext.close!(context)

    context = Browser.new_context!(browser)
    assert get_context_locale.(context) == default_locale
    BrowserContext.close!(context)
  end

  test "should propagate locale to workers", %{browser: browser, browser_name: browser_name, server: server} do
    context = Browser.new_context!(browser, locale: "ru-RU")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    msg =
      Page.expect_console_message!(
        page,
        fn ->
          Page.evaluate!(page, """
          () => new Worker(URL.createObjectURL(new Blob(['console.log("locale:" + Intl.NumberFormat().resolvedOptions().locale)'], { type: 'application/javascript' })))
          """)
        end,
        predicate: &String.starts_with?(ConsoleMessage.text(&1), "locale:")
      )

    if browser_name == "webkit",
      # Webkit on Ubuntu is "ru-RU", and on other platforms is "ru"
      do: assert(ConsoleMessage.text(msg) =~ "locale:ru"),
      else: assert(ConsoleMessage.text(msg) == "locale:ru-RU")

    BrowserContext.close!(context)
  end

  test "should affect Intl.DateTimeFormat().resolvedOptions().locale", %{browser: browser, server: server} do
    # https://github.com/microsoft/playwright/issues/27802
    context = Browser.new_context!(browser, locale: "en-GB")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => (new Intl.DateTimeFormat()).resolvedOptions().locale") == "en-GB"
    BrowserContext.close!(context)
  end

  test "should send user Accept-Language header", %{browser: browser, server: server} do
    # https://github.com/microsoft/playwright/issues/23732
    context = Browser.new_context!(browser, locale: "en-GB")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    req_promise = TestServer.wait_for_request(server, "/empty.html")

    Page.evaluate!(
      page,
      """
      async url => {
        await fetch(url, {
          headers: {
            'Content-Type': 'application/json',
            'Accept-Language': 'de'
          },
        });
      }
      """,
      server.empty_page
    )

    req = Task.await(req_promise, :infinity)
    assert header(req, "accept-language") == "de"

    req_promise = TestServer.wait_for_request(server, "/empty.html")

    Page.evaluate!(
      page,
      """
      async url => {
        await fetch(url, {
          headers: {
            'Content-Type': 'application/json'
          },
        });
      }
      """,
      server.empty_page
    )

    req = Task.await(req_promise, :infinity)
    assert header(req, "accept-language") =~ "en-GB"
    BrowserContext.close!(context)
  end

  test "should send Accept-Language header on WebSocket handshake", %{browser: browser, server: server} do
    # https://github.com/microsoft/playwright/issues/23732
    # it.fixme(browserName === 'chromium' && browserMajorVersion < 151, ...)  -- the pinned Chromium is newer
    context = Browser.new_context!(browser, locale: "en-GB")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    req_promise = TestServer.wait_for_web_socket_connection_request(server)
    Page.evaluate!(page, "port => { new WebSocket(`ws://localhost:${port}/ws`); }", server.port)
    req = Task.await(req_promise, :infinity)
    assert header(req, "accept-language") =~ "en-GB"
    BrowserContext.close!(context)
  end

  test "should send Accept-Language header on WebSocket handshake from a worker", %{browser: browser, server: server} do
    # https://github.com/microsoft/playwright/issues/13919
    # it.fixme(browserName === 'chromium' && browserMajorVersion < 151, ...)  -- the pinned Chromium is newer
    context = Browser.new_context!(browser, locale: "en-GB")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    req_promise = TestServer.wait_for_web_socket_connection_request(server)

    Page.evaluate!(
      page,
      """
      port => {
        const code = `new WebSocket(${JSON.stringify(`ws://localhost:${port}/ws`)});`;
        new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
      }
      """,
      server.port
    )

    req = Task.await(req_promise, :infinity)
    assert header(req, "accept-language") =~ "en-GB"
    BrowserContext.close!(context)
  end
end
