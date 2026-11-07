defmodule PlaywrightEx.Page.RetargetTest do
  @upstream "tests/page/retarget.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [rafraf: 2]

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime

  @moduletag :page

  defp give_it_a_chance_to_resolve(page), do: rafraf(page, 5)

  test "RE-001 element state checks should work as expected for label with zero-sized input", %{
    page: page
  } do
    Page.set_content!(page, """
    <label>
      Click me
      <input disabled style="width:0;height:0;padding:0;margin:0;border:0;">
    </label>
    """)

    # Visible checks the label.
    assert Page.is_visible!(page, "text=Click me") == true
    assert Page.is_hidden!(page, "text=Click me") == false

    # Enabled checks the input.
    assert Page.is_enabled!(page, "text=Click me") == false
    assert Page.is_disabled!(page, "text=Click me") == true
  end

  test "RE-002 should wait for enclosing disabled button", %{page: page} do
    Page.set_content!(page, "<button><span>Target</span></button>")
    span = Page.query_selector!(page, "text=Target")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(span, :disabled) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(span, "span => span.parentElement.disabled = true")
    Runtime.Promise.await(task)
  end

  test "RE-003 should wait for enclosing button with a disabled fieldset", %{page: page} do
    Page.set_content!(page, "<fieldset disabled=true><button><span>Target</span></button></div>")
    span = Page.query_selector!(page, "text=Target")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(span, :enabled) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(span, "span => span.parentElement.parentElement.disabled = false")
    Runtime.Promise.await(task)
  end

  test "RE-004 should wait for enclosing enabled button", %{page: page} do
    Page.set_content!(page, "<button disabled><span>Target</span></button>")
    span = Page.query_selector!(page, "text=Target")
    task = Runtime.Promise.async(fn -> ElementHandle.wait_for_element_state!(span, :enabled) end, shared: true)
    give_it_a_chance_to_resolve(page)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(span, "span => span.parentElement.disabled = false")
    Runtime.Promise.await(task)
  end

  test "RE-005 should check the box outside shadow dom label", %{page: page} do
    Page.set_content!(page, "<div></div>")

    Page.eval_on_selector!(page, "div", """
    div => {
      const root = div.attachShadow({ mode: 'open' });
      const label = document.createElement('label');
      label.setAttribute('for', 'target');
      label.textContent = 'Click me';
      root.appendChild(label);
      const input = document.createElement('input');
      input.setAttribute('type', 'checkbox');
      input.setAttribute('id', 'target');
      root.appendChild(input);
    }
    """)

    Page.check!(page, "label")
    assert Page.eval_on_selector!(page, "input", "input => input.checked") == true
  end

  test "RE-006 setInputFiles should work with label", %{page: page, asset: asset} do
    Page.set_content!(page, "<label for=target>Choose a file</label><input id=target type=file>")
    Page.set_input_files!(page, "text=Choose a file", asset.("file-to-upload.txt"))
    assert Page.eval_on_selector!(page, "input", "input => input.files.length") == 1

    assert Page.eval_on_selector!(page, "input", "input => input.files?.[0].name") ==
             "file-to-upload.txt"
  end

  defp options_to_attributes(options) do
    " #{if options[:disabled], do: "disabled", else: ""} #{if options[:hidden], do: "hidden", else: ""} " <>
      "#{if options[:readonly], do: "readonly", else: ""} "
  end

  defp dom_in_label(dom, options \\ []),
    do: "<label #{options_to_attributes(options)}>Text #{dom}</label>"

  defp dom_label_for(dom, options \\ []),
    do: ~s|<label #{options_to_attributes(options)} for="target"><h1>Text</h1></label>#{dom}|

  defp dom_standalone(dom), do: dom

  defp dom_in_button(dom, options \\ []),
    do: "<button #{options_to_attributes(options)}>Button #{dom}</button>"

  defp dom_in_link(dom, options \\ []),
    do: "<button #{options_to_attributes(options)}>Button #{dom}</button>"

  test "RE-007 enabled/disabled retargeting", %{page: page} do
    cases = [
      %{dom: dom_in_label("<input id=target>"), enabled: true, locator: "label"},
      %{dom: dom_label_for("<input id=target>"), enabled: true, locator: "label"},
      %{dom: dom_standalone("<input id=target>"), enabled: true, locator: "input"},
      %{dom: dom_in_button("<input id=target>"), enabled: true, locator: "input"},
      %{dom: dom_in_link("<input id=target>"), enabled: true, locator: "input"},
      %{dom: dom_in_button("<input id=target>", disabled: true), enabled: true, locator: "input"},
      %{
        dom: dom_in_label("<li role=menuitem id=target aria-disabled=false></li>"),
        enabled: true,
        locator: "li"
      },
      %{dom: dom_in_label("<input id=target disabled>"), enabled: false, locator: "label"},
      %{dom: dom_label_for("<input id=target disabled>"), enabled: false, locator: "label"},
      %{dom: dom_standalone("<input id=target disabled>"), enabled: false, locator: "input"},
      %{dom: dom_in_button("<input id=target disabled>"), enabled: false, locator: "input"},
      %{dom: dom_in_link("<input id=target disabled>"), enabled: false, locator: "input"},
      %{
        dom: dom_in_button("<input id=target disabled>", disabled: true),
        enabled: false,
        locator: "input"
      },
      %{
        dom: dom_in_label("<li role=menuitem id=target aria-disabled=true></li>"),
        enabled: false,
        locator: "li"
      }
    ]

    # it.step(`"${locator}" in "${dom}" should be enabled=${enabled}`)
    for %{dom: dom, enabled: enabled, locator: locator} <- cases do
      Page.set_content!(page, dom)
      target = Page.locator(page, locator)
      handle = Page.query_selector!(page, locator)
      assert Locator.is_enabled!(target) == enabled
      assert Locator.is_disabled!(target) == !enabled

      if enabled do
        Expect.to_be_enabled!(target)
        Expect.not_to_be_disabled!(target)
        ElementHandle.wait_for_element_state!(handle, :enabled)
      else
        Expect.not_to_be_enabled!(target)
        Expect.to_be_disabled!(target)
        ElementHandle.wait_for_element_state!(handle, :disabled)
      end
    end
  end

  test "RE-008 visible/hidden retargeting", %{page: page} do
    cases = [
      %{dom: dom_in_label("<span id=target>content</span>"), visible: true, locator: "label"},
      %{
        dom: dom_in_label("<span id=target hidden>content</span>"),
        visible: true,
        locator: "label"
      },
      %{dom: dom_label_for("<span id=target>content</span>"), visible: true, locator: "label"},
      %{
        dom: dom_label_for("<span id=target hidden>content</span>"),
        visible: true,
        locator: "label"
      },
      %{dom: dom_standalone("<span id=target>content</span>"), visible: true, locator: "span"},
      %{dom: dom_in_button("<span id=target>content</span>"), visible: true, locator: "span"},
      %{dom: dom_in_link("<span id=target>content</span>"), visible: true, locator: "span"},
      %{
        dom: dom_in_label("<span id=target>content</span>", hidden: true),
        visible: false,
        locator: "label"
      },
      %{
        dom: dom_label_for("<span id=target>content</span>", hidden: true),
        visible: false,
        locator: "label"
      },
      %{
        dom: dom_standalone("<span id=target hidden>content</span>"),
        visible: false,
        locator: "span"
      },
      %{
        dom: dom_in_button("<span id=target hidden>content</span>"),
        visible: false,
        locator: "span"
      },
      %{
        dom: dom_in_button("<span id=target>content</span>", hidden: true),
        visible: false,
        locator: "span"
      },
      %{
        dom: dom_in_link("<span id=target hidden>content</span>"),
        visible: false,
        locator: "span"
      },
      %{
        dom: dom_in_link("<span id=target>content</span>", hidden: true),
        visible: false,
        locator: "span"
      }
    ]

    # it.step(`"${locator}" in "${dom}" should be visible=${visible}`)
    for %{dom: dom, visible: visible, locator: locator} <- cases do
      Page.set_content!(page, dom)
      target = Page.locator(page, locator)
      handle = Page.query_selector!(page, locator)
      assert Locator.is_visible!(target) == visible
      assert Locator.is_hidden!(target) == !visible

      if visible do
        Expect.to_be_visible!(target)
        Expect.not_to_be_hidden!(target)
        ElementHandle.wait_for_element_state!(handle, :visible)
      else
        Expect.not_to_be_visible!(target)
        Expect.to_be_hidden!(target)
        ElementHandle.wait_for_element_state!(handle, :hidden)
      end
    end
  end

  test "RE-009 editable retargeting", %{page: page} do
    cases = [
      %{dom: dom_in_label("<input id=target>"), editable: true, locator: "label"},
      %{dom: dom_label_for("<input id=target>"), editable: true, locator: "label"},
      %{dom: dom_standalone("<input id=target>"), editable: true, locator: "input"},
      %{dom: dom_in_button("<input id=target>"), editable: true, locator: "input"},
      %{dom: dom_in_link("<input id=target>"), editable: true, locator: "input"},
      %{
        dom: dom_in_button("<input id=target>", readonly: true),
        editable: true,
        locator: "input"
      },
      %{dom: dom_in_label("<input id=target readonly>"), editable: false, locator: "label"},
      %{dom: dom_label_for("<input id=target readonly>"), editable: false, locator: "label"},
      %{dom: dom_standalone("<input id=target readonly>"), editable: false, locator: "input"},
      %{dom: dom_in_button("<input id=target readonly>"), editable: false, locator: "input"},
      %{dom: dom_in_link("<input id=target readonly>"), editable: false, locator: "input"},
      %{
        dom: dom_in_button("<input id=target readonly>", readonly: true),
        editable: false,
        locator: "input"
      }
    ]

    # it.step(`"${locator}" in "${dom}" should be editable=${editable}`)
    for %{dom: dom, editable: editable, locator: locator} <- cases do
      Page.set_content!(page, dom)
      target = Page.locator(page, locator)
      handle = Page.query_selector!(page, locator)
      assert Locator.is_editable!(target) == editable

      if editable do
        Expect.to_be_editable!(target)
        ElementHandle.wait_for_element_state!(handle, :editable)
      else
        Expect.not_to_be_editable!(target)
      end
    end
  end

  test "RE-010 input value retargeting", %{page: page} do
    cases = [
      %{dom: dom_in_label("<input id=target>"), locator: "label"},
      %{dom: dom_label_for("<input id=target>"), locator: "label"},
      %{dom: dom_standalone("<input id=target>"), locator: "input"},
      %{dom: dom_in_button("<input id=target>"), locator: "input"},
      %{dom: dom_in_link("<input id=target>"), locator: "input"},
      %{dom: dom_in_button("<input id=target>"), locator: "input"}
    ]

    # it.step(`"${locator}" in "${dom}" input value`)
    for %{dom: dom, locator: locator} <- cases do
      Page.set_content!(page, dom)
      target = Page.locator(page, locator)
      handle = Page.query_selector!(page, locator)

      assert Locator.input_value!(target) == ""
      assert ElementHandle.input_value!(handle) == ""
      Expect.to_have_value!(target, "")

      Locator.fill!(target, "foo")
      assert Locator.input_value!(target) == "foo"
      assert ElementHandle.input_value!(handle) == "foo"
      Expect.to_have_value!(target, "foo")

      Page.eval_on_selector!(page, "#target", "input => input.value = 'bar'")
      assert Locator.input_value!(target) == "bar"
      assert ElementHandle.input_value!(handle) == "bar"
      Expect.to_have_value!(target, "bar")

      Locator.select_text!(target)
      assert Page.evaluate!(page, "() => window.getSelection().toString()") == "bar"
    end
  end

  test "RE-011 selection retargeting", %{page: page} do
    cases = [
      %{dom: dom_standalone("<div contenteditable id=target>content</div>"), locator: "div"},
      %{dom: dom_in_button("<div contenteditable id=target>content</div>"), locator: "div"},
      %{dom: dom_in_link("<div contenteditable id=target>content</div>"), locator: "div"},
      %{dom: dom_in_button("<div contenteditable id=target>content</div>"), locator: "div"}
    ]

    # it.step(`"${locator}" in "${dom}" text selection`)
    for %{dom: dom, locator: locator} <- cases do
      Page.set_content!(page, dom)
      target = Page.locator(page, locator)
      handle = Page.query_selector!(page, locator)

      assert Locator.is_editable!(target) == true
      assert ElementHandle.is_editable!(handle) == true
      Expect.to_have_text!(Page.locator(page, "#target"), "content")

      Locator.fill!(target, "foo")
      Expect.to_have_text!(Page.locator(page, "#target"), "foo")

      Locator.select_text!(target)
      assert Page.evaluate!(page, "() => window.getSelection().toString()") == "foo"
    end
  end

  test "RE-012 select options retargeting", %{page: page} do
    select =
      "<select id=target multiple><option value=dog selected>Dog</option><option value=cat>Cat</option></select>"

    cases = [
      %{dom: dom_in_label(select), locator: "label"},
      %{dom: dom_label_for(select), locator: "label"},
      %{dom: dom_standalone(select), locator: "select"},
      %{dom: dom_in_button(select), locator: "select"},
      %{dom: dom_in_link(select), locator: "select"},
      %{dom: dom_in_button(select), locator: "select"}
    ]

    # it.step(`"${locator}" in "${dom}" select option`)
    for %{dom: dom, locator: locator} <- cases do
      Page.set_content!(page, dom)
      target = Page.locator(page, locator)
      handle = Page.query_selector!(page, locator)

      assert Locator.input_value!(target) == "dog"
      assert ElementHandle.input_value!(handle) == "dog"
      Expect.to_have_value!(target, "dog")
      Expect.to_have_values!(target, ["dog"])

      Locator.select_option!(target, "cat")
      assert Locator.input_value!(target) == "cat"
      assert ElementHandle.input_value!(handle) == "cat"
      Expect.to_have_value!(target, "cat")
      Expect.to_have_values!(target, ["cat"])
    end
  end

  test "RE-013 direct actions retargeting", %{page: page} do
    cases = [
      %{dom: dom_in_label("<div>content</div><input id=target value=oh>"), locator: "div"},
      %{dom: dom_label_for("<div>content</div><input id=target value=oh>"), locator: "div"},
      %{dom: dom_standalone("<div>content</div>"), locator: "div"},
      %{dom: dom_in_button("<div>content</div>"), locator: "div"},
      %{dom: dom_in_link("<div>content</div>"), locator: "div"},
      %{dom: dom_in_button("<div>content</div>"), locator: "div"}
    ]

    # it.step(`"${locator}" in "${dom}" direct actions`)
    for %{dom: dom, locator: locator} <- cases do
      Page.set_content!(page, dom)
      target = Page.locator(page, locator)

      assert Locator.inner_text!(target) == "content"
      assert Locator.text_content!(target) == "content"
      Expect.to_have_text!(target, "content")
      Expect.to_contain_text!(target, "content")
      Expect.not_to_be_focused!(target)
      Expect.to_have_count!(target, 1)

      Page.eval_on_selector!(page, "div", "div => div.foo = 'bar'")
      Expect.to_have_js_property!(target, "foo", "bar")

      Page.eval_on_selector!(page, "div", "div => div.classList.add('cls')")
      Expect.to_have_class!(target, "cls")

      Page.eval_on_selector!(page, "div", "div => div.id = 'myid'")
      Expect.to_have_id!(target, "myid")
      Expect.to_have_attribute!(target, "id", "myid")
      assert Locator.get_attribute!(target, "id") == "myid"
    end
  end

  test "RE-014 check retargeting", %{page: page} do
    cases = [
      %{dom: dom_in_label("<input type=checkbox id=target>"), locator: "label"},
      %{dom: dom_label_for("<input type=checkbox id=target>"), locator: "label"},
      %{dom: dom_standalone("<input type=checkbox id=target>"), locator: "input"},
      %{dom: dom_in_button("<input type=checkbox id=target>"), locator: "input"},
      %{dom: dom_in_link("<input type=checkbox id=target>"), locator: "input"},
      %{dom: dom_in_button("<input type=checkbox id=target>"), locator: "input"}
    ]

    # it.step(`"${locator}" in "${dom}" check`)
    for %{dom: dom, locator: locator} <- cases do
      Page.set_content!(page, dom)
      target = Page.locator(page, locator)
      assert Locator.is_checked!(target) == false
      Expect.not_to_be_checked!(target)
      Expect.to_be_checked!(target, checked: false)

      Page.eval_on_selector!(page, "input", "input => input.checked = true")
      assert Locator.is_checked!(target) == true
      Expect.to_be_checked!(target)
      Expect.to_be_checked!(target, checked: true)

      Locator.uncheck!(target)
      assert Page.eval_on_selector!(page, "input", "input => input.checked") == false

      Locator.check!(target)
      assert Page.eval_on_selector!(page, "input", "input => input.checked") == true

      Locator.set_checked!(target, false)
      assert Page.eval_on_selector!(page, "input", "input => input.checked") == false
    end
  end

  test "RE-015 should not retarget anchor into parent label", %{page: page} do
    Page.set_content!(page, """
    <label disabled>Text<a href='#' onclick='window.__clicked=1'>Target</a></label>
    """)

    Locator.click!(Page.locator(page, "a"))
    assert Page.evaluate!(page, "window.__clicked") == 1

    Page.set_content!(page, """
    <input type="radio" id="input-id" checked disabled />
    <label for="input-id">Text<a href='#' onclick='window.__clicked=2'>Target</a></label>
    """)

    Locator.click!(Page.locator(page, "a"))
    assert Page.evaluate!(page, "window.__clicked") == 2
  end
end
