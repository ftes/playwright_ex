defmodule PlaywrightEx.Page.ElementhandleMiscTest do
  @upstream "tests/page/elementhandle-misc.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "EH-045 should hover", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    button = Page.query_selector!(page, "#button-6")
    ElementHandle.hover!(button)
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-6"
  end

  test "EH-046 should hover when Node is removed", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Page.evaluate!(page, "() => delete window['Node']")
    button = Page.query_selector!(page, "#button-6")
    ElementHandle.hover!(button)
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-6"
  end

  test "EH-047 should fill input", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    handle = Page.query_selector!(page, "input")
    ElementHandle.fill!(handle, "some value")
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "EH-048 should fill input when Node is removed", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.evaluate!(page, "() => delete window['Node']")
    handle = Page.query_selector!(page, "input")
    ElementHandle.fill!(handle, "some value")
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "EH-049 should check the box", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox'></input>")
    input = Page.query_selector!(page, "input")
    ElementHandle.check!(input)
    assert Page.evaluate!(page, "checkbox.checked") == true
  end

  test "EH-050 should check the box using setChecked", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox'></input>")
    input = Page.query_selector!(page, "input")
    ElementHandle.set_checked!(input, true)
    assert Page.evaluate!(page, "checkbox.checked") == true
    ElementHandle.set_checked!(input, false)
    assert Page.evaluate!(page, "checkbox.checked") == false
  end

  test "EH-051 should uncheck the box", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox' checked></input>")
    input = Page.query_selector!(page, "input")
    ElementHandle.uncheck!(input)
    assert Page.evaluate!(page, "checkbox.checked") == false
  end

  test "EH-052 should select single option", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    select = Page.query_selector!(page, "select")
    ElementHandle.select_option!(select, "blue")
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue"]
  end

  test "EH-053 should focus a button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")
    assert JSHandle.evaluate!(button, "button => document.activeElement === button") == false
    ElementHandle.focus!(button)
    assert JSHandle.evaluate!(button, "button => document.activeElement === button") == true
  end

  test "EH-054 should allow disposing twice", %{page: page} do
    Page.set_content!(page, "<section>39</section>")
    element = Page.query_selector!(page, "section")
    assert element
    JSHandle.dispose!(element)
    JSHandle.dispose!(element)
  end
end
