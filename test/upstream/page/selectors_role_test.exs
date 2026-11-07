defmodule PlaywrightEx.Page.SelectorsRoleTest do
  @upstream "tests/page/selectors-role.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  # `locator.evaluateAll(els => els.map(e => e.outerHTML))`
  defp outer_html(locator), do: Locator.evaluate_all!(locator, "els => els.map(e => e.outerHTML)")

  test "SE-050 should detect roles", %{page: page} do
    Page.set_content!(page, """
    <button>Hello</button>
    <select multiple="" size="2"></select>
    <select></select>
    <h3>Heading</h3>
    <details><summary>Hello</summary></details>
    <div role="dialog">I am a dialog</div>
    """)

    assert outer_html(Page.locator(page, "role=button")) == ["<button>Hello</button>"]
    assert outer_html(Page.locator(page, "role=listbox")) == [~s(<select multiple="" size="2"></select>)]
    assert outer_html(Page.locator(page, "role=combobox")) == ["<select></select>"]
    assert outer_html(Page.locator(page, "role=heading")) == ["<h3>Heading</h3>"]
    assert outer_html(Page.locator(page, "role=group")) == ["<details><summary>Hello</summary></details>"]
    assert outer_html(Page.locator(page, "role=dialog")) == [~s(<div role="dialog">I am a dialog</div>)]
    assert outer_html(Page.locator(page, "role=menuitem")) == []
    assert outer_html(Page.get_by_role(page, :menuitem)) == []
  end

  test "SE-051 should support selected", %{page: page} do
    Page.set_content!(page, """
    <select>
      <option>Hi</option>
      <option selected>Hello</option>
    </select>
    <div>
      <div role="option" aria-selected="true">Hi</div>
      <div role="option" aria-selected="false">Hello</div>
    </div>
    """)

    assert outer_html(Page.locator(page, "role=option[selected]")) == [
             ~s(<option selected="">Hello</option>),
             ~s(<div role="option" aria-selected="true">Hi</div>)
           ]

    assert outer_html(Page.locator(page, "role=option[selected=true]")) == [
             ~s(<option selected="">Hello</option>),
             ~s(<div role="option" aria-selected="true">Hi</div>)
           ]

    assert outer_html(Page.get_by_role(page, :option, selected: true)) == [
             ~s(<option selected="">Hello</option>),
             ~s(<div role="option" aria-selected="true">Hi</div>)
           ]

    assert outer_html(Page.locator(page, "role=option[selected=false]")) == [
             "<option>Hi</option>",
             ~s(<div role="option" aria-selected="false">Hello</div>)
           ]

    assert outer_html(Page.get_by_role(page, :option, selected: false)) == [
             "<option>Hi</option>",
             ~s(<div role="option" aria-selected="false">Hello</div>)
           ]
  end

  test "SE-052 should support checked", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43662' }
    Page.set_content!(page, """
    <input type=checkbox>
    <input type=checkbox checked>
    <input type=checkbox indeterminate>
    <div role=checkbox aria-checked="true">Hi</div>
    <div role=checkbox aria-checked="false">Hello</div>
    <div role=checkbox>Unknown</div>
    """)

    Page.eval_on_selector!(page, "[indeterminate]", "input => input.indeterminate = true")

    assert outer_html(Page.locator(page, "role=checkbox[checked]")) == [
             ~s(<input type="checkbox" checked="">),
             ~s(<div role="checkbox" aria-checked="true">Hi</div>)
           ]

    assert outer_html(Page.locator(page, "role=checkbox[checked=true]")) == [
             ~s(<input type="checkbox" checked="">),
             ~s(<div role="checkbox" aria-checked="true">Hi</div>)
           ]

    assert outer_html(Page.get_by_role(page, :checkbox, checked: true)) == [
             ~s(<input type="checkbox" checked="">),
             ~s(<div role="checkbox" aria-checked="true">Hi</div>)
           ]

    assert outer_html(Page.locator(page, "role=checkbox[checked=false]")) == [
             ~s(<input type="checkbox">),
             ~s(<div role="checkbox" aria-checked="false">Hello</div>),
             ~s(<div role="checkbox">Unknown</div>)
           ]

    assert outer_html(Page.get_by_role(page, :checkbox, checked: false)) == [
             ~s(<input type="checkbox">),
             ~s(<div role="checkbox" aria-checked="false">Hello</div>),
             ~s(<div role="checkbox">Unknown</div>)
           ]

    assert outer_html(Page.locator(page, ~s(role=checkbox[checked="mixed"]))) == [
             ~s(<input type="checkbox" indeterminate="">)
           ]

    assert outer_html(Page.locator(page, "role=checkbox")) == [
             ~s(<input type="checkbox">),
             ~s(<input type="checkbox" checked="">),
             ~s(<input type="checkbox" indeterminate="">),
             ~s(<div role="checkbox" aria-checked="true">Hi</div>),
             ~s(<div role="checkbox" aria-checked="false">Hello</div>),
             ~s(<div role="checkbox">Unknown</div>)
           ]

    Page.set_content!(page, """
    <div role="checkbox" aria-checked="True" aria-readonly="True"
      onclick="this.setAttribute('aria-checked', String(this.getAttribute('aria-checked').toLowerCase() !== 'true'))">Remember me</div>
    <button aria-pressed="True">Bold</button>
    <button aria-expanded="True">Menu</button>
    <div role="Button" tabindex="0">Save</div>
    """)

    checkbox = Page.get_by_role(page, :checkbox)
    assert Locator.count!(Page.get_by_role(page, :checkbox, checked: true)) == 1
    assert Locator.count!(Page.get_by_role(page, :button, pressed: true)) == 1
    assert Locator.count!(Page.get_by_role(page, :button, expanded: true)) == 1
    assert Locator.count!(Page.get_by_role(page, :button, name: "Save")) == 1
    Expect.to_be_checked!(checkbox)
    Expect.not_to_be_editable!(checkbox)

    Expect.to_match_aria_snapshot!(Page.locator(page, "body"), """
    - checkbox "Remember me" [checked]
    - button "Bold" [pressed]
    - button "Menu" [expanded]
    - button "Save"
    """)

    Locator.check!(checkbox)
    Expect.to_have_attribute!(checkbox, "aria-checked", "True")

    Locator.evaluate!(checkbox, "element => element.setAttribute('aria-checked', 'Mixed')")

    Locator.evaluate!(
      Page.get_by_role(page, :button, name: "Bold"),
      "element => element.setAttribute('aria-pressed', 'Mixed')"
    )

    assert Locator.count!(Page.locator(page, "role=checkbox[checked=mixed]")) == 1
    assert Locator.count!(Page.locator(page, "role=button[pressed=mixed]")) == 1
  end

  test "SE-053 should support pressed", %{page: page} do
    Page.set_content!(page, """
    <button>Hi</button>
    <button aria-pressed="true">Hello</button>
    <button aria-pressed="false">Bye</button>
    <button aria-pressed="mixed">Mixed</button>
    """)

    assert outer_html(Page.locator(page, "role=button[pressed]")) == [~s(<button aria-pressed="true">Hello</button>)]

    assert outer_html(Page.locator(page, "role=button[pressed=true]")) == [
             ~s(<button aria-pressed="true">Hello</button>)
           ]

    assert outer_html(Page.get_by_role(page, :button, pressed: true)) == [
             ~s(<button aria-pressed="true">Hello</button>)
           ]

    assert outer_html(Page.locator(page, "role=button[pressed=false]")) == [
             "<button>Hi</button>",
             ~s(<button aria-pressed="false">Bye</button>)
           ]

    assert outer_html(Page.get_by_role(page, :button, pressed: false)) == [
             "<button>Hi</button>",
             ~s(<button aria-pressed="false">Bye</button>)
           ]

    assert outer_html(Page.locator(page, ~s(role=button[pressed="mixed"]))) == [
             ~s(<button aria-pressed="mixed">Mixed</button>)
           ]

    assert outer_html(Page.locator(page, "role=button")) == [
             "<button>Hi</button>",
             ~s(<button aria-pressed="true">Hello</button>),
             ~s(<button aria-pressed="false">Bye</button>),
             ~s(<button aria-pressed="mixed">Mixed</button>)
           ]
  end

  test "SE-054 should support expanded", %{page: page} do
    Page.set_content!(page, """
    <div role="treeitem">Hi</div>
    <div role="treeitem" aria-expanded="true">Hello</div>
    <div role="treeitem" aria-expanded="false">Bye</div>
    """)

    assert outer_html(Page.locator(page, "role=treeitem")) == [
             ~s(<div role="treeitem">Hi</div>),
             ~s(<div role="treeitem" aria-expanded="true">Hello</div>),
             ~s(<div role="treeitem" aria-expanded="false">Bye</div>)
           ]

    assert outer_html(Page.get_by_role(page, :treeitem)) == [
             ~s(<div role="treeitem">Hi</div>),
             ~s(<div role="treeitem" aria-expanded="true">Hello</div>),
             ~s(<div role="treeitem" aria-expanded="false">Bye</div>)
           ]

    assert outer_html(Page.locator(page, "role=treeitem[expanded]")) == [
             ~s(<div role="treeitem" aria-expanded="true">Hello</div>)
           ]

    assert outer_html(Page.locator(page, "role=treeitem[expanded=true]")) == [
             ~s(<div role="treeitem" aria-expanded="true">Hello</div>)
           ]

    assert outer_html(Page.get_by_role(page, :treeitem, expanded: true)) == [
             ~s(<div role="treeitem" aria-expanded="true">Hello</div>)
           ]

    assert outer_html(Page.locator(page, "role=treeitem[expanded=false]")) == [
             ~s(<div role="treeitem" aria-expanded="false">Bye</div>)
           ]

    assert outer_html(Page.get_by_role(page, :treeitem, expanded: false)) == [
             ~s(<div role="treeitem" aria-expanded="false">Bye</div>)
           ]

    # Workaround for expanded="none".
    assert outer_html(Page.locator(page, "[role=treeitem]:not([aria-expanded])")) == [
             ~s(<div role="treeitem">Hi</div>)
           ]
  end

  test "SE-055 should support disabled", %{page: page} do
    Page.set_content!(page, """
    <button>Hi</button>
    <button disabled>Bye</button>
    <button aria-disabled="true">Hello</button>
    <button aria-disabled="false">Oh</button>
    <fieldset disabled>
      <button>Yay</button>
    </fieldset>
    <select>
      <optgroup disabled>
        <option>one</option>
      </optgroup>
      <optgroup>
        <option>two</option>
      </optgroup>
      <option disabled>three</option>
    </select>
    """)

    assert outer_html(Page.locator(page, "role=button[disabled]")) == [
             ~s(<button disabled="">Bye</button>),
             ~s(<button aria-disabled="true">Hello</button>),
             "<button>Yay</button>"
           ]

    assert outer_html(Page.locator(page, "role=button[disabled=true]")) == [
             ~s(<button disabled="">Bye</button>),
             ~s(<button aria-disabled="true">Hello</button>),
             "<button>Yay</button>"
           ]

    assert outer_html(Page.get_by_role(page, :button, disabled: true)) == [
             ~s(<button disabled="">Bye</button>),
             ~s(<button aria-disabled="true">Hello</button>),
             "<button>Yay</button>"
           ]

    assert outer_html(Page.locator(page, "role=button[disabled=false]")) == [
             "<button>Hi</button>",
             ~s(<button aria-disabled="false">Oh</button>)
           ]

    assert outer_html(Page.get_by_role(page, :button, disabled: false)) == [
             "<button>Hi</button>",
             ~s(<button aria-disabled="false">Oh</button>)
           ]

    assert outer_html(Page.get_by_role(page, :option, disabled: true)) == [
             "<option>one</option>",
             ~s(<option disabled="">three</option>)
           ]

    assert outer_html(Page.get_by_role(page, :option, disabled: false)) == ["<option>two</option>"]

    assert outer_html(Page.get_by_role(page, :option)) == [
             "<option>one</option>",
             "<option>two</option>",
             ~s(<option disabled="">three</option>)
           ]
  end

  test "SE-056 should inherit disabled from the ancestor", %{page: page} do
    Page.set_content!(page, """
    <span aria-disabled="true">
      <button>Click me!</button>
    </span>
    """)

    Expect.to_be_disabled!(Page.locator(page, "button"))

    Page.set_content!(page, """
    <span aria-disabled="true">
      <h1>Heading</h1>
    </span>
    """)

    Expect.not_to_be_disabled!(Page.locator(page, "h1"))
  end

  test "SE-057 should support disabled fieldset", %{page: page} do
    Page.set_content!(page, """
    <fieldset disabled>
      <input></input>
      <button data-testid="inside-fieldset-element">x</button>
      <legend>
        <button data-testid="inside-legend-element">legend</button>
      </legend>
    </fieldset>

    <fieldset disabled>
      <legend>
        <div>
          <button data-testid="nested-inside-legend-element">x</button>
        </div>
      </legend>
    </fieldset>

    <fieldset disabled>
      <div></div>
      <legend>
        <button data-testid="first-legend-element">x</button>
      </legend>
      <legend>
        <button data-testid="second-legend-element">x</button>
      </legend>
    </fieldset>

    <fieldset disabled>
      <fieldset>
        <button data-testid="deep-button">x</button>
      </fieldset>
    </fieldset>
    """)

    # expect.soft: the first failure ends the test here.
    Expect.to_be_enabled!(Page.get_by_test_id(page, "inside-legend-element"))
    Expect.to_be_enabled!(Page.get_by_test_id(page, "nested-inside-legend-element"))
    Expect.to_be_enabled!(Page.get_by_test_id(page, "first-legend-element"))
    Expect.to_be_disabled!(Page.get_by_test_id(page, "second-legend-element"))
    Expect.to_be_disabled!(Page.get_by_test_id(page, "deep-button"))
  end

  test "SE-058 should support level", %{page: page} do
    Page.set_content!(page, """
    <h1>Hello</h1>
    <h3>Hi</h3>
    <div role="heading" aria-level="5">Bye</div>
    """)

    assert outer_html(Page.locator(page, "role=heading[level=1]")) == ["<h1>Hello</h1>"]
    assert outer_html(Page.get_by_role(page, :heading, level: 1)) == ["<h1>Hello</h1>"]
    assert outer_html(Page.locator(page, "role=heading[level=3]")) == ["<h3>Hi</h3>"]
    assert outer_html(Page.get_by_role(page, :heading, level: 3)) == ["<h3>Hi</h3>"]

    assert outer_html(Page.locator(page, "role=heading[level=5]")) == [
             ~s(<div role="heading" aria-level="5">Bye</div>)
           ]
  end

  test "SE-059 should filter hidden, unless explicitly asked for", %{page: page} do
    Page.set_content!(page, """
    <button>Hi</button>
    <button hidden>Hello</button>
    <button aria-hidden="true">Yay</button>
    <button aria-hidden="false">Nay</button>
    <button style="visibility:hidden">Bye</button>
    <div style="visibility:hidden">
      <button>Oh</button>
    </div>
    <div style="visibility:hidden">
      <button style="visibility:visible">Still here</button>
    </div>
    <button style="display:none">Never</button>
    <div id=host1></div>
    <div id=host2 style="display:none"></div>

    <input name="one">
    <details>
      <summary>Open form</summary>
      <label>
         Label
         <input name="two">
      </label>
    </details>

    <select>
      <option style="visibility:hidden">One</option>
      <option style="display:none">Two</option>
      <option>Three</option>
    </select>

    <script>
      function addButton(host, text) {
        const root = host.attachShadow({ mode: 'open' });
        const button = document.createElement('button');
        button.textContent = text;
        root.appendChild(button);
      }
      addButton(document.getElementById('host1'), 'Shadow1');
      addButton(document.getElementById('host2'), 'Shadow2');
    </script>
    """)

    assert outer_html(Page.locator(page, "role=button")) == [
             "<button>Hi</button>",
             ~s(<button aria-hidden="false">Nay</button>),
             ~s(<button style="visibility:visible">Still here</button>),
             "<button>Shadow1</button>"
           ]

    assert outer_html(Page.locator(page, "role=button[include-hidden]")) == [
             "<button>Hi</button>",
             ~s(<button hidden="">Hello</button>),
             ~s(<button aria-hidden="true">Yay</button>),
             ~s(<button aria-hidden="false">Nay</button>),
             ~s(<button style="visibility:hidden">Bye</button>),
             "<button>Oh</button>",
             ~s(<button style="visibility:visible">Still here</button>),
             ~s(<button style="display:none">Never</button>),
             "<button>Shadow1</button>",
             "<button>Shadow2</button>"
           ]

    assert outer_html(Page.locator(page, "role=button[include-hidden=true]")) == [
             "<button>Hi</button>",
             ~s(<button hidden="">Hello</button>),
             ~s(<button aria-hidden="true">Yay</button>),
             ~s(<button aria-hidden="false">Nay</button>),
             ~s(<button style="visibility:hidden">Bye</button>),
             "<button>Oh</button>",
             ~s(<button style="visibility:visible">Still here</button>),
             ~s(<button style="display:none">Never</button>),
             "<button>Shadow1</button>",
             "<button>Shadow2</button>"
           ]

    assert outer_html(Page.locator(page, "role=button[include-hidden=false]")) == [
             "<button>Hi</button>",
             ~s(<button aria-hidden="false">Nay</button>),
             ~s(<button style="visibility:visible">Still here</button>),
             "<button>Shadow1</button>"
           ]

    assert outer_html(Page.locator(page, "role=textbox")) == [~s(<input name="one">)]

    assert outer_html(Page.locator(page, "role=option")) == [
             ~s(<option style="visibility:hidden">One</option>),
             "<option>Three</option>"
           ]
  end

  test "SE-060 should support name", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43549' }
    Page.set_content!(page, """
    <div role="button" aria-label=" Hello "></div>
    <div role="button" aria-label="Hallo"></div>
    <div role="button" aria-label="Hello" aria-hidden="true"></div>
    <div role="button" aria-label="123" aria-hidden="true"></div>
    <div role="button" aria-label='foo"bar' aria-hidden="true"></div>

    <span id="title">Chosen name</span>
    <div role="group" aria-labelledby="title"></div>
    """)

    group = Page.get_by_role(page, :group)
    Expect.to_have_accessible_name!(group, "Chosen name")

    assert outer_html(Page.locator(page, ~s(role=button[name="Hello"]))) == [
             ~s(<div role="button" aria-label=" Hello "></div>)
           ]

    assert outer_html(Page.locator(page, ~s(role=button[name=" \n Hello "]))) == [
             ~s(<div role="button" aria-label=" Hello "></div>)
           ]

    assert outer_html(Page.get_by_role(page, :button, name: "Hello")) == [
             ~s(<div role="button" aria-label=" Hello "></div>)
           ]

    assert outer_html(Page.locator(page, ~s(role=button[name*="all"]))) == [
             ~s(<div role="button" aria-label="Hallo"></div>)
           ]

    assert outer_html(Page.locator(page, "role=button[name=/^H[ae]llo$/]")) == [
             ~s(<div role="button" aria-label=" Hello "></div>),
             ~s(<div role="button" aria-label="Hallo"></div>)
           ]

    assert outer_html(Page.get_by_role(page, :button, name: ~r/^H[ae]llo$/)) == [
             ~s(<div role="button" aria-label=" Hello "></div>),
             ~s(<div role="button" aria-label="Hallo"></div>)
           ]

    assert outer_html(Page.locator(page, "role=button[name=/h.*o/i]")) == [
             ~s(<div role="button" aria-label=" Hello "></div>),
             ~s(<div role="button" aria-label="Hallo"></div>)
           ]

    assert outer_html(Page.get_by_role(page, :button, name: ~r/h.*o/i)) == [
             ~s(<div role="button" aria-label=" Hello "></div>),
             ~s(<div role="button" aria-label="Hallo"></div>)
           ]

    assert outer_html(Page.locator(page, ~s(role=button[name="Hello"][include-hidden]))) == [
             ~s(<div role="button" aria-label=" Hello "></div>),
             ~s(<div role="button" aria-label="Hello" aria-hidden="true"></div>)
           ]

    assert outer_html(Page.get_by_role(page, :button, name: "Hello", include_hidden: true)) == [
             ~s(<div role="button" aria-label=" Hello "></div>),
             ~s(<div role="button" aria-label="Hello" aria-hidden="true"></div>)
           ]

    assert outer_html(Page.get_by_role(page, :button, name: "hello", include_hidden: true)) == [
             ~s(<div role="button" aria-label=" Hello "></div>),
             ~s(<div role="button" aria-label="Hello" aria-hidden="true"></div>)
           ]

    assert outer_html(Page.locator(page, "role=button[name=Hello]")) == [
             ~s(<div role="button" aria-label=" Hello "></div>)
           ]

    assert outer_html(Page.locator(page, "role=button[name=123][include-hidden]")) == [
             ~s(<div role="button" aria-label="123" aria-hidden="true"></div>)
           ]

    assert outer_html(Page.get_by_role(page, :button, name: "123", include_hidden: true)) == [
             ~s(<div role="button" aria-label="123" aria-hidden="true"></div>)
           ]

    # Old electron/android do not have this API.
    # isMissingAriaLabelledByElements (chromium < 135): the pinned browsers are newer.
    Locator.evaluate!(group, """
    element => {
      element.ariaLabelledByElements = [document.querySelector('#title')];
    }
    """)

    assert outer_html(Page.get_by_role(page, :group, name: "Chosen name", exact: true)) == [
             ~s(<div role="group" aria-labelledby=""></div>)
           ]
  end

  test "SE-061 should support option name with html whitespace", %{page: page} do
    Page.set_content!(page, """
    <select>
      <option value="html">&nbsp;HTML</option>
    </select>
    """)

    Expect.to_have_count!(Page.get_by_role(page, :option, name: "HTML"), 1)
  end

  test "SE-062 errors", %{page: page} do
    {:error, e0} = Page.query_selector(page, "role=[bar]")
    assert e0.message =~ "Role must not be empty"

    {:error, e1} = Page.query_selector(page, "role=foo[sElected]")

    assert e1.message =~
             ~s(Unknown attribute "sElected", must be one of "checked", "description", "disabled", "expanded", "include-hidden", "level", "name", "pressed", "selected")

    {:error, e2} = Page.query_selector(page, "role=foo[bar . qux=true]")
    assert e2.message =~ ~s(Unknown attribute "bar.qux")

    {:error, e3} = Page.query_selector(page, ~s(role=heading[level="bar"]))
    assert e3.message =~ ~s("level" attribute must be compared to a number)

    {:error, e4} = Page.query_selector(page, ~s(role=checkbox[checked="bar"]))
    assert e4.message =~ ~s("checked" must be one of true, false, "mixed")

    {:error, e5} = Page.query_selector(page, "role=checkbox[checked~=true]")
    assert e5.message =~ "cannot use ~= in attribute with non-string matching value"

    {:error, e6} = Page.query_selector(page, "role=button[level=3]")
    assert e6.message =~ ~s("level" attribute is only supported for roles: "heading", "listitem", "row", "treeitem")

    {:error, e7} = Page.query_selector(page, "role=button[name]")
    assert e7.message =~ ~s("name" attribute must have a value)

    {:error, e8} = Page.query_selector(page, ~s(role=treeitem[expanded="none"]))
    assert e8.message =~ ~s("expanded" must be one of true, false)
  end

  test "SE-063 hidden with shadow dom slots", %{page: page} do
    Page.set_content!(page, """
    <div make-hidden>
      <button>hidden1</button>
    </div>
    <div make-hidden>
      <span><button>hidden2</button></v>
    </div>
    <div>
      <button>visible1</button>
    </div>
    <div>
      <span><button>visible2</button></span>
    </div>
    <script>
      for (const div of document.querySelectorAll('div')) {
        const hidden = div.hasAttribute('make-hidden');
        div.attachShadow({ mode: 'open' }).innerHTML = hidden ? 'nothing to see here' : '<slot></slot>';
      }
    </script>
    """)

    assert outer_html(Page.locator(page, "role=button")) == [
             "<button>visible1</button>",
             "<button>visible2</button>"
           ]

    assert outer_html(Page.locator(page, "role=button[include-hidden]")) == [
             "<button>hidden1</button>",
             "<button>hidden2</button>",
             "<button>visible1</button>",
             "<button>visible2</button>"
           ]
  end

  test "SE-064 should support output accessible name", %{page: page} do
    Page.set_content!(page, "<label>Output1<output>output</output></label>")
    Expect.to_be_visible!(Page.get_by_role(page, :status, name: "Output1"))
  end

  test "SE-065 should not match scope by default", %{page: page} do
    Page.set_content!(page, """
    <ul>
      <li aria-label="Parent list">
        Parent list
        <ul>
          <li>child 1</li>
          <li>child 2</li>
        </ul>
      </li>
    </ul>
    """)

    children = page |> Page.get_by_role(:listitem, name: "Parent list") |> Locator.get_by_role(:listitem)
    Expect.to_have_count!(children, 2)
    Expect.to_have_text!(children, ["child 1", "child 2"])
  end
end
