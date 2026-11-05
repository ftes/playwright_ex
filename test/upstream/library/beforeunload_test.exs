defmodule PlaywrightEx.Library.BeforeunloadTest do
  @upstream "tests/library/beforeunload.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Route

  @moduletag :page

  test "should close browser with beforeunload page", %{server: server, browser_type: browser_type} do
    browser = BrowserType.launch!(browser_type)
    page = Browser.new_page!(browser)
    Page.goto!(page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(page, "body")
    Browser.close!(browser)
  end

  test "should close browsercontext with beforeunload page", %{server: server, page: page, context: context} do
    Page.goto!(page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(page, "body")
    BrowserContext.close!(context)
  end

  test "should be able to navigate away from page with beforeunload", %{server: server, page: page} do
    Page.goto!(page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(page, "body")
    Page.goto!(page, server.empty_page)
  end

  test "should close page with beforeunload listener", %{context: context, server: server} do
    new_page = BrowserContext.new_page!(context)
    Page.goto!(new_page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(new_page, "body")
    Page.close!(new_page)
  end

  test "should run beforeunload if asked for @smoke", %{context: context, server: server, browser_name: browser_name} do
    new_page = BrowserContext.new_page!(context)
    Page.goto!(new_page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(new_page, "body")
    dialog_promise = Page.wait_for_event(new_page, :dialog)
    Page.close!(new_page, run_before_unload: true)
    dialog = Promise.await!(dialog_promise)
    assert Dialog.type(dialog) == "beforeunload"
    assert Dialog.default_value(dialog) == ""

    cond do
      browser_name == "chromium" -> assert Dialog.message(dialog) == ""
      browser_name == "webkit" -> assert Dialog.message(dialog) == "Leave?"
      true -> assert Dialog.message(dialog) =~ "This page is asking you to confirm that you want to leave"
    end

    close_promise = Page.wait_for_event(new_page, :close)
    Dialog.accept!(dialog)
    Promise.await!(close_promise)
  end

  test "should access page after beforeunload", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(page, "body")
    dialog_promise = Page.wait_for_event(page, :dialog)
    Page.close!(page, run_before_unload: true)
    dialog = Promise.await!(dialog_promise)
    Dialog.dismiss!(dialog)
    Page.evaluate!(page, "() => document.title")
  end

  test "should not stall on evaluate when dismissing beforeunload", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/23141' });

    Page.goto!(page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers fire.
    Page.click!(page, "body")

    dialog_promise = Page.wait_for_event(page, :dialog)
    # `.then(dialog => dialog.dismiss())` runs while the evaluate is pending.
    dismissed = Task.async(fn -> Dialog.dismiss!(Promise.await!(dialog_promise)) end)

    Page.evaluate!(page, """
    () => {
      window.location.reload();
    }
    """)

    Task.await(dismissed)
  end

  test "should not stall on click when dismissing beforeunload", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/33806' });

    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a href="#{server.prefix}/frames/one-frame.html">click me</a>))

    Page.evaluate!(page, """
    () => {
      window.onbeforeunload = () => false;
    }
    """)

    Page.on(page, :dialog, fn dialog ->
      Dialog.dismiss(dialog)
    end)

    page |> Page.get_by_role("link") |> Locator.click!(no_wait_after: true)

    Page.evaluate!(page, """
    () => {
      window.onbeforeunload = null;
    }
    """)

    # This line should not timeout.
    page |> Page.get_by_role("link") |> Locator.click!(timeout: 5000)
    Expect.to_have_url!(page, server.prefix <> "/frames/one-frame.html")
  end

  test "should support dismissing the dialog multiple times", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/beforeunload.html")

    # We have to interact with a page so that 'beforeunload' handlers
    # fire (in Firefox).
    Page.click!(page, "body")

    dialog_promise = Page.wait_for_event(page, :dialog)
    Page.close!(page, run_before_unload: true)
    dialog = Promise.await!(dialog_promise)

    Dialog.dismiss!(dialog)

    dialog_promise2 = Page.wait_for_event(page, :dialog)
    Page.close!(page, run_before_unload: true)
    dialog2 = Promise.await!(dialog_promise2)

    Dialog.dismiss!(dialog2)
  end

  test "should support closing the page after a previous dismiss", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/beforeunload.html")

    # We have to interact with a page so that 'beforeunload' handlers
    # fire (in Firefox).
    Page.click!(page, "body")

    dialog_promise = Page.wait_for_event(page, :dialog)
    Page.close!(page, run_before_unload: true)
    dialog = Promise.await!(dialog_promise)

    Dialog.dismiss!(dialog)

    Page.close!(page)
    assert Page.is_closed(page) == true
  end

  test "should support closing the page via a subsequent onbeforeunload dialog", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/beforeunload.html")

    # We have to interact with a page so that 'beforeunload' handlers
    # fire (in Firefox).
    Page.click!(page, "body")

    dialog_promise = Page.wait_for_event(page, :dialog)
    Page.close!(page, run_before_unload: true)
    dialog = Promise.await!(dialog_promise)

    # `await page.waitForEvent('close')` after `dialog.accept()`: subscribe first, the event may
    # arrive before the next call.
    close_promise = Page.wait_for_event(page, :close)
    Dialog.accept!(dialog)

    Promise.await!(close_promise)
    assert Page.is_closed(page) == true
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/38731' }
  test "does not get stalled by beforeUnload", %{page: page, server: server} do
    Page.goto!(page, server.hello_world)

    Page.evaluate!(page, """
    () => {
      window.addEventListener('beforeunload', event => {
        event.preventDefault();
      });
    }
    """)

    Page.on(page, :dialog, fn dialog -> Dialog.dismiss(dialog) end)

    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(page, "body")

    Page.route!(page, "**/api", fn route -> Route.fulfill(route, status: 200, body: "ok") end)
    Page.evaluate!(page, "async () => fetch(new URL('/api', window.location.href))")

    Page.close!(page, run_before_unload: true)

    Page.evaluate!(page, "async () => fetch(new URL('/api', window.location.href))")
  end
end
