defmodule PlaywrightEx.Page.PageFocusTest do
  @upstream "tests/page/page-focus.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Expect
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  @tag skip: if(@browser_name == "firefox", do: "upstream skip: firefox (non-BiDi)")
  test "FO-001 should work @smoke", %{page: page} do
    # it.skip(browserName === 'firefox' && !isBidi);  -- isBidi: we run the default protocols
    Page.set_content!(page, "<div id=d1 tabIndex=0></div>")
    assert Page.evaluate!(page, "() => document.activeElement.nodeName") == "BODY"
    Page.focus!(page, "#d1")
    assert Page.evaluate!(page, "() => document.activeElement.id") == "d1"
  end

  # `focused = true` / `blurred = true`: messages to the test process.
  test "FO-002 should emit focus event", %{page: page} do
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

  test "FO-003 should emit blur event", %{page: page} do
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

  test "FO-004 should traverse focus", %{page: page} do
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

  test "FO-005 should traverse focus in all directions", %{page: page} do
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

  @tag skip:
         if(not match?({:unix, :darwin}, :os.type()) or @browser_name != "webkit",
           do:
             "upstream skip: Chromium and WebKit both have settings for tab traversing all links, but it is only on by default in WebKit."
         )
  test "FO-006 should traverse only form elements", %{page: page} do
    # it.skip(platform !== 'darwin' || browserName !== 'webkit',
    #     'Chromium and WebKit both have settings for tab traversing all links, but it is only on by default in WebKit.');
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

  @tag skip: if(@browser_name == "webkit", do: "upstream skip: Safari does not focus on click")
  test "FO-007 clicking checkbox should activate it", %{page: page} do
    # it.skip(browserName === 'webkit', 'Safari does not focus on click');
    Page.set_content!(page, "<input type=checkbox></input>")
    Page.click!(page, "input")
    node_name = Page.evaluate!(page, "() => document.activeElement.nodeName")
    assert node_name == "INPUT"
  end

  # https://github.com/microsoft/playwright/issues/32339
  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: firefox")
  test "FO-008 tab should cycle between single input and browser", %{
    page: page
  } do
    # it.skip(browserName === 'chromium' && !isHeadlessShell, 'Chromium keeps input focused.');
    #   -- headless chromium is the headless shell
    # it.fixme(browserName === 'firefox');
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

  # https://github.com/microsoft/playwright/issues/32339
  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: firefox")
  test "FO-009 tab should cycle between document elements and browser", %{
    page: page
  } do
    # it.skip(browserName === 'chromium' && !isHeadlessShell, 'Chromium keeps last input focused.');
    #   -- headless chromium is the headless shell
    # it.fixme(browserName === 'firefox');
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

  # https://github.com/microsoft/playwright/issues/14254
  test "FO-010 keeps focus on element when attempting to focus a non-focusable element", %{page: page} do
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

  test "FO-011 should move focus from an iframe to its parent", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/43280
    TestServer.set_route(server, "/frame.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<input id=inner>")
    end)

    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<iframe src="#{server.prefix}/frame.html"></iframe><input id=outer>))
    Locator.focus!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("#inner"))

    assert Locator.evaluate!(
             page |> Page.frame_locator("iframe") |> FrameLocator.locator("#inner"),
             "e => e === document.activeElement"
           ) == true

    Page.evaluate!(page, "() => document.getElementById('outer').focus()")
    Expect.to_be_focused!(Page.locator(page, "#outer"))

    assert Locator.evaluate!(
             page |> Page.frame_locator("iframe") |> FrameLocator.locator("#inner"),
             "e => e === document.activeElement"
           ) == false
  end

  test "FO-012 should tab from an iframe to its parent", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/43280
    TestServer.set_route(server, "/frame.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<input id=inner>")
    end)

    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<iframe src="#{server.prefix}/frame.html"></iframe><input id=outer>))
    Locator.click!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("#inner"))

    assert Locator.evaluate!(
             page |> Page.frame_locator("iframe") |> FrameLocator.locator("#inner"),
             "e => e === document.activeElement"
           ) == true

    Keyboard.press!(Page.keyboard(page), "Tab")
    Expect.to_be_focused!(Page.locator(page, "#outer"))
  end

  test "FO-013 should move focus from the parent into its iframe", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/43506
    TestServer.set_route(server, "/frame.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<input id=inner>")
    end)

    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<iframe src="#{server.prefix}/frame.html"></iframe><input id=outer>))
    Locator.focus!(Page.locator(page, "#outer"))
    Expect.to_be_focused!(Page.locator(page, "#outer"))
    # Call native focus() exactly once, locator.focus() would hide the bug by calling it twice.
    Page.evaluate!(page, "() => document.querySelector('iframe').contentDocument.querySelector('input').focus()")
    Expect.to_be_focused!(Page.locator(page, "iframe"))
    Expect.to_be_focused!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("#inner"))
  end
end
