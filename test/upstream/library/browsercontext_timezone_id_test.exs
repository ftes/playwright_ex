defmodule PlaywrightEx.Library.BrowsercontextTimezoneIdTest do
  @upstream "tests/library/browsercontext-timezone-id.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Page

  test "should work @smoke", %{browser: browser, browser_name: browser_name} do
    # Note: timezone names are rendered differently between browsers and platforms,
    # so we only check the GMT offset.
    # expect.soft: the first failure ends the test here.
    func = "() => new Date(1479579154987).toString()"

    context = Browser.new_context!(browser, locale: "en-US", timezone_id: "America/Jamaica")
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, func) =~ "Sat Nov 19 2016 13:12:34 GMT-0500"
    BrowserContext.close!(context)

    context = Browser.new_context!(browser, locale: "en-US", timezone_id: "Pacific/Honolulu")
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, func) =~ "Sat Nov 19 2016 08:12:34 GMT-1000"
    BrowserContext.close!(context)

    timezone_id = if browser_name == "firefox", do: "America/Argentina/Buenos_Aires", else: "America/Buenos_Aires"
    context = Browser.new_context!(browser, locale: "en-US", timezone_id: timezone_id)
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, func) =~ "Sat Nov 19 2016 15:12:34 GMT-0300"
    BrowserContext.close!(context)

    context = Browser.new_context!(browser, locale: "en-US", timezone_id: "Europe/Berlin")
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, func) =~ "Sat Nov 19 2016 19:12:34 GMT+0100"
    BrowserContext.close!(context)
  end

  test "should throw for invalid timezone IDs when creating pages", %{browser: browser} do
    # isBidi: browser.newContext({ timezoneId }) rejects with a browser-specific message.
    for timezone_id <- ["Foo/Bar", "Baz/Qux"] do
      {context, error} =
        case Browser.new_context(browser, timezone_id: timezone_id) do
          {:ok, context} ->
            case BrowserContext.new_page(context) do
              {:ok, _page} -> {context, nil}
              {:error, error} -> {context, error}
            end

          {:error, error} ->
            {nil, error}
        end

      assert Exception.message(error) =~ "Invalid timezone ID: #{timezone_id}"
      if context, do: BrowserContext.close!(context)
    end
  end

  test "should work for multiple pages sharing same process", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, timezone_id: "Europe/Moscow")
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

  test "should not change default timezone in another context", %{browser: browser} do
    get_context_timezone = fn context ->
      page = BrowserContext.new_page!(context)
      Page.evaluate!(page, "() => Intl.DateTimeFormat().resolvedOptions().timeZone")
    end

    context = Browser.new_context!(browser)
    default_timezone = get_context_timezone.(context)
    BrowserContext.close!(context)

    timezone_override = if default_timezone == "Europe/Moscow", do: "America/Los_Angeles", else: "Europe/Moscow"

    context = Browser.new_context!(browser, timezone_id: timezone_override)
    assert get_context_timezone.(context) == timezone_override
    BrowserContext.close!(context)

    context = Browser.new_context!(browser)
    assert get_context_timezone.(context) == default_timezone
    BrowserContext.close!(context)
  end

  test "should affect Intl.DateTimeFormat().resolvedOptions().timeZone", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, timezone_id: "America/Jamaica")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => (new Intl.DateTimeFormat()).resolvedOptions().timeZone") == "America/Jamaica"
    BrowserContext.close!(context)
  end

  test "should propagate timezone to workers", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, timezone_id: "America/Jamaica")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    msg =
      Page.expect_console_message!(page, fn ->
        Page.evaluate!(page, """
        () => new Worker(URL.createObjectURL(new Blob(['console.log(Intl.DateTimeFormat().resolvedOptions().timeZone)'], { type: 'application/javascript' })))
        """)
      end)

    assert ConsoleMessage.text(msg) == "America/Jamaica"
    BrowserContext.close!(context)
  end
end
