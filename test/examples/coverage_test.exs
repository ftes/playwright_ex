defmodule PlaywrightEx.Examples.CoverageTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.Coverage

  @chromium_only if(PlaywrightEx.TestBrowser.name() != "chromium", do: "JS coverage is Chromium-only")

  example "Coverage",
    js: ~S"""
    const { chromium } = require('playwright');
    const v8toIstanbul = require('v8-to-istanbul');

    (async () => {
      const browser = await chromium.launch();
      const page = await browser.newPage();
      await page.coverage.startJSCoverage();
      await page.goto('https://chromium.org');
      const coverage = await page.coverage.stopJSCoverage();
      for (const entry of coverage) {
        const converter = v8toIstanbul('', 0, { source: entry.source });
        await converter.load();
        converter.applyCoverage(entry.functions);
        console.log(JSON.stringify(converter.toIstanbul()));
      }
      await browser.close();
    })();
    """,
    html: "<script>function hello() { return 'world'; } hello();</script>",
    skip: @chromium_only do
    browser = Playwright.chromium(playwright) |> BrowserType.launch!()
    page = Browser.new_page!(browser)
    Page.coverage(page) |> Coverage.start_js_coverage!()
    Page.goto!(page, "https://chromium.org")
    coverage = Page.coverage(page) |> Coverage.stop_js_coverage!()

    for entry <- coverage do
      # v8-to-istanbul is a Node package: convert the V8 ranges with a tool of your choice.
      IO.puts(JSON.encode!(%{url: entry.url, functions: entry.functions}))
    end

    Browser.close!(browser)
  end
end
