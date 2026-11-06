defmodule PlaywrightEx.Examples.BrowserTypeTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  # The examples launch Chromium: they run where it is the browser under test.
  @chromium_only if(PlaywrightEx.TestBrowser.name() != "chromium", do: "launches chromium, not the browser under test")

  example "BrowserType",
    js: ~S"""
    const { chromium } = require('playwright');  // Or 'firefox' or 'webkit'.

    (async () => {
      const browser = await chromium.launch();
      const page = await browser.newPage();
      await page.goto('https://example.com');
      // other actions...
      await browser.close();
    })();
    """,
    skip: @chromium_only do
    # Or Playwright.firefox/1 or Playwright.webkit/1.
    browser = BrowserType.launch!(Playwright.chromium(playwright))
    page = Browser.new_page!(browser)
    Page.goto!(page, "https://example.com")
    # other actions...
    Browser.close!(browser)
  end

  example "BrowserType.connectOverCDP",
    js: ~S"""
    const browser = await playwright.chromium.connectOverCDP('http://localhost:9222');
    const defaultContext = browser.contexts()[0];
    const page = defaultContext.pages()[0];
    """,
    skip: @chromium_only,
    given: [_: BrowserType.launch!(Playwright.chromium(playwright), args: ["--remote-debugging-port=9222"])] do
    browser = Playwright.chromium(playwright) |> BrowserType.connect_over_cdp!("http://localhost:9222")
    default_context = Browser.contexts(browser) |> Enum.at(0)
    page = BrowserContext.pages(default_context) |> Enum.at(0)
  end

  example "BrowserType.launch",
    js: ~S"""
    const browser = await chromium.launch({  // Or 'firefox' or 'webkit'.
      ignoreDefaultArgs: ['--mute-audio']
    });
    """,
    skip: @chromium_only do
    # Or Playwright.firefox/1 or Playwright.webkit/1.
    browser = BrowserType.launch!(Playwright.chromium(playwright), ignore_default_args: ["--mute-audio"])
  end
end
