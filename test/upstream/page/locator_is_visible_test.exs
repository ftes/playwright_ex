defmodule PlaywrightEx.Page.LocatorIsVisibleTest do
  @upstream "tests/page/locator-is-visible.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "isVisible and isHidden should work", %{page: page} do
    Page.set_content!(page, "<div>Hi</div><span></span>")

    div = Page.locator(page, "div")
    assert Locator.is_visible!(div) == true
    assert Locator.is_hidden!(div) == false
    assert Page.is_visible!(page, "div") == true
    assert Page.is_hidden!(page, "div") == false

    span = Page.locator(page, "span")
    assert Locator.is_visible!(span) == false
    assert Locator.is_hidden!(span) == true
    assert Page.is_visible!(page, "span") == false
    assert Page.is_hidden!(page, "span") == true

    assert Page.is_visible!(page, "no-such-element") == false
    assert Page.is_hidden!(page, "no-such-element") == true
  end

  test "isVisible should be true for opacity:0", %{page: page} do
    Page.set_content!(page, ~s|<div style="opacity:0">Hi</div>|)
    Expect.to_be_visible!(Page.locator(page, "div"))
  end

  test "isVisible should be true for element outside view", %{page: page} do
    Page.set_content!(page, ~s|<div style="position: absolute; left: -1000px">Hi</div>|)
    Expect.to_be_visible!(Page.locator(page, "div"))
  end

  test "isVisible and isHidden should work with details", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/10674' });
    Page.set_content!(page, """
    <details>
        <summary>click to open</summary>
          <ul>
            <li>hidden item 1</li>
            <li>hidden item 2</li>
            <li>hidden item 3</li>
          </ul
      </details>
    """)

    Expect.to_be_hidden!(Page.locator(page, "ul"))
  end

  test "isVisible and isHidden should work with nested details", %{page: page} do
    Page.set_content!(page, """
    <details>
        <summary>outer</summary>
        <details open>
          <summary>inner</summary>
          <button>hidden button</button>
        </details>
      </details>
    """)

    Expect.to_be_visible!(Page.locator(page, "summary", has_text: "outer"))
    Expect.to_be_hidden!(Page.locator(page, "summary", has_text: "inner"))
    Expect.to_be_hidden!(Page.locator(page, "button"))
    Expect.to_have_count!(Page.get_by_role(page, :button), 0)
  end

  test "isVisible and isHidden should work with unslotted content", %{page: page} do
    Page.set_content!(page, """
      <div id=unslotted><span>hidden 1</span><div><span>hidden 2</span></div></div>
      <div id=slotted><span>visible</span></div>
      <script>
        unslotted.attachShadow({ mode: 'open' }).innerHTML = 'nothing to see here';
        slotted.attachShadow({ mode: 'open' }).innerHTML = '<slot></slot>';
      </script>
    """)

    Expect.to_be_hidden!(Page.locator(page, "span", has_text: "hidden 1"))
    Expect.to_be_hidden!(Page.locator(page, "span", has_text: "hidden 2"))
    Expect.to_be_visible!(Page.locator(page, "span", has_text: "visible"))
  end

  test "isVisible and isHidden should work with list box options", %{page: page} do
    # it.skip(isAndroid, ...)  -- Android is not supported
    Page.set_content!(page, """
      <select multiple>
        <option>visible 1</option>
        <optgroup label="group"><option>visible 2</option></optgroup>
        <option hidden>hidden 1</option>
        <optgroup label="hidden group" style="display:none"><option>hidden 2</option></optgroup>
      </select>
      <select size=3><option>visible 3</option></select>
      <select multiple style="display:none"><option>hidden 3</option></select>
    """)

    for name <- ["visible 1", "visible 2", "visible 3"],
        do: Expect.to_be_visible!(Page.get_by_role(page, :option, name: name, exact: true))

    for text <- ["hidden 1", "hidden 2", "hidden 3"],
        do: Expect.to_be_hidden!(Page.locator(page, "option", has_text: text))
  end

  test "isVisible inside a button", %{page: page} do
    Page.set_content!(page, "<button><span></span>a button</button>")
    span = Page.locator(page, "span")
    assert Locator.is_visible!(span) == false
    assert Locator.is_hidden!(span) == true
    assert Page.is_visible!(page, "span") == false
    assert Page.is_hidden!(page, "span") == true
    Expect.not_to_be_visible!(span)
    Expect.to_be_hidden!(span)
    Locator.wait_for!(span, state: :hidden)
    Locator.wait_for!(Page.locator(page, "button"), state: :visible)
  end

  test "isVisible inside a role=button", %{page: page} do
    Page.set_content!(page, "<div role=button><span></span>a button</div>")
    span = Page.locator(page, "span")
    assert Locator.is_visible!(span) == false
    assert Locator.is_hidden!(span) == true
    assert Page.is_visible!(page, "span") == false
    assert Page.is_hidden!(page, "span") == true
    Expect.not_to_be_visible!(span)
    Expect.to_be_hidden!(span)
    Locator.wait_for!(span, state: :hidden)
    Locator.wait_for!(Page.locator(page, "[role=button]"), state: :visible)
  end

  test "isVisible during navigation should not throw", %{page: page, server: server} do
    for _i <- 0..19 do
      # Avoid page.setContent throwing because of scheduled navigation.
      Page.set_content(page, """
        <script>
          setTimeout(() => {
            window.location.href = #{JSON.encode!(server.empty_page)};
          }, Math.random(50));
        </script>
      """)

      assert Locator.is_visible!(Page.locator(page, "div")) == false
    end
  end

  test "isVisible with invalid selector should throw", %{page: page} do
    {:error, error} = Locator.is_visible(Page.locator(page, "hey=what"))
    assert Exception.message(error) =~ ~s|Unknown engine "hey" while parsing selector hey=what|
  end
end
