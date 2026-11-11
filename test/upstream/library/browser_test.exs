defmodule PlaywrightEx.Library.BrowserTest do
  @upstream "tests/library/browser.spec.ts"
  # isolate: counts the contexts of `browser`.
  use PlaywrightEx.UpstreamCase, async: true, isolate: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime

  @k_target_closed_error_message "Target page, context or browser has been closed"

  test "BR-001 should return browserType", %{browser: browser, browser_type: browser_type} do
    assert Browser.browser_type(browser) == browser_type
  end

  test "BR-002 should create new page @smoke", %{browser: browser} do
    page1 = Browser.new_page!(browser)
    assert length(Browser.contexts(browser)) == 1

    page2 = Browser.new_page!(browser)
    assert length(Browser.contexts(browser)) == 2

    Page.close!(page1)
    assert length(Browser.contexts(browser)) == 1

    Page.close!(page2)
    assert Browser.contexts(browser) == []
  end

  test "BR-003 should throw upon second create new page", %{browser: browser} do
    page = Browser.new_page!(browser)
    {:error, error} = page |> Page.context() |> BrowserContext.new_page()
    Page.close!(page)
    assert Exception.message(error) =~ "Please use browser.newContext()"
  end

  test "BR-004 version should work", %{browser: browser, browser_name: browser_name} do
    version = Browser.version(browser)

    if browser_name == "chromium",
      do: assert(version =~ ~r/^\d+\.\d+\.\d+\.\d+$/),
      else: assert(version =~ ~r/^\d+\.\d+/)
  end

  test "BR-005 should dispatch page.on(close) upon browser.close and reject evaluate", %{browser_type: browser_type} do
    browser = BrowserType.launch!(browser_type)
    page = Browser.new_page!(browser)
    test = self()
    Page.on(page, :close, fn _ -> send(test, :closed) end)
    promise = Runtime.Promise.async(fn -> Page.evaluate(page, "() => new Promise(() => {})") end)
    Browser.close!(browser)
    assert_received :closed
    {:error, error} = Runtime.Promise.await(promise)
    assert Exception.message(error) =~ @k_target_closed_error_message
  end

  test "BR-006 should fire context event on newContext", %{browser: browser} do
    test = self()
    Browser.on(browser, :context, fn ctx -> send(test, {:context, ctx}) end)
    context = Browser.new_context!(browser)
    assert_received {:context, ^context}
    refute_received {:context, _}
    BrowserContext.close!(context)
  end

  test "BR-007 newContext should not leave a context upon failure"
end
