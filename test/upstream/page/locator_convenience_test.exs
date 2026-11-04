defmodule PlaywrightEx.Page.LocatorConvenienceTest do
  @upstream "tests/page/locator-convenience.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  @tag skip: "not ported: Locator.toString"
  test "should have a nice preview"

  test "getAttribute should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    locator = Page.locator(page, "#outer")
    assert Locator.get_attribute!(locator, "name") == "value"
    assert Locator.get_attribute!(locator, "foo") == nil
    assert Page.get_attribute!(page, "#outer", "name") == "value"
    assert Page.get_attribute!(page, "#outer", "foo") == nil
  end

  test "inputValue should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")

    Page.select_option!(page, "#select", "foo")
    assert Page.input_value!(page, "#select") == "foo"

    Page.fill!(page, "#textarea", "text value")
    assert Page.input_value!(page, "#textarea") == "text value"

    Page.fill!(page, "#input", "input value")
    assert Page.input_value!(page, "#input") == "input value"
    locator = Page.locator(page, "#input")
    assert Locator.input_value!(locator) == "input value"

    {:error, e} = Page.input_value(page, "#inner")
    assert Exception.message(e) =~ "Node is not an <input>, <textarea> or <select> element"
    locator2 = Page.locator(page, "#inner")
    {:error, e} = Locator.input_value(locator2)
    assert Exception.message(e) =~ "Node is not an <input>, <textarea> or <select> element"
  end

  test "innerHTML should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    locator = Page.locator(page, "#outer")
    assert Locator.inner_html!(locator) == "<div id=\"inner\">Text,\nmore text</div>"
    assert Page.inner_html!(page, "#outer") == "<div id=\"inner\">Text,\nmore text</div>"
  end

  test "innerText should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    locator = Page.locator(page, "#inner")
    assert Locator.inner_text!(locator) == "Text, more text"
    assert Page.inner_text!(page, "#inner") == "Text, more text"
  end

  test "innerText should throw", %{page: page} do
    Page.set_content!(page, "<svg>text</svg>")
    {:error, error1} = Page.inner_text(page, "svg")
    assert Exception.message(error1) =~ "Node is not an HTMLElement"
    locator = Page.locator(page, "svg")
    {:error, error2} = Locator.inner_text(locator)
    assert Exception.message(error2) =~ "Node is not an HTMLElement"
  end

  test "innerText should produce log", %{page: page} do
    Page.set_content!(page, "<div>Hello</div>")
    locator = Page.locator(page, "span")
    {:error, error} = Locator.inner_text(locator, timeout: 1000)
    assert Exception.message(error) =~ "waiting for locator('span')"
  end

  test "textContent should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    locator = Page.locator(page, "#inner")
    assert Locator.text_content!(locator) == "Text,\nmore text"
    assert Page.text_content!(page, "#inner") == "Text,\nmore text"
  end

  test "isEnabled and isDisabled should work", %{page: page} do
    Page.set_content!(page, """
      <button disabled>button1</button>
      <button>button2</button>
      <div>div</div>
    """)

    div = Page.locator(page, "div")
    assert Locator.is_enabled!(div) == true
    assert Locator.is_disabled!(div) == false
    assert Page.is_enabled!(page, "div") == true
    assert Page.is_disabled!(page, "div") == false
    button1 = Page.locator(page, ~s|:text("button1")|)
    assert Locator.is_enabled!(button1) == false
    assert Locator.is_disabled!(button1) == true
    assert Page.is_enabled!(page, ~s|:text("button1")|) == false
    assert Page.is_disabled!(page, ~s|:text("button1")|) == true
    button2 = Page.locator(page, ~s|:text("button2")|)
    assert Locator.is_enabled!(button2) == true
    assert Locator.is_disabled!(button2) == false
    assert Page.is_enabled!(page, ~s|:text("button2")|) == true
    assert Page.is_disabled!(page, ~s|:text("button2")|) == false
  end

  test "isEditable should work", %{page: page} do
    Page.set_content!(page, """
      <input id=input1 disabled>
      <textarea></textarea>
      <input id=input2>
      <div contenteditable="true"></div>
      <span id=span1 role=textbox aria-readonly=true></span>
      <span id=span2 role=textbox></span>
      <button>button</button>
    """)

    Page.eval_on_selector!(page, "textarea", "t => t.readOnly = true")
    input1 = Page.locator(page, "#input1")
    assert Locator.is_editable!(input1) == false
    assert Page.is_editable!(page, "#input1") == false
    input2 = Page.locator(page, "#input2")
    assert Locator.is_editable!(input2) == true
    assert Page.is_editable!(page, "#input2") == true
    textarea = Page.locator(page, "textarea")
    assert Locator.is_editable!(textarea) == false
    assert Page.is_editable!(page, "textarea") == false
    assert Locator.is_editable!(Page.locator(page, "div")) == true
    assert Locator.is_editable!(Page.locator(page, "#span1")) == false
    assert Locator.is_editable!(Page.locator(page, "#span2")) == true
    {:error, error} = Locator.is_editable(Page.locator(page, "button"))

    assert Exception.message(error) =~
             "Element is not an <input>, <textarea>, <select> or [contenteditable] and does not have a role allowing [aria-readonly]"
  end

  test "isChecked should work", %{page: page} do
    Page.set_content!(page, "<input type='checkbox' checked><div>Not a checkbox</div>")
    element = Page.locator(page, "input")
    assert Locator.is_checked!(element) == true
    assert Page.is_checked!(page, "input") == true
    Locator.evaluate!(element, "input => input.checked = false")
    assert Locator.is_checked!(element) == false
    assert Page.is_checked!(page, "input") == false
    {:error, error} = Page.is_checked(page, "div")
    assert Exception.message(error) =~ "Not a checkbox or radio button"
  end

  @tag skip: "not ported: expect"
  test "isChecked should work for indeterminate input"

  test "allTextContents should work", %{page: page} do
    Page.set_content!(page, "<div>A</div><div>B</div><div>C</div>")
    assert Locator.all_text_contents!(Page.locator(page, "div")) == ["A", "B", "C"]
  end

  test "allInnerTexts should work", %{page: page} do
    Page.set_content!(page, "<div>A</div><div>B</div><div>C</div>")
    assert Locator.all_inner_texts!(Page.locator(page, "div")) == ["A", "B", "C"]
  end

  test "should return page", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/two-frames.html")
    outer = Page.locator(page, "#outer")
    assert Locator.page(outer) == page

    inner = Locator.locator(outer, "#inner")
    assert Locator.page(inner) == page

    in_frame = Frame.locator(Enum.at(Page.frames(page), 1), "div")
    assert Locator.page(in_frame) == page
  end

  test "description should return null for locator without description", %{page: page} do
    locator = Page.locator(page, "button")
    assert Locator.description(locator) == nil
  end

  test "description should return description for locator with simple description", %{page: page} do
    locator = page |> Page.locator("button") |> Locator.describe("Submit button")
    assert Locator.description(locator) == "Submit button"
  end

  test "description should return description with special characters", %{page: page} do
    locator = page |> Page.locator("div") |> Locator.describe(~s|Button with "quotes" and 'apostrophes'|)
    assert Locator.description(locator) == ~s|Button with "quotes" and 'apostrophes'|
  end

  test "description should return description for chained locators", %{page: page} do
    locator = page |> Page.locator("form") |> Locator.locator("input") |> Locator.describe("Form input field")
    assert Locator.description(locator) == "Form input field"
  end

  test "description should return description for locator with multiple describe calls", %{page: page} do
    locator1 = page |> Page.locator("foo") |> Locator.describe("First description")
    assert Locator.description(locator1) == "First description"
    locator2 = locator1 |> Locator.locator("button") |> Locator.describe("Second description")
    assert Locator.description(locator2) == "Second description"
    locator3 = Locator.locator(locator2, "button")
    assert Locator.description(locator3) == nil
  end

  @tag skip: "not ported: Locator.toString"
  test "toString() returns formatted locator"

  @tag skip: "not ported: Locator.toString"
  test "toString() prefers description"
end
