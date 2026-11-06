defmodule PlaywrightEx.Examples.BrowserTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  # The examples that launch a browser run where it is the browser under test.
  @browser PlaywrightEx.TestBrowser.name()
  @firefox_only if(@browser != "firefox", do: "launches firefox, not the browser under test")
  @webkit_only if(@browser != "webkit", do: "launches webkit, not the browser under test")
  @chromium_only if(@browser != "chromium", do: "Chromium only")

  example "Browser",
    js: ~S"""
    const { firefox } = require('playwright');  // Or 'chromium' or 'webkit'.

    (async () => {
      const browser = await firefox.launch();
      const page = await browser.newPage();
      await page.goto('https://example.com');
      await browser.close();
    })();
    """,
    skip: @firefox_only do
    # Or Playwright.chromium/1 or Playwright.webkit/1.
    browser = BrowserType.launch!(Playwright.firefox(playwright))
    page = Browser.new_page!(browser)
    Page.goto!(page, "https://example.com")
    Browser.close!(browser)
  end

  example "Browser.contexts",
    js: ~S"""
    const browser = await pw.webkit.launch();
    console.log(browser.contexts().length); // prints `0`

    const context = await browser.newContext();
    console.log(browser.contexts().length); // prints `1`
    """,
    skip: @webkit_only do
    browser = BrowserType.launch!(Playwright.webkit(playwright))
    # prints 0
    IO.puts(length(Browser.contexts(browser)))

    context = Browser.new_context!(browser)
    # prints 1
    IO.puts(length(Browser.contexts(browser)))
  end

  example "Browser.newContext",
    js: ~S"""
    (async () => {
      const browser = await playwright.firefox.launch();  // Or 'chromium' or 'webkit'.
      // Create a new incognito browser context.
      const context = await browser.newContext();
      // Create a new page in a pristine context.
      const page = await context.newPage();
      await page.goto('https://example.com');

      // Gracefully close up everything
      await context.close();
      await browser.close();
    })();
    """,
    skip: @firefox_only do
    # Or Playwright.chromium/1 or Playwright.webkit/1.
    browser = BrowserType.launch!(Playwright.firefox(playwright))
    # Create a new incognito browser context.
    context = Browser.new_context!(browser)
    # Create a new page in a pristine context.
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com")

    # Gracefully close up everything
    BrowserContext.close!(context)
    Browser.close!(browser)
  end

  example "Browser.startTracing",
    js: ~S"""
    await browser.startTracing(page, { path: 'trace.json' });
    await page.goto('https://www.google.com');
    await browser.stopTracing();
    """,
    skip: @chromium_only,
    writes: ["trace.json"] do
    Browser.start_tracing!(browser, page, path: "trace.json")
    Page.goto!(page, "https://www.google.com")
    Browser.stop_tracing!(browser)
  end
end
