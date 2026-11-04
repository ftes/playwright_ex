defmodule PlaywrightEx.Page.PageFocusTest do
  @upstream "tests/page/page-focus.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work @smoke", %{page: page, browser_name: browser_name} do
    # it.skip(browserName === 'firefox' && !isBidi);  -- isBidi: we run the default protocols
    if browser_name != "firefox" do
      Page.set_content!(page, "<div id=d1 tabIndex=0></div>")
      assert Page.evaluate!(page, "() => document.activeElement.nodeName") == "BODY"
      Page.focus!(page, "#d1")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "d1"
    end
  end

  # `focused = true` / `blurred = true`: messages to the test process.
  test "should emit focus event", %{page: page} do
    Page.set_content!(page, "<div id=d1 tabIndex=0></div>")
    test = self()
    Page.expose_function!(page, "focusEvent", fn -> send(test, :focused) end)

    Page.eval_on_selector!(
      page,
      "#d1",
      "d1 => d1.addEventListener('focus', window['focusEvent'])"
    )

    Page.focus!(page, "#d1")
    assert_receive :focused
  end

  test "should emit blur event", %{page: page} do
    Page.set_content!(page, "<div id=d1 tabIndex=0>DIV1</div><div id=d2 tabIndex=0>DIV2</div>")
    Page.focus!(page, "#d1")
    test = self()
    Page.expose_function!(page, "focusEvent", fn -> send(test, :focused) end)
    Page.expose_function!(page, "blurEvent", fn -> send(test, :blurred) end)
    Page.eval_on_selector!(page, "#d1", "d1 => d1.addEventListener('blur', window['blurEvent'])")

    Page.eval_on_selector!(
      page,
      "#d2",
      "d2 => d2.addEventListener('focus', window['focusEvent'])"
    )

    Page.focus!(page, "#d2")
    assert_receive :focused
    assert_receive :blurred
  end

  test "should traverse focus", %{page: page} do
    Page.set_content!(page, ~s|<input id="i1"><input id="i2">|)
    test = self()
    Page.expose_function!(page, "focusEvent", fn -> send(test, :focused) end)

    Page.eval_on_selector!(
      page,
      "#i2",
      "i2 => i2.addEventListener('focus', window['focusEvent'])"
    )

    Page.focus!(page, "#i1")
    keyboard = Page.keyboard(page)
    Keyboard.type!(keyboard, "First")
    Keyboard.press!(keyboard, "Tab")
    Keyboard.type!(keyboard, "Last")

    assert_receive :focused
    assert Page.eval_on_selector!(page, "#i1", "e => e.value") == "First"
    assert Page.eval_on_selector!(page, "#i2", "e => e.value") == "Last"
  end

  test "should traverse focus in all directions", %{page: page} do
    Page.set_content!(page, ~s|<input value="1"><input value="2"><input value="3">|)
    keyboard = Page.keyboard(page)
    Keyboard.press!(keyboard, "Tab")
    assert Page.evaluate!(page, "() => document.activeElement.value") == "1"
    Keyboard.press!(keyboard, "Tab")
    assert Page.evaluate!(page, "() => document.activeElement.value") == "2"
    Keyboard.press!(keyboard, "Tab")
    assert Page.evaluate!(page, "() => document.activeElement.value") == "3"
    Keyboard.press!(keyboard, "Shift+Tab")
    assert Page.evaluate!(page, "() => document.activeElement.value") == "2"
    Keyboard.press!(keyboard, "Shift+Tab")
    assert Page.evaluate!(page, "() => document.activeElement.value") == "1"
  end

  test "should traverse only form elements", %{page: page, browser_name: browser_name} do
    # it.skip(platform !== 'darwin' || browserName !== 'webkit',
    #     'Chromium and WebKit both have settings for tab traversing all links, but it is only on by default in WebKit.');
    if match?({:unix, :darwin}, :os.type()) and browser_name == "webkit" do
      Page.set_content!(page, """
      <input id="input-1">
      <button id="button">button</button>
      <a href id="link">link</a>
      <input id="input-2">
      """)

      keyboard = Page.keyboard(page)
      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input-1"
      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input-2"
      Keyboard.press!(keyboard, "Shift+Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input-1"
      Keyboard.press!(keyboard, "Alt+Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "button"
      Keyboard.press!(keyboard, "Alt+Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "link"
      Keyboard.press!(keyboard, "Alt+Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input-2"
      Keyboard.press!(keyboard, "Alt+Shift+Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "link"
      Keyboard.press!(keyboard, "Alt+Shift+Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "button"
      Keyboard.press!(keyboard, "Alt+Shift+Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input-1"
    end
  end

  test "clicking checkbox should activate it", %{page: page, browser_name: browser_name} do
    # it.skip(browserName === 'webkit', 'Safari does not focus on click');
    if browser_name != "webkit" do
      Page.set_content!(page, "<input type=checkbox></input>")
      Page.click!(page, "input")
      node_name = Page.evaluate!(page, "() => document.activeElement.nodeName")
      assert node_name == "INPUT"
    end
  end

  # https://github.com/microsoft/playwright/issues/32339
  test "tab should cycle between single input and browser", %{
    page: page,
    browser_name: browser_name
  } do
    # it.skip(browserName === 'chromium' && !isHeadlessShell, 'Chromium keeps input focused.');
    #   -- headless chromium is the headless shell
    # it.fixme(browserName === 'firefox');
    if browser_name != "firefox" do
      Page.set_content!(page, """
      <label for="input1">input1</label>
        <input id="input1">
        <script>
        {
          window.focusEvents = [];
          const input = document.getElementById('input1');
          input.addEventListener('blur', () => focusEvents.push('blur'));
          input.addEventListener('focus', () => focusEvents.push('focus'));
        }
        </script>
      """)

      keyboard = Page.keyboard(page)
      assert Page.evaluate!(page, "() => document.activeElement.tagName") == "BODY"
      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input1"
      assert Page.evaluate!(page, "() => window.focusEvents") == ["focus"]
      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.tagName") == "BODY"
      assert Page.evaluate!(page, "() => window.focusEvents") == ["focus", "blur"]
      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input1"
      assert Page.evaluate!(page, "() => window.focusEvents") == ["focus", "blur", "focus"]
    end
  end

  # https://github.com/microsoft/playwright/issues/32339
  test "tab should cycle between document elements and browser", %{
    page: page,
    browser_name: browser_name
  } do
    # it.skip(browserName === 'chromium' && !isHeadlessShell, 'Chromium keeps last input focused.');
    #   -- headless chromium is the headless shell
    # it.fixme(browserName === 'firefox');
    if browser_name != "firefox" do
      Page.set_content!(page, """
      <input id="input1">
      <input id="input2">
      <script>
        window.focusEvents = [];
        {
          const input = document.getElementById('input1');
          input.addEventListener('blur', () => focusEvents.push('blur1'));
          input.addEventListener('focus', () => focusEvents.push('focus1'));
        }
        {
          const input = document.getElementById('input2');
          input.addEventListener('blur', () => focusEvents.push('blur2'));
          input.addEventListener('focus', () => focusEvents.push('focus2'));
        }
      </script>
      """)

      keyboard = Page.keyboard(page)
      assert Page.evaluate!(page, "() => document.activeElement.tagName") == "BODY"
      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input1"
      assert Page.evaluate!(page, "() => window.focusEvents") == ["focus1"]
      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input2"
      assert Page.evaluate!(page, "() => window.focusEvents") == ["focus1", "blur1", "focus2"]
      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.tagName") == "BODY"

      assert Page.evaluate!(page, "() => window.focusEvents") == [
               "focus1",
               "blur1",
               "focus2",
               "blur2"
             ]

      Keyboard.press!(keyboard, "Tab")
      assert Page.evaluate!(page, "() => document.activeElement.id") == "input1"

      assert Page.evaluate!(page, "() => window.focusEvents") == [
               "focus1",
               "blur1",
               "focus2",
               "blur2",
               "focus1"
             ]
    end
  end

  # https://github.com/microsoft/playwright/issues/14254
  test "keeps focus on element when attempting to focus a non-focusable element", %{page: page} do
    Page.set_content!(page, """
    <div id="focusable" tabindex="0">focusable</div>
    <div id="non-focusable">not focusable</div>
    <script>
      window.eventLog = [];

      const focusable = document.getElementById("focusable");

      focusable.addEventListener('blur', () => window.eventLog.push('blur focusable'));
      focusable.addEventListener('focus', () => window.eventLog.push('focus focusable'));

      const nonFocusable = document.getElementById("non-focusable");
      nonFocusable.addEventListener('blur', () => window.eventLog.push('blur non-focusable'));
      nonFocusable.addEventListener('focus', () => window.eventLog.push('focus non-focusable'));
    </script>
    """)

    Locator.click!(Page.locator(page, "#focusable"))
    assert Page.evaluate!(page, "() => document.activeElement?.id") == "focusable"
    Locator.focus!(Page.locator(page, "#non-focusable"))
    assert Page.evaluate!(page, "() => document.activeElement?.id") == "focusable"
    assert Page.evaluate!(page, "() => window['eventLog']") == ["focus focusable"]
  end
end
