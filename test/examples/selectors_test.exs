defmodule PlaywrightEx.Examples.SelectorsTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  # isolate: registers a selector engine on the driver.
  use PlaywrightEx.ExampleCase, async: true, isolate: true

  # Upstream's example registers a function (`createTagNameEngine`); the port takes the engine as
  # JS source, as the Python client does.
  example "Selectors.register",
    js: ~S"""
    const { selectors, firefox } = require('@playwright/test');  // Or 'chromium' or 'webkit'.

    (async () => {
      // Must be a function that evaluates to a selector engine instance.
      const createTagNameEngine = () => ({
        // Returns the first element matching given selector in the root's subtree.
        query(root, selector) {
          return root.querySelector(selector);
        },

        // Returns all elements matching given selector in the root's subtree.
        queryAll(root, selector) {
          return Array.from(root.querySelectorAll(selector));
        }
      });

      // Register the engine. Selectors will be prefixed with "tag=".
      await selectors.register('tag', createTagNameEngine);

      const browser = await firefox.launch();
      const page = await browser.newPage();
      await page.setContent(`<div><button>Click me</button></div>`);

      // Use the selector prefixed with its name.
      const button = page.locator('tag=button');
      // We can combine it with built-in locators.
      await page.locator('tag=div').getByText('Click me').click();
      // Can use it in any methods supporting selectors.
      const buttonCount = await page.locator('tag=button').count();

      await browser.close();
    })();
    """,
    skip: if(PlaywrightEx.TestBrowser.name() != "firefox", do: "launches firefox, not the browser under test") do
    # Must be a script that evaluates to a selector engine instance.
    tag_name_engine = """
    {
      // Returns the first element matching given selector in the root's subtree.
      query(root, selector) {
        return root.querySelector(selector);
      },

      // Returns all elements matching given selector in the root's subtree.
      queryAll(root, selector) {
        return Array.from(root.querySelectorAll(selector));
      }
    }
    """

    # Register the engine. Selectors will be prefixed with "tag=".
    Playwright.selectors(playwright) |> Selectors.register!("tag", tag_name_engine)

    # Or Playwright.chromium/1 or Playwright.webkit/1.
    browser = BrowserType.launch!(Playwright.firefox(playwright))
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<div><button>Click me</button></div>")

    # Use the selector prefixed with its name.
    button = Page.locator(page, "tag=button")
    # We can combine it with built-in locators.
    Page.locator(page, "tag=div") |> Locator.get_by_text("Click me") |> Locator.click!()
    # Can use it in any methods supporting selectors.
    button_count = Page.locator(page, "tag=button") |> Locator.count!()

    Browser.close!(browser)
  end
end
