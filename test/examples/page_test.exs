defmodule PlaywrightEx.Examples.PageTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  example "Page.route",
    js: ~S"""
    const page = await browser.newPage();
    await page.route('**/*.{png,jpg,jpeg}', route => route.abort());
    await page.goto('https://example.com');
    await browser.close();
    """,
    skip: "navigates a browser of its own: not offline" do
    page = Browser.new_page!(browser)
    Page.route!(page, "**/*.{png,jpg,jpeg}", &Route.abort/1)
    Page.goto!(page, "https://example.com")
    Browser.close!(browser)
  end
end
