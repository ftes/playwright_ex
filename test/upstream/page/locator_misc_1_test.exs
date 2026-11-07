defmodule PlaywrightEx.Page.LocatorMisc1Test do
  @upstream "tests/page/locator-misc-1.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "LO-127 should hover @smoke", %{page: page, server: server} do
    # it.skip(!headless, 'headed messes up with hover');
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    button = Page.locator(page, "#button-6")
    Locator.hover!(button)
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-6"
  end

  test "LO-128 should hover when Node is removed", %{page: page, server: server} do
    # it.skip(!headless, 'headed messes up with hover');
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Page.evaluate!(page, "() => delete window['Node']")
    button = Page.locator(page, "#button-6")
    Locator.hover!(button)
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-6"
  end

  test "LO-129 should fill input", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    handle = Page.locator(page, "input")
    Locator.fill!(handle, "some value")
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "LO-130 should fill input when Node is removed", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.evaluate!(page, "() => delete window['Node']")
    handle = Page.locator(page, "input")
    Locator.fill!(handle, "some value")
    assert Page.evaluate!(page, "() => window['result']") == "some value"
  end

  test "LO-131 should clear input", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    handle = Page.locator(page, "input")
    Locator.fill!(handle, "some value")
    assert Page.evaluate!(page, "() => window['result']") == "some value"
    Locator.clear!(handle)
    assert Page.evaluate!(page, "() => window['result']") == ""
  end

  test "LO-132 should check the box", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox'></input>")
    input = Page.locator(page, "input")
    Locator.check!(input)
    assert Page.evaluate!(page, "checkbox.checked") == true
  end

  test "LO-133 should check the box using setChecked", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox'></input>")
    input = Page.locator(page, "input")
    Locator.set_checked!(input, true)
    assert Page.evaluate!(page, "checkbox.checked") == true
    Locator.set_checked!(input, false)
    assert Page.evaluate!(page, "checkbox.checked") == false
  end

  test "LO-134 should uncheck the box", %{page: page} do
    Page.set_content!(page, "<input id='checkbox' type='checkbox' checked></input>")
    input = Page.locator(page, "input")
    Locator.uncheck!(input)
    assert Page.evaluate!(page, "checkbox.checked") == false
  end

  test "LO-135 should select single option", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/select.html")
    select = Page.locator(page, "select")
    Locator.select_option!(select, "blue")
    assert Page.evaluate!(page, "() => window['result'].onInput") == ["blue"]
    assert Page.evaluate!(page, "() => window['result'].onChange") == ["blue"]
  end

  test "LO-136 should focus and blur a button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.locator(page, "button")
    assert Locator.evaluate!(button, "button => document.activeElement === button") == false

    # `focused = true` / `blurred = true`: messages to the test process.
    test = self()

    Page.expose_function!(page, "focusEvent", fn ->
      send(test, :focused)
      true
    end)

    Page.expose_function!(page, "blurEvent", fn ->
      send(test, :blurred)
      true
    end)

    Locator.evaluate!(button, """
    button => {
      button.addEventListener('focus', window['focusEvent']);
      button.addEventListener('blur', window['blurEvent']);
    }
    """)

    Locator.focus!(button)
    assert_received :focused
    refute_received :blurred
    assert Locator.evaluate!(button, "button => document.activeElement === button") == true

    Locator.blur!(button)
    assert_received :blurred
    assert Locator.evaluate!(button, "button => document.activeElement === button") == false
  end

  test "LO-137 focus should respect strictness", %{page: page} do
    Page.set_content!(page, "<div>A</div><div>B</div>")
    {:error, error} = Locator.focus(Page.locator(page, "div"))
    assert Exception.message(error) =~ "strict mode violation"
  end

  test "LO-138 should dispatch click event via ElementHandles", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.locator(page, "button")
    Locator.dispatch_event!(button, "click")
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "LO-139 should upload the file", %{page: page, server: server, asset: asset} do
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    file_path = Path.relative_to_cwd(asset.("file-to-upload.txt"))
    input = Page.locator(page, "input[type=file]")
    Locator.set_input_files!(input, file_path)

    assert Page.evaluate!(page, "e => e.files[0].name", Locator.element_handle!(input)) ==
             "file-to-upload.txt"
  end
end
