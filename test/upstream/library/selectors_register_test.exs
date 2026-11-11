defmodule PlaywrightEx.Library.SelectorsRegisterTest do
  @upstream "tests/library/selectors-register.spec.ts"
  # isolate: registers selector engines on the driver.
  use PlaywrightEx.UpstreamCase, async: true, isolate: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Selectors

  # Selector engines are JS source: `(${createTagSelector.toString()})()` (no function serialization).
  @create_tag_selector """
  () => ({
    query(root, selector) {
      return root.querySelector(selector);
    },
    queryAll(root, selector) {
      return Array.from(root.querySelectorAll(selector));
    }
  })
  """

  test "SE-160 should work", %{playwright: playwright, browser: browser} do
    # Register one engine before creating context.
    Selectors.register!(Playwright.selectors(playwright), "tag", "(#{@create_tag_selector})()")

    context = Browser.new_context!(browser)
    # Register another engine after creating context.
    Selectors.register!(Playwright.selectors(playwright), "tag2", "(#{@create_tag_selector})()")

    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<div><span></span></div><div></div>")

    assert Page.eval_on_selector!(page, "tag=DIV", "e => e.nodeName") == "DIV"
    assert Page.eval_on_selector!(page, "tag=SPAN", "e => e.nodeName") == "SPAN"
    assert Page.eval_on_selector_all!(page, "tag=DIV", "es => es.length") == 2

    assert Page.eval_on_selector!(page, "tag2=DIV", "e => e.nodeName") == "DIV"
    assert Page.eval_on_selector!(page, "tag2=SPAN", "e => e.nodeName") == "SPAN"
    assert Page.eval_on_selector_all!(page, "tag2=DIV", "es => es.length") == 2

    # Selector names are case-sensitive.
    {:error, error} = Page.query_selector(page, "tAG=DIV")
    assert Exception.message(error) =~ ~s(Unknown engine "tAG" while parsing selector tAG=DIV)

    BrowserContext.close!(context)
  end

  test "SE-161 should work when registered on global", %{playwright: playwright, browser: browser} do
    # it.skip(mode === 'driver', ...)  -- always default mode
    # require('@playwright/test').selectors: the selectors of the Playwright instance that launched
    # the browser (in default mode). There are no global selectors here: that is `playwright`'s.
    Selectors.register!(Playwright.selectors(playwright), "oop-tag", "(#{@create_tag_selector})()")

    context = Browser.new_context!(browser)
    # Register another engine after creating context.
    Selectors.register!(Playwright.selectors(playwright), "oop-tag2", "(#{@create_tag_selector})()")

    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<div><span></span></div><div></div>")

    assert Page.eval_on_selector!(page, "oop-tag=DIV", "e => e.nodeName") == "DIV"
    assert Page.eval_on_selector!(page, "oop-tag=SPAN", "e => e.nodeName") == "SPAN"
    assert Page.eval_on_selector_all!(page, "oop-tag=DIV", "es => es.length") == 2

    assert Page.eval_on_selector!(page, "oop-tag2=DIV", "e => e.nodeName") == "DIV"
    assert Page.eval_on_selector!(page, "oop-tag2=SPAN", "e => e.nodeName") == "SPAN"
    assert Page.eval_on_selector_all!(page, "oop-tag2=DIV", "es => es.length") == 2

    BrowserContext.close!(context)
  end

  test "SE-162 should work with path", %{playwright: playwright, browser: browser, asset: asset} do
    Selectors.register!(Playwright.selectors(playwright), "foo", %{path: asset.("sectionselectorengine.js")})
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<section></section>")
    assert Page.eval_on_selector!(page, "foo=whatever", "e => e.nodeName") == "SECTION"
    Page.close!(page)
  end

  test "SE-163 should work in main and isolated world", %{playwright: playwright, browser: browser} do
    create_dummy_selector = """
    (() => ({
      query(root, selector) {
        return window['__answer'];
      },
      queryAll(root, selector) {
        return window['__answer'] ? [window['__answer'], document.body, document.documentElement] : [];
      }
    }))()
    """

    Selectors.register!(Playwright.selectors(playwright), "main", create_dummy_selector)
    Selectors.register!(Playwright.selectors(playwright), "isolated", create_dummy_selector, content_script: true)
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<div><span><section></section></span></div>")
    Page.evaluate!(page, "() => window['__answer'] = document.querySelector('span')")
    # Works in main if asked.
    assert Page.eval_on_selector!(page, "main=ignored", "e => e.nodeName") == "SPAN"
    assert Page.eval_on_selector!(page, "css=div >> main=ignored", "e => e.nodeName") == "SPAN"
    assert Page.eval_on_selector_all!(page, "main=ignored", "es => window['__answer'] !== undefined") == true
    assert Page.eval_on_selector_all!(page, "main=ignored", "es => es.filter(e => e).length") == 3
    # Works in isolated by default.
    assert Page.query_selector!(page, "isolated=ignored") == nil
    assert Page.query_selector!(page, "css=div >> isolated=ignored") == nil
    # $$eval always works in main, to avoid adopting nodes one by one.
    assert Page.eval_on_selector_all!(page, "isolated=ignored", "es => window['__answer'] !== undefined") == true
    assert Page.eval_on_selector_all!(page, "isolated=ignored", "es => es.filter(e => e).length") == 3
    # At least one engine in main forces all to be in main.
    assert Page.eval_on_selector!(page, "main=ignored >> isolated=ignored", "e => e.nodeName") == "SPAN"
    assert Page.eval_on_selector!(page, "isolated=ignored >> main=ignored", "e => e.nodeName") == "SPAN"
    # Can be chained to css.
    assert Page.eval_on_selector!(page, "main=ignored >> css=section", "e => e.nodeName") == "SECTION"
    Page.close!(page)
  end

  test "SE-164 should handle errors", %{playwright: playwright, browser: browser} do
    page = Browser.new_page!(browser)
    {:error, error} = Page.query_selector(page, "neverregister=ignored")

    assert Exception.message(error) =~
             ~s(Unknown engine "neverregister" while parsing selector neverregister=ignored)

    create_dummy_selector = """
    (() => ({
      query(root, selector) {
        return root.querySelector('dummy');
      },
      queryAll(root, selector) {
        return Array.from(root.querySelectorAll('dummy'));
      }
    }))()
    """

    {:error, error} = Selectors.register(Playwright.selectors(playwright), "$", create_dummy_selector)

    assert Exception.message(error) ==
             "selectors.register: Selector engine name may only contain [a-zA-Z0-9_] characters"

    # Selector names are case-sensitive.
    Selectors.register!(Playwright.selectors(playwright), "dummy", create_dummy_selector)
    Selectors.register!(Playwright.selectors(playwright), "duMMy", create_dummy_selector)

    {:error, error} = Selectors.register(Playwright.selectors(playwright), "dummy", create_dummy_selector)
    assert Exception.message(error) == ~s(selectors.register: "dummy" selector engine has been already registered)

    {:error, error} = Selectors.register(Playwright.selectors(playwright), "css", create_dummy_selector)
    assert Exception.message(error) == ~s(selectors.register: "css" is a predefined selector engine)
    Page.close!(page)
  end

  test "SE-165 should throw \"already registered\" error when registering", %{playwright: playwright} do
    Selectors.register!(Playwright.selectors(playwright), "alreadyRegistered", "(#{@create_tag_selector})()")

    {:error, error} =
      Selectors.register(Playwright.selectors(playwright), "alreadyRegistered", "(#{@create_tag_selector})()")

    assert Exception.message(error) =~
             ~s(selectors.register: "alreadyRegistered" selector engine has been already registered)
  end

  test "SE-166 should not rely on engines working from the root", %{playwright: playwright, browser: browser} do
    create_value_engine = """
    (() => ({
      query(root, selector) {
        return root && root.value.includes(selector) ? root : undefined;
      },
      queryAll(root, selector) {
        return root && root.value.includes(selector) ? [root] : [];
      },
    }))()
    """

    Selectors.register!(Playwright.selectors(playwright), "__value", create_value_engine)
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<input id=input1 value=value1><input id=input2 value=value2>")
    assert Page.eval_on_selector!(page, "input >> __value=value2", "e => e.id") == "input2"
    Page.close!(page)
  end

  test "SE-167 should throw a nice error if the selector returns a bad value", %{
    playwright: playwright,
    browser: browser
  } do
    create_fake_engine = """
    (() => ({
      query(root, selector) {
        return [document.body];
      },
      queryAll(root, selector) {
        return [[document.body]];
      },
    }))()
    """

    Selectors.register!(Playwright.selectors(playwright), "__fake", create_fake_engine)
    page = Browser.new_page!(browser)
    {:error, error} = Page.query_selector(page, "__fake=value2")
    assert Exception.message(error) =~ "Expected a Node but got [object Array]"
    Page.close!(page)
  end
end
