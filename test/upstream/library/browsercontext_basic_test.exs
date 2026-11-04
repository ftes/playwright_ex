defmodule PlaywrightEx.Library.BrowsercontextBasicTest do
  @upstream "tests/library/browsercontext-basic.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext

  test "should create new context @smoke", %{browser: browser} do
    assert Browser.contexts(browser) == []
    context = Browser.new_context!(browser)
    assert Browser.contexts(browser) == [context]
    assert browser == BrowserContext.browser(context)
    context2 = Browser.new_context!(browser)
    assert Browser.contexts(browser) == [context, context2]
    BrowserContext.close!(context)
    assert Browser.contexts(browser) == [context2]
    assert browser == BrowserContext.browser(context)
    BrowserContext.close!(context2)
  end

  @tag skip: "not ported: Locator"
  test "should be able to click across browser contexts"

  @tag skip: "not ported: Locator"
  test "should be able to hover across browser contexts in parallel"

  @tag skip: "not ported: waitForEvent"
  test "window.open should use parent tab context"

  @tag skip: "not ported: Page"
  test "should isolate localStorage and cookies @smoke"

  @tag skip: "not ported: Page"
  test "should propagate default viewport to the page"

  @tag skip: "not ported: Page"
  test "should make a copy of default viewport"

  @tag skip: "not ported: Page"
  test "should respect deviceScaleFactor"

  test "should not allow deviceScaleFactor with null viewport", %{browser: browser} do
    {:error, error} = Browser.new_context(browser, viewport: :null, device_scale_factor: 1)
    assert Exception.message(error) =~ ~s("deviceScaleFactor" option is not supported with null "viewport")
  end

  test "should not allow isMobile with null viewport", %{browser: browser} do
    {:error, error} = Browser.new_context(browser, viewport: :null, is_mobile: true)
    assert Exception.message(error) =~ ~s("isMobile" option is not supported with null "viewport")
  end

  test "close() should work for empty context", %{browser: browser} do
    context = Browser.new_context!(browser)
    BrowserContext.close!(context)
  end

  @tag skip: "not ported: waitForEvent"
  test "close() should abort waitForEvent"

  test "close() should be callable twice", %{browser: browser} do
    context = Browser.new_context!(browser)
    BrowserContext.close!(context)
    BrowserContext.close!(context)
  end

  @tag skip: "not ported: waitForEvent"
  test "should pass self to close event"

  @tag skip: "not ported: Locator"
  test "should not report frameless pages on error"

  @tag skip: "not ported: Page"
  test "should return all of the pages"

  @tag skip: "not ported: Page"
  test "should close all belonging pages once closing context"

  @tag skip: "not ported: Page"
  test "should disable javascript"

  @tag skip: "not ported: Page"
  test "should be able to navigate after disabling javascript"

  @tag skip: "not ported: Page"
  test "should not hang on promises after disabling javascript"

  @tag skip: "not ported: Locator, expect"
  test "setContent should work after disabling javascript"

  @tag skip: "not ported: Locator, expect"
  test "should retry click after disabling javascript"

  @tag skip: "not ported: Page"
  test "should work with offline option"

  @tag skip: "not ported: Page"
  test "fetch with keepalive should throw when offline"

  @tag skip: "not ported: Page"
  test "should emulate navigator.onLine"

  @tag skip: "not ported: route"
  test "should emulate navigator.onLine across navigations"

  @tag skip: "not ported: evaluateHandle, expect.poll"
  test "should emulate offline event"

  @tag skip: "not ported: waitForEvent"
  test "should emulate media in popup"

  @tag skip: "not ported: evaluateHandle (attachFrame)"
  test "should emulate media in cross-process iframe"

  @tag skip: "not ported: Page"
  test "default user agent"

  @tag skip: "not ported: Page"
  test "should create two pages in parallel in various contexts"
end
