defmodule PlaywrightEx.Page.PageCheckTest do
  @upstream "tests/page/page-check.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Page

  @moduletag :page

  @roles ["checkbox", "menuitemcheckbox", "option", "radio", "switch", "menuitemradio", "treeitem"]

  test "CH-001 should check the box @smoke", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox'></input>")
    Page.check!(page, "input")
    assert Page.evaluate!(page, "() => window['checkbox'].checked") == true
  end

  test "CH-002 should not check the checked box", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox' checked></input>")
    Page.check!(page, "input")
    assert Page.evaluate!(page, "() => window['checkbox'].checked") == true
  end

  test "CH-003 should uncheck the box", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox' checked></input>")
    Page.uncheck!(page, "input")
    assert Page.evaluate!(page, "() => window['checkbox'].checked") == false
  end

  test "CH-004 should not uncheck the unchecked box", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox'></input>")
    Page.uncheck!(page, "input")
    assert Page.evaluate!(page, "() => window['checkbox'].checked") == false
  end

  test "CH-005 should check radio", %{page: page} do
    Page.set_content!(page, """
    <input type='radio'>one</input>
    <input id='two' type='radio'>two</input>
    <input type='radio'>three</input>
    """)

    Page.check!(page, "#two")
    assert Page.evaluate!(page, "() => window['two'].checked") == true
  end

  test "CH-006 should check radio by aria role", %{page: page} do
    Page.set_content!(page, """
    <div role='radio' id='checkbox'>CHECKBOX</div>
    <script>
      checkbox.addEventListener('click', () => checkbox.setAttribute('aria-checked', 'true'));
    </script>
    """)

    Page.check!(page, "div")
    assert Page.evaluate!(page, "() => window['checkbox'].getAttribute('aria-checked')") == "true"
  end

  test "CH-007 should uncheck radio by aria role", %{page: page} do
    Page.set_content!(page, """
    <div role='radio' id='checkbox' aria-checked="true">CHECKBOX</div>
    <script>
      checkbox.addEventListener('click', () => checkbox.setAttribute('aria-checked', 'false'));
    </script>
    """)

    Page.uncheck!(page, "div")
    assert Page.evaluate!(page, "() => window['checkbox'].getAttribute('aria-checked')") == "false"
  end

  test "CH-008 should check the box by aria role", %{page: page} do
    for role <- @roles do
      # it.step(`role=${role}`)
      Page.set_content!(page, """
      <div role='#{role}' id='checkbox'>CHECKBOX</div>
      <script>
        checkbox.addEventListener('click', () => checkbox.setAttribute('aria-checked', 'true'));
      </script>
      """)

      Page.check!(page, "div")

      assert Page.evaluate!(page, "() => window['checkbox'].getAttribute('aria-checked')") == "true",
             "role=#{role}"
    end
  end

  test "CH-009 should uncheck the box by aria role", %{page: page} do
    for role <- @roles do
      # it.step(`role=${role}`)
      Page.set_content!(page, """
      <div role='#{role}' id='checkbox' aria-checked="true">CHECKBOX</div>
      <script>
        checkbox.addEventListener('click', () => checkbox.setAttribute('aria-checked', 'false'));
      </script>
      """)

      Page.uncheck!(page, "div")

      assert Page.evaluate!(page, "() => window['checkbox'].getAttribute('aria-checked')") == "false",
             "role=#{role}"
    end
  end

  test "CH-010 should throw when not a checkbox", %{page: page} do
    Page.set_content!(page, "<div>Check me</div>")
    {:error, error} = Page.check(page, "div")
    assert Exception.message(error) =~ "Not a checkbox or radio button"
  end

  test "CH-011 should throw when not a checkbox 2", %{page: page} do
    Page.set_content!(page, "<div role=button>Check me</div>")
    {:error, error} = Page.check(page, "div")
    assert Exception.message(error) =~ "Not a checkbox or radio button"
  end

  test "CH-012 should check the box inside a button", %{page: page} do
    Page.set_content!(page, "<div role='button'><input type='checkbox'></div>")
    Page.check!(page, "input")
    assert Page.eval_on_selector!(page, "input", "input => input.checked") == true
    assert Page.is_checked!(page, "input") == true
    assert ElementHandle.is_checked!(Page.query_selector!(page, "input")) == true
  end

  test "CH-013 should check the label with position", %{page: page, server: server} do
    Page.set_content!(page, """
    <input id='checkbox' type='checkbox' style='width: 5px; height: 5px;'>
    <label for='checkbox'>
      <a href=#{JSON.encode!(server.empty_page)}>I am a long link that goes away so that nothing good will happen if you click on me</a>
      Click me
    </label>
    """)

    box = ElementHandle.bounding_box!(Page.query_selector!(page, "text=Click me"))
    Page.check!(page, "text=Click me", position: %{x: box.width - 10, y: 2})
    assert Page.eval_on_selector!(page, "input", "input => input.checked") == true
  end

  test "CH-014 trial run should not check", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox'></input>")
    Page.check!(page, "input", trial: true)
    assert Page.evaluate!(page, "() => window['checkbox'].checked") == false
  end

  test "CH-015 trial run should not uncheck", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox' checked></input>")
    Page.uncheck!(page, "input", trial: true)
    assert Page.evaluate!(page, "() => window['checkbox'].checked") == true
  end

  test "CH-016 should check the box using setChecked", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox'></input>")
    Page.set_checked!(page, "input", true)
    assert Page.evaluate!(page, "() => window['checkbox'].checked") == true
    Page.set_checked!(page, "input", false)
    assert Page.evaluate!(page, "() => window['checkbox'].checked") == false
  end

  test "CH-017 should throw when trying to uncheck radio button", %{page: page} do
    Page.set_content!(page, "<input type='radio' name='test' checked id='radio'>")
    {:error, error} = Page.uncheck(page, "#radio")
    assert Exception.message(error) =~ "Cannot uncheck radio button"
  end
end
