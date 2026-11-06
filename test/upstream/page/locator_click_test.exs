defmodule PlaywrightEx.Page.LocatorClickTest do
  @upstream "tests/page/locator-click.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.locator(page, "button")
    Locator.click!(button)
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "should work with Node removed", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.evaluate!(page, "() => delete window['Node']")
    button = Page.locator(page, "button")
    Locator.click!(button)
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "should double click the button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.evaluate!(page, """
    () => {
      window['double'] = false;
      const button = document.querySelector('button');
      button.addEventListener('dblclick', event => {
        window['double'] = true;
      });
    }
    """)

    button = Page.locator(page, "button")
    Locator.dblclick!(button)
    assert Page.evaluate!(page, "double") == true
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "should click if the target element is removed in pointerup event", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/21995' });
    Page.set_content!(page, "<button id=clickme>Clickable</button>")

    Page.eval_on_selector!(
      page,
      "#clickme",
      "element => element.addEventListener('pointerup', () => element.remove(), false)"
    )

    Locator.click!(Page.locator(page, "#clickme"))
  end

  test "should click if the target element is removed in pointerdown event", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/21995' });
    Page.set_content!(page, "<button id=clickme>Clickable</button>")

    Page.eval_on_selector!(
      page,
      "#clickme",
      "element => element.addEventListener('pointerdown', () => element.remove(), false)"
    )

    Locator.click!(Page.locator(page, "#clickme"))
  end
end
