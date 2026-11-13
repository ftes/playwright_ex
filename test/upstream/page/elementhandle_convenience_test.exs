defmodule PlaywrightEx.Page.ElementhandleConvenienceTest do
  @upstream "tests/page/elementhandle-convenience.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "EH-024 should have a nice preview", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    outer = Page.query_selector!(page, "#outer")
    inner = Page.query_selector!(page, "#inner")
    check = Page.query_selector!(page, "#check")
    text = JSHandle.evaluate_handle!(inner, "e => e.firstChild")
    # Give them a chance to calculate the preview.
    Page.evaluate!(page, "() => 1")
    assert to_string(outer) == ~s(JSHandle@<div id="outer" name="value">…</div>)
    assert to_string(inner) == ~s(JSHandle@<div id="inner">Text,↵more text</div>)
    assert to_string(text) == "JSHandle@#text=Text,↵more text"
    assert to_string(check) == ~s(JSHandle@<input checked id="check" foo="bar"" type="checkbox"/>)
  end

  test "EH-025 should have a nice preview for non-ascii attributes/children", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<div title="#{String.duplicate("😛", 100)}">#{String.duplicate("😛", 100)}))
    handle = Page.query_selector!(page, "div")

    expected =
      ~s(JSHandle@<div title="#{String.duplicate("😛", 100)}">#{String.duplicate("😛", 49)}…</div>)

    Expect.poll!(fn -> to_string(handle) end, &assert(&1 == expected))
  end

  test "EH-026 getAttribute should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    handle = Page.query_selector!(page, "#outer")
    assert ElementHandle.get_attribute!(handle, "name") == "value"
    assert ElementHandle.get_attribute!(handle, "foo") == nil
    assert Page.get_attribute!(page, "#outer", "name") == "value"
    assert Page.get_attribute!(page, "#outer", "foo") == nil
  end

  test "EH-027 inputValue should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")

    Page.select_option!(page, "#select", "foo")
    assert Page.input_value!(page, "#select") == "foo"

    Page.fill!(page, "#textarea", "text value")
    assert Page.input_value!(page, "#textarea") == "text value"

    Page.fill!(page, "#input", "input value")
    assert Page.input_value!(page, "#input") == "input value"
    handle = Page.query_selector!(page, "#input")
    assert ElementHandle.input_value!(handle) == "input value"

    {:error, e} = Page.input_value(page, "#inner")
    assert Exception.message(e) =~ "Node is not an <input>, <textarea> or <select> element"
    handle2 = Page.query_selector!(page, "#inner")
    {:error, e} = ElementHandle.input_value(handle2)
    assert Exception.message(e) =~ "Node is not an <input>, <textarea> or <select> element"
  end

  test "EH-028 innerHTML should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    handle = Page.query_selector!(page, "#outer")
    assert ElementHandle.inner_html!(handle) == "<div id=\"inner\">Text,\nmore text</div>"
    assert Page.inner_html!(page, "#outer") == "<div id=\"inner\">Text,\nmore text</div>"
  end

  test "EH-029 innerText should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    handle = Page.query_selector!(page, "#inner")
    assert ElementHandle.inner_text!(handle) == "Text, more text"
    assert Page.inner_text!(page, "#inner") == "Text, more text"
  end

  test "EH-030 innerText should throw", %{page: page} do
    Page.set_content!(page, "<svg>text</svg>")
    {:error, error1} = Page.inner_text(page, "svg")
    assert Exception.message(error1) =~ "Node is not an HTMLElement"
    handle = Page.query_selector!(page, "svg")
    {:error, error2} = ElementHandle.inner_text(handle)
    assert Exception.message(error2) =~ "Node is not an HTMLElement"
  end

  test "EH-031 textContent should work", %{page: page, server: server} do
    Page.goto!(page, "#{server.prefix}/dom.html")
    handle = Page.query_selector!(page, "#inner")
    assert ElementHandle.text_content!(handle) == "Text,\nmore text"
    assert Page.text_content!(page, "#inner") == "Text,\nmore text"
  end

  test "EH-032 textContent should work on ShadowRoot", %{page: page} do
    Page.set_content!(page, """
    <div></div>
    <script>
      document.querySelector('div').attachShadow({ mode: 'open' }).innerHTML = '<div>hello</div>';
    </script>
    """)

    div = Page.query_selector!(page, "div")
    root = JSHandle.evaluate_handle!(div, "div => div.shadowRoot")
    assert ElementHandle.text_content!(root) == "hello"
    # We do not match ShadowRoot as ":scope".
    assert ElementHandle.query_selector_all!(root, ":scope div") == []
  end

  test "EH-033 isVisible and isHidden should work", %{page: page} do
    Page.set_content!(page, "<div>Hi</div><span></span>")

    div = Page.query_selector!(page, "div")
    assert ElementHandle.is_visible!(div) == true
    assert ElementHandle.is_hidden!(div) == false
    assert Page.is_visible!(page, "div") == true
    assert Page.is_hidden!(page, "div") == false

    span = Page.query_selector!(page, "span")
    assert ElementHandle.is_visible!(span) == false
    assert ElementHandle.is_hidden!(span) == true
    assert Page.is_visible!(page, "span") == false
    assert Page.is_hidden!(page, "span") == true

    assert Page.is_visible!(page, "no-such-element") == false
    assert Page.is_hidden!(page, "no-such-element") == true
  end

  test "EH-034 isVisible should not throw when the DOM element is not connected", %{page: page} do
    Page.set_content!(page, ~s(<div id="root"></div>))

    Page.evaluate!(page, """
    () => {
      function insert() {
        document.getElementById('root').innerHTML = '<div id="problem">Problem</div>';
        window.requestAnimationFrame(remove);
      }
      function remove() {
        const node = document.getElementById('problem');
        node?.parentNode?.removeChild(node);
        window.requestAnimationFrame(insert);
      }
      window.requestAnimationFrame(insert);
    }
    """)

    for _ <- 0..9, do: Page.is_visible!(page, "#problem")
  end

  test "EH-035 isEnabled and isDisabled should work", %{page: page} do
    Page.set_content!(page, """
    <button disabled>button1</button>
    <button>button2</button>
    <div>div</div>
    """)

    div = Page.query_selector!(page, "div")
    assert ElementHandle.is_enabled!(div) == true
    assert ElementHandle.is_disabled!(div) == false
    assert Page.is_enabled!(page, "div") == true
    assert Page.is_disabled!(page, "div") == false
    button1 = Page.query_selector!(page, ~s[:text("button1")])
    assert ElementHandle.is_enabled!(button1) == false
    assert ElementHandle.is_disabled!(button1) == true
    assert Page.is_enabled!(page, ~s[:text("button1")]) == false
    assert Page.is_disabled!(page, ~s[:text("button1")]) == true
    button2 = Page.query_selector!(page, ~s[:text("button2")])
    assert ElementHandle.is_enabled!(button2) == true
    assert ElementHandle.is_disabled!(button2) == false
    assert Page.is_enabled!(page, ~s[:text("button2")]) == true
    assert Page.is_disabled!(page, ~s[:text("button2")]) == false
  end

  test "EH-036 isEnabled and isDisabled should work with <select/> option/optgroup correctly", %{page: page} do
    Page.set_content!(page, """
    <select name="select">
      <option id="enabled1" value="1">Enabled</option>
      <option id="disabled1" value="2" disabled>Disabled</option>
      <optgroup label="Foo1">
        <option value="mercedes">Mercedes</option>
      </optgroup>
      <optgroup label="Foo2" disabled>
        <option value="mercedes">Mercedes</option>
      </optgroup>
    </select>
    """)

    assert page |> Page.query_selector!("#enabled1") |> ElementHandle.is_enabled!() == true
    assert page |> Page.query_selector!("#enabled1") |> ElementHandle.is_disabled!() == false
    assert page |> Page.query_selector!("#disabled1") |> ElementHandle.is_enabled!() == false
    assert page |> Page.query_selector!("#disabled1") |> ElementHandle.is_disabled!() == true
    assert page |> Page.query_selector!("optgroup >> nth=0") |> ElementHandle.is_enabled!() == true
    assert page |> Page.query_selector!("optgroup >> nth=0") |> ElementHandle.is_disabled!() == false
    assert page |> Page.query_selector!("optgroup >> nth=1") |> ElementHandle.is_enabled!() == false
    assert page |> Page.query_selector!("optgroup >> nth=1") |> ElementHandle.is_disabled!() == true
  end

  test "EH-037 isEditable should work", %{page: page} do
    Page.set_content!(page, "<input id=input1 disabled><textarea></textarea><input id=input2>")
    Page.eval_on_selector!(page, "textarea", "t => t.readOnly = true")
    input1 = Page.query_selector!(page, "#input1")
    assert ElementHandle.is_editable!(input1) == false
    assert Page.is_editable!(page, "#input1") == false
    input2 = Page.query_selector!(page, "#input2")
    assert ElementHandle.is_editable!(input2) == true
    assert Page.is_editable!(page, "#input2") == true
    textarea = Page.query_selector!(page, "textarea")
    assert ElementHandle.is_editable!(textarea) == false
    assert Page.is_editable!(page, "textarea") == false
  end

  test "EH-038 isChecked should work", %{page: page} do
    Page.set_content!(page, "<input type='checkbox' checked><div>Not a checkbox</div>")
    handle = Page.query_selector!(page, "input")
    assert ElementHandle.is_checked!(handle) == true
    assert Page.is_checked!(page, "input") == true
    JSHandle.evaluate!(handle, "input => input.checked = false")
    assert ElementHandle.is_checked!(handle) == false
    assert Page.is_checked!(page, "input") == false
    {:error, error} = Page.is_checked(page, "div")
    assert Exception.message(error) =~ "Not a checkbox or radio button"
  end
end
