defmodule PlaywrightEx.Page.SelectorsRegisterTest do
  @upstream "tests/page/selectors-register.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Selectors

  @moduletag :page

  # it.skip(!!process.env.PW_TEST_CONNECT_WS_ENDPOINT, ...)  -- never connected to a ws endpoint

  # Selector engines are JS source: `(${createDummySelector.toString()})()` (no function serialization).
  defp register!(playwright, name, create_dummy_selector) do
    Selectors.register!(Playwright.selectors(playwright), name, "(#{create_dummy_selector})()")
  end

  test "textContent should be atomic", %{playwright: playwright, page: page} do
    create_dummy_selector = """
    () => ({
      query(root, selector) {
        const result = root.querySelector(selector);
        if (result)
          void Promise.resolve().then(() => result.textContent = 'modified');
        return result;
      },
      queryAll(root, selector) {
        const result = Array.from(root.querySelectorAll(selector));
        for (const e of result)
          void Promise.resolve().then(() => e.textContent = 'modified');
        return result;
      }
    })
    """

    register!(playwright, "textContent", create_dummy_selector)
    Page.goto!(page, "data:text/html,<div>Hello</div>")
    tc = Page.text_content!(page, "textContent=div")
    assert tc == "Hello"
    assert Page.evaluate!(page, "() => document.querySelector('div').textContent") == "modified"
  end

  test "innerText should be atomic", %{playwright: playwright, page: page} do
    create_dummy_selector = """
    () => ({
      query(root, selector) {
        const result = root.querySelector(selector);
        if (result)
          void Promise.resolve().then(() => result.textContent = 'modified');
        return result;
      },
      queryAll(root, selector) {
        const result = Array.from(root.querySelectorAll(selector));
        for (const e of result)
          void Promise.resolve().then(() => e.textContent = 'modified');
        return result;
      }
    })
    """

    register!(playwright, "innerText", create_dummy_selector)
    Page.goto!(page, "data:text/html,<div>Hello</div>")
    tc = Page.inner_text!(page, "innerText=div")
    assert tc == "Hello"
    assert Page.evaluate!(page, "() => document.querySelector('div').innerText") == "modified"
  end

  test "innerHTML should be atomic", %{playwright: playwright, page: page} do
    create_dummy_selector = """
    () => ({
      query(root, selector) {
        const result = root.querySelector(selector);
        if (result)
          void Promise.resolve().then(() => result.textContent = 'modified');
        return result;
      },
      queryAll(root, selector) {
        const result = Array.from(root.querySelectorAll(selector));
        for (const e of result)
          void Promise.resolve().then(() => e.textContent = 'modified');
        return result;
      }
    })
    """

    register!(playwright, "innerHTML", create_dummy_selector)
    Page.goto!(page, "data:text/html,<div>Hello<span>world</span></div>")
    tc = Page.inner_html!(page, "innerHTML=div")
    assert tc == "Hello<span>world</span>"
    assert Page.evaluate!(page, "() => document.querySelector('div').innerHTML") == "modified"
  end

  test "getAttribute should be atomic", %{playwright: playwright, page: page} do
    create_dummy_selector = """
    () => ({
      query(root, selector) {
        const result = root.querySelector(selector);
        if (result)
          void Promise.resolve().then(() => result.setAttribute('foo', 'modified'));
        return result;
      },
      queryAll(root, selector) {
        const result = Array.from(root.querySelectorAll(selector));
        for (const e of result)
          void Promise.resolve().then(() => e.setAttribute('foo', 'modified'));
        return result;
      }
    })
    """

    register!(playwright, "getAttribute", create_dummy_selector)
    Page.goto!(page, "data:text/html,<div foo=hello></div>")
    tc = Page.get_attribute!(page, "getAttribute=div", "foo")
    assert tc == "hello"
    assert Page.evaluate!(page, "() => document.querySelector('div').getAttribute('foo')") == "modified"
  end

  test "isVisible should be atomic", %{playwright: playwright, page: page} do
    create_dummy_selector = """
    () => ({
      query(root, selector) {
        const result = root.querySelector(selector);
        if (result)
          void Promise.resolve().then(() => result.style.display = 'none');
        return result;
      },
      queryAll(root, selector) {
        const result = Array.from(root.querySelectorAll(selector));
        for (const e of result)
          void Promise.resolve().then(() => e.style.display = 'none');
        return result;
      }
    })
    """

    register!(playwright, "isVisible", create_dummy_selector)
    Page.goto!(page, "data:text/html,<div>Hello</div>")
    result = Page.is_visible!(page, "isVisible=div")
    assert result == true
    assert Page.evaluate!(page, "() => document.querySelector('div').style.display") == "none"
  end

  test "should take java-style string", %{playwright: playwright, page: page} do
    create_dummy_selector = """
    {
      query(root, selector) {
        return root.querySelector(selector);
      },
      queryAll(root, selector) {
        return root.querySelectorAll(selector);
      }
    }
    """

    Selectors.register!(Playwright.selectors(playwright), "objectLiteral", create_dummy_selector)
    Page.goto!(page, "data:text/html,<div>Hello</div>")
    Page.text_content!(page, "objectLiteral=div")
  end
end
