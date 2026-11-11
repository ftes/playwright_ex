defmodule PlaywrightEx.Library.LocatorHighlightTest do
  @upstream "tests/library/locator-highlight.spec.ts"
  # isolate: registers a selector engine on the driver.
  use PlaywrightEx.UpstreamCase, async: true, isolate: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Selectors

  # test.skip(({ mode }) => mode !== 'default', ...)  -- always default mode

  @style_function """
  (el) => ({
    outline: el.style.outline,
    backgroundColor: el.style.backgroundColor,
  })
  """

  test "LO-193 highlight should accept a CSS string style", %{
    browser: browser,
    server: server,
    browser_name: browser_name
  } do
    # test.skip(isFrozenWebkit);  -- we run a current browser
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Locator.highlight!(Page.get_by_role(page, :button),
      style: "outline: 3px solid rgb(255, 0, 0); background-color: rgba(0, 255, 0, 0.25)"
    )

    highlight = Page.locator(page, "x-pw-highlight")
    Expect.to_be_visible!(highlight)
    style = Locator.evaluate!(highlight, @style_function)

    if browser_name in ["chromium", "firefox"],
      do: assert(style["outline"] == "rgb(255, 0, 0) solid 3px"),
      else: assert(style["outline"] == "3px solid rgb(255, 0, 0)")

    assert style["backgroundColor"] == "rgba(0, 255, 0, 0.25)"

    BrowserContext.close!(context)
  end

  test "LO-194 highlight should accept an object style (JS only)", %{
    browser: browser,
    server: server,
    browser_name: browser_name
  } do
    # test.skip(isFrozenWebkit);  -- we run a current browser
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Locator.highlight!(Page.get_by_role(page, :button),
      style: %{"outline" => "2px dashed rgb(0, 0, 255)", "backgroundColor" => "rgba(255, 255, 0, 0.2)"}
    )

    highlight = Page.locator(page, "x-pw-highlight")
    Expect.to_be_visible!(highlight)
    style = Locator.evaluate!(highlight, @style_function)

    if browser_name in ["chromium", "firefox"],
      do: assert(style["outline"] == "rgb(0, 0, 255) dashed 2px"),
      else: assert(style["outline"] == "2px dashed rgb(0, 0, 255)")

    assert style["backgroundColor"] == "rgba(255, 255, 0, 0.2)"

    BrowserContext.close!(context)
  end

  test "LO-195 hideHighlight removes a styled highlight", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/input/button.html")

    button = Page.get_by_role(page, :button)
    Locator.highlight!(button, style: "outline: 2px solid red")
    Expect.to_be_visible!(Page.locator(page, "x-pw-highlight"))

    Locator.hide_highlight!(button)
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 0)

    BrowserContext.close!(context)
  end

  test "LO-196 highlight should survive navigation", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, ~s[<button onclick="console.log(1)">Clicker</button>])

    Locator.highlight!(Page.get_by_role(page, :button))
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 1)

    # Highlights are resolved again after the navigation.
    Page.goto!(page, server.prefix <> "/input/button.html")
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 1)

    Page.hide_highlight!(page)
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 0)

    BrowserContext.close!(context)
  end

  test "LO-197 Page.hideHighlight clears all locator highlights", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<button>One</button><button>Two</button>")

    Locator.highlight!(Page.get_by_role(page, :button, name: "One"))
    Locator.highlight!(Page.get_by_role(page, :button, name: "Two"))
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 2)

    Page.hide_highlight!(page)
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 0)

    BrowserContext.close!(context)
  end

  test "LO-198 highlight should work with a custom selector engine that runs in the main world", %{
    playwright: playwright,
    browser: browser
  } do
    # Engines registered without "contentScript" run in the main world and can see page globals.
    create_engine = """
    (() => ({
      query(root, selector) {
        return window['__engineEnabled'] ? root.querySelector(selector) : null;
      },
      queryAll(root, selector) {
        return window['__engineEnabled'] ? Array.from(root.querySelectorAll(selector)) : [];
      },
    }))()
    """

    Selectors.register!(Playwright.selectors(playwright), "highlight-tag", create_engine)

    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<button>Button</button>")
    Page.evaluate!(page, "() => window['__engineEnabled'] = true")

    button = Page.locator(page, "highlight-tag=button")
    Locator.highlight!(button)
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 1)

    Locator.hide_highlight!(button)
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 0)

    Locator.highlight!(button)
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 1)

    Page.hide_highlight!(page)
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 0)

    BrowserContext.close!(context)
  end

  test "LO-199 highlight should resolve relative to the frame of the locator", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, ~s(<iframe name="frame" srcdoc="<button>foo</button>"></iframe><button>bar</button>))
    frame = Page.frame(page, "frame")

    Locator.highlight!(Page.locator(page, "button"))
    Locator.highlight!(Frame.locator(frame, "button"))
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 1)
    Expect.to_have_count!(Frame.locator(frame, "x-pw-highlight"), 1)

    Locator.hide_highlight!(Page.locator(page, "button"))
    Expect.to_have_count!(Page.locator(page, "x-pw-highlight"), 0)
    Expect.to_have_count!(Frame.locator(frame, "x-pw-highlight"), 1)

    Locator.hide_highlight!(Frame.locator(frame, "button"))
    Expect.to_have_count!(Frame.locator(frame, "x-pw-highlight"), 0)

    BrowserContext.close!(context)
  end
end
