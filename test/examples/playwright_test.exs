defmodule PlaywrightEx.Examples.PlaywrightTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  # The examples that launch a browser run where it is the browser under test.
  @browser PlaywrightEx.TestBrowser.name()
  @chromium_only if(@browser != "chromium", do: "launches chromium, not the browser under test")
  @webkit_only if(@browser != "webkit", do: "launches webkit, not the browser under test")

  example "Playwright",
    js: ~S"""
    const { chromium, firefox, webkit } = require('playwright');

    (async () => {
      const browser = await chromium.launch();  // Or 'firefox' or 'webkit'.
      const page = await browser.newPage();
      await page.goto('http://example.com');
      // other actions...
      await browser.close();
    })();
    """,
    skip: @chromium_only do
    # Or Playwright.firefox/1 or Playwright.webkit/1.
    browser = BrowserType.launch!(Playwright.chromium(playwright))
    page = Browser.new_page!(browser)
    Page.goto!(page, "http://example.com")
    # other actions...
    Browser.close!(browser)
  end

  example "Playwright.devices",
    js: ~S"""
    const { webkit, devices } = require('playwright');
    const iPhone = devices['iPhone 6'];

    (async () => {
      const browser = await webkit.launch();
      const context = await browser.newContext({
        ...iPhone
      });
      const page = await context.newPage();
      await page.goto('http://example.com');
      // other actions...
      await browser.close();
    })();
    """,
    skip: @webkit_only do
    iphone = Playwright.devices(playwright)["iPhone 6"]

    browser = BrowserType.launch!(Playwright.webkit(playwright))
    context = Browser.new_context!(browser, iphone)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://example.com")
    # other actions...
    Browser.close!(browser)
  end

  example "Playwright.errors",
    js: ~S"""
    try {
      await page.locator('.foo').waitFor();
    } catch (e) {
      if (e instanceof playwright.errors.TimeoutError) {
        // Do something if this is a timeout.
      }
    }
    """,
    given: [_: Page.set_default_timeout(page, 100)] do
    try do
      Page.locator(page, ".foo") |> Locator.wait_for!()
    rescue
      _ in PlaywrightEx.TimeoutError ->
        # Do something if this is a timeout.
        nil
    end
  end
end
