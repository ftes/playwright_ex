defmodule PlaywrightEx.Page.PageKeyboardTest do
  @upstream "tests/page/page-keyboard.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  @is_mac match?({:unix, :darwin}, :os.type())

  test "should type into a textarea @smoke", %{page: page} do
    Page.evaluate!(page, """
    () => {
      const textarea = document.createElement('textarea');
      document.body.appendChild(textarea);
      textarea.focus();
    }
    """)

    text = "Hello world. I am the text that was typed!"
    Keyboard.type!(Page.keyboard(page), text)
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == text
  end

  test "should move with the arrow keys", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.type!(page, "textarea", "Hello World!")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "Hello World!"
    for _ <- 1..String.length("World!"), do: Keyboard.press!(Page.keyboard(page), "ArrowLeft")
    Keyboard.type!(Page.keyboard(page), "inserted ")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "Hello inserted World!"
    Keyboard.down!(Page.keyboard(page), "Shift")
    for _ <- 1..String.length("inserted "), do: Keyboard.press!(Page.keyboard(page), "ArrowLeft")
    Keyboard.up!(Page.keyboard(page), "Shift")
    Keyboard.press!(Page.keyboard(page), "Backspace")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "Hello World!"
  end

  test "should send a character with ElementHandle.press", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    textarea = Page.query_selector!(page, "textarea")
    ElementHandle.press!(textarea, "a")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "a"

    Page.evaluate!(page, "() => window.addEventListener('keydown', e => e.preventDefault(), true)")

    ElementHandle.press!(textarea, "b")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "a"
  end

  test "should send a character with insertText", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.focus!(page, "textarea")
    Keyboard.insert_text!(Page.keyboard(page), "嗨")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "嗨"
    Page.evaluate!(page, "() => window.addEventListener('keydown', e => e.preventDefault(), true)")
    Keyboard.insert_text!(Page.keyboard(page), "a")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "嗨a"
  end

  test "should not type text with Alt modifier", %{page: page} do
    Page.set_content!(page, "<input><textarea></textarea><div contenteditable></div>")

    for locator <- [Page.locator(page, "input"), Page.locator(page, "textarea"), Page.locator(page, "div")] do
      Locator.press!(locator, "Alt+KeyA")
      Locator.press!(locator, "Alt+Digit1")
      Locator.press!(locator, "Alt+Shift+KeyA")
      Keyboard.down!(Page.keyboard(page), "Alt")
      Keyboard.press!(Page.keyboard(page), "b")
      Keyboard.up!(Page.keyboard(page), "Alt")
      Locator.press!(locator, "c")
    end

    Expect.to_have_value!(Page.locator(page, "input"), "c")
    Expect.to_have_value!(Page.locator(page, "textarea"), "c")
    Expect.to_have_text!(Page.locator(page, "div"), "c")
  end

  test "insertText should only emit input event", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.focus!(page, "textarea")
    # page.on('console', m => console.log(m.text()));  -- debug output, not ported

    events =
      Page.evaluate_handle!(page, """
      () => {
        const events = [];
        document.addEventListener('keydown', e => events.push(e.type));
        document.addEventListener('keyup', e => events.push(e.type));
        document.addEventListener('keypress', e => events.push(e.type));
        document.addEventListener('input', e => events.push(e.type));
        return events;
      }
      """)

    Keyboard.insert_text!(Page.keyboard(page), "hello world")
    assert JSHandle.json_value!(events) == ["input"]
  end

  test "should emit keydown, keypress, textInput and input when typing a character", %{page: page} do
    Page.set_content!(page, "<input>")

    events =
      Page.evaluate_handle!(page, """
      () => {
        const events = [];
        for (const type of ['keydown', 'keypress', 'textInput', 'input', 'keyup'])
          document.querySelector('input').addEventListener(type, () => events.push(type));
        return events;
      }
      """)

    Page.focus!(page, "input")
    Keyboard.press!(Page.keyboard(page), "f")
    assert JSHandle.json_value!(events) == ["keydown", "keypress", "textInput", "input", "keyup"]
  end

  @tag skip:
         if(System.get_env("BROWSER", "chromium") == "firefox",
           do: "Firefox/Juggler dispatches keydown and keypress in the same task"
         )
  test "should dispatch key events in separate tasks", %{page: page} do
    Page.set_content!(page, "<input>")

    log =
      Page.evaluate_handle!(page, """
      () => {
        const log = [];
        const input = document.querySelector('input');
        for (const type of ['keydown', 'keypress'])
          input.addEventListener(type, () => { log.push(type); queueMicrotask(() => log.push('microtask-' + type)); });
        input.focus();
        return log;
      }
      """)

    Keyboard.press!(Page.keyboard(page), "a")
    # A microtask scheduled in the keydown handler must run before keypress,
    # proving each event is delivered in its own task rather than synchronously.
    assert JSHandle.json_value!(log) == ["keydown", "microtask-keydown", "keypress", "microtask-keypress"]
  end

  test "should report shiftKey", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    keyboard = Page.keyboard(page)
    code_for_key = [{"Shift", 16}, {"Alt", 18}, {"Control", 17}]

    for {modifier_key, _} <- code_for_key do
      Keyboard.down!(keyboard, modifier_key)

      assert Page.evaluate!(page, "getResult()") ==
               "Keydown: " <> modifier_key <> " " <> modifier_key <> "Left LEFT [" <> modifier_key <> "]"

      Keyboard.down!(keyboard, "!")
      # Shift+! will generate a keypress
      if modifier_key == "Shift",
        do:
          assert(
            Page.evaluate!(page, "getResult()") ==
              "Keydown: ! Digit1 STANDARD [" <>
                modifier_key <> "]\nKeypress: ! Digit1 STANDARD 33 [" <> modifier_key <> "]"
          ),
        else: assert(Page.evaluate!(page, "getResult()") == "Keydown: ! Digit1 STANDARD [" <> modifier_key <> "]")

      Keyboard.up!(keyboard, "!")
      assert Page.evaluate!(page, "getResult()") == "Keyup: ! Digit1 STANDARD [" <> modifier_key <> "]"
      Keyboard.up!(keyboard, modifier_key)

      assert Page.evaluate!(page, "getResult()") ==
               "Keyup: " <> modifier_key <> " " <> modifier_key <> "Left LEFT []"
    end
  end

  test "should report multiple modifiers", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    keyboard = Page.keyboard(page)
    Keyboard.down!(keyboard, "Control")
    assert Page.evaluate!(page, "getResult()") == "Keydown: Control ControlLeft LEFT [Control]"
    Keyboard.down!(keyboard, "Alt")
    assert Page.evaluate!(page, "getResult()") == "Keydown: Alt AltLeft LEFT [Alt Control]"
    Keyboard.down!(keyboard, ";")
    assert Page.evaluate!(page, "getResult()") == "Keydown: ; Semicolon STANDARD [Alt Control]"
    Keyboard.up!(keyboard, ";")
    assert Page.evaluate!(page, "getResult()") == "Keyup: ; Semicolon STANDARD [Alt Control]"
    Keyboard.up!(keyboard, "Control")
    assert Page.evaluate!(page, "getResult()") == "Keyup: Control ControlLeft LEFT [Alt]"
    Keyboard.up!(keyboard, "Alt")
    assert Page.evaluate!(page, "getResult()") == "Keyup: Alt AltLeft LEFT []"
  end

  test "should send proper codes while typing", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.type!(Page.keyboard(page), "!")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               ["Keydown: ! Digit1 STANDARD []", "Keypress: ! Digit1 STANDARD 33 []", "Keyup: ! Digit1 STANDARD []"],
               "\n"
             )

    Keyboard.type!(Page.keyboard(page), "^")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               ["Keydown: ^ Digit6 STANDARD []", "Keypress: ^ Digit6 STANDARD 94 []", "Keyup: ^ Digit6 STANDARD []"],
               "\n"
             )
  end

  test "should send proper codes while typing with shift", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    keyboard = Page.keyboard(page)
    Keyboard.down!(keyboard, "Shift")
    Keyboard.type!(Page.keyboard(page), "~")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               [
                 "Keydown: Shift ShiftLeft LEFT [Shift]",
                 "Keydown: ~ Backquote STANDARD [Shift]",
                 "Keypress: ~ Backquote STANDARD 126 [Shift]",
                 "Keyup: ~ Backquote STANDARD [Shift]"
               ],
               "\n"
             )

    Keyboard.up!(keyboard, "Shift")
  end

  test "should not type canceled events", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.focus!(page, "textarea")

    Page.evaluate!(page, """
    () => {
      window.addEventListener('keydown', event => {
        event.stopPropagation();
        event.stopImmediatePropagation();
        if (event.key === 'l')
          event.preventDefault();
        if (event.key === 'o')
          event.preventDefault();
      }, false);
    }
    """)

    Keyboard.type!(Page.keyboard(page), "Hello World!")
    assert Page.eval_on_selector!(page, "textarea", "textarea => textarea.value") == "He Wrd!"
  end

  test "should press plus", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.press!(Page.keyboard(page), "+")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               ["Keydown: + Equal STANDARD []", "Keypress: + Equal STANDARD 43 []", "Keyup: + Equal STANDARD []"],
               "\n"
             )
  end

  test "should press shift plus", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.press!(Page.keyboard(page), "Shift++")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               [
                 "Keydown: Shift ShiftLeft LEFT [Shift]",
                 "Keydown: + Equal STANDARD [Shift]",
                 "Keypress: + Equal STANDARD 43 [Shift]",
                 "Keyup: + Equal STANDARD [Shift]",
                 "Keyup: Shift ShiftLeft LEFT []"
               ],
               "\n"
             )
  end

  test "should support plus-separated modifiers", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.press!(Page.keyboard(page), "Shift+~")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               [
                 "Keydown: Shift ShiftLeft LEFT [Shift]",
                 "Keydown: ~ Backquote STANDARD [Shift]",
                 "Keypress: ~ Backquote STANDARD 126 [Shift]",
                 "Keyup: ~ Backquote STANDARD [Shift]",
                 "Keyup: Shift ShiftLeft LEFT []"
               ],
               "\n"
             )
  end

  test "should support multiple plus-separated modifiers", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.press!(Page.keyboard(page), "Control+Shift+~")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               [
                 "Keydown: Control ControlLeft LEFT [Control]",
                 "Keydown: Shift ShiftLeft LEFT [Control Shift]",
                 "Keydown: ~ Backquote STANDARD [Control Shift]",
                 "Keyup: ~ Backquote STANDARD [Control Shift]",
                 "Keyup: Shift ShiftLeft LEFT [Control]",
                 "Keyup: Control ControlLeft LEFT []"
               ],
               "\n"
             )
  end

  test "should shift raw codes", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.press!(Page.keyboard(page), "Shift+Digit3")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               [
                 "Keydown: Shift ShiftLeft LEFT [Shift]",
                 "Keydown: # Digit3 STANDARD [Shift]",
                 "Keypress: # Digit3 STANDARD 35 [Shift]",
                 "Keyup: # Digit3 STANDARD [Shift]",
                 "Keyup: Shift ShiftLeft LEFT []"
               ],
               "\n"
             )
  end

  test "should specify repeat property", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.focus!(page, "textarea")
    last_event = capture_last_keydown(page)
    keyboard = Page.keyboard(page)
    Keyboard.down!(keyboard, "a")
    assert JSHandle.evaluate!(last_event, "e => e.repeat") == false
    Keyboard.press!(keyboard, "a")
    assert JSHandle.evaluate!(last_event, "e => e.repeat") == true

    Keyboard.down!(keyboard, "b")
    assert JSHandle.evaluate!(last_event, "e => e.repeat") == false
    Keyboard.down!(keyboard, "b")
    assert JSHandle.evaluate!(last_event, "e => e.repeat") == true

    Keyboard.up!(keyboard, "a")
    Keyboard.down!(keyboard, "a")
    assert JSHandle.evaluate!(last_event, "e => e.repeat") == false
  end

  test "should type all kinds of characters", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.focus!(page, "textarea")
    text = "This text goes onto two lines.\nThis character is 嗨."
    Keyboard.type!(Page.keyboard(page), text)
    assert Page.eval_on_selector!(page, "textarea", "t => t.value") == text
  end

  test "should specify location", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    last_event = capture_last_keydown(page)
    textarea = Page.query_selector!(page, "textarea")

    ElementHandle.press!(textarea, "Digit5")
    assert JSHandle.evaluate!(last_event, "e => e.location") == 0
    assert JSHandle.evaluate!(last_event, "e => e.key") == "5"
    assert JSHandle.evaluate!(last_event, "e => e.code") == "Digit5"

    ElementHandle.press!(textarea, "ControlLeft")
    assert JSHandle.evaluate!(last_event, "e => e.location") == 1
    assert JSHandle.evaluate!(last_event, "e => e.key") == "Control"
    assert JSHandle.evaluate!(last_event, "e => e.code") == "ControlLeft"

    ElementHandle.press!(textarea, "ControlRight")
    assert JSHandle.evaluate!(last_event, "e => e.location") == 2
    assert JSHandle.evaluate!(last_event, "e => e.key") == "Control"
    assert JSHandle.evaluate!(last_event, "e => e.code") == "ControlRight"

    ElementHandle.press!(textarea, "NumpadSubtract")
    assert JSHandle.evaluate!(last_event, "e => e.location") == 3
    assert JSHandle.evaluate!(last_event, "e => e.key") == "-"
    assert JSHandle.evaluate!(last_event, "e => e.code") == "NumpadSubtract"
  end

  test "should specify numpad location on keyup", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.press!(Page.keyboard(page), "NumpadSubtract")

    assert Page.evaluate!(page, "getResult()") ==
             Enum.join(
               [
                 "Keydown: - NumpadSubtract NUMPAD []",
                 "Keypress: - NumpadSubtract NUMPAD 45 []",
                 "Keyup: - NumpadSubtract NUMPAD []"
               ],
               "\n"
             )
  end

  test "should press NumpadDecimal as Delete", %{page: page} do
    Page.set_content!(page, "<textarea></textarea>")
    last_event = capture_last_keydown(page)
    textarea = Page.locator(page, "textarea")

    Locator.press!(textarea, "NumpadDecimal")
    assert JSHandle.evaluate!(last_event, "e => e.key") == "Delete"
    assert JSHandle.evaluate!(last_event, "e => e.code") == "NumpadDecimal"
    assert JSHandle.evaluate!(last_event, "e => e.location") == 3
    Expect.to_have_value!(textarea, "")
  end

  test "should type numpad digits with Shift", %{page: page} do
    Page.set_content!(page, "<textarea></textarea>")
    textarea = Page.locator(page, "textarea")
    Locator.press!(textarea, "Shift+Numpad1")
    Locator.press!(textarea, "Shift+NumpadDecimal")
    Locator.press!(textarea, "Shift+Numpad9")
    Expect.to_have_value!(textarea, "1.9")
  end

  test "should press Enter", %{page: page} do
    Page.set_content!(page, "<textarea></textarea>")
    Page.focus!(page, "textarea")
    last_event_handle = capture_last_keydown(page)

    test_enter_key = fn key, expected_key, expected_code ->
      Keyboard.press!(Page.keyboard(page), key)
      last_event = JSHandle.json_value!(last_event_handle)
      # had the wrong key
      assert last_event["key"] == expected_key
      # had the wrong code
      assert last_event["code"] == expected_code
      value = Page.eval_on_selector!(page, "textarea", "t => t.value")
      # failed to create a newline
      assert value == "\n"
      Page.eval_on_selector!(page, "textarea", "t => t.value = ''")
    end

    test_enter_key.("Enter", "Enter", "Enter")
    test_enter_key.("NumpadEnter", "Enter", "NumpadEnter")
    test_enter_key.("\n", "Enter", "Enter")
    test_enter_key.("\r", "Enter", "Enter")
  end

  test "should press audio and media control keys", %{page: page, browser_name: browser_name} do
    Page.set_content!(page, "<input autofocus>")
    Page.focus!(page, "input")
    last_event = capture_last_keydown(page)

    media_keys = [
      %{key: "AudioVolumeMute", code: if(browser_name == "firefox", do: "VolumeMute", else: "AudioVolumeMute")},
      %{key: "AudioVolumeDown", code: if(browser_name == "firefox", do: "VolumeDown", else: "AudioVolumeDown")},
      %{key: "AudioVolumeUp", code: if(browser_name == "firefox", do: "VolumeUp", else: "AudioVolumeUp")},
      %{key: "MediaTrackNext", code: "MediaTrackNext"},
      %{key: "MediaTrackPrevious", code: "MediaTrackPrevious"},
      %{key: "MediaPlayPause", code: "MediaPlayPause"}
    ]

    for media_key <- media_keys do
      Keyboard.press!(Page.keyboard(page), media_key.key)
      assert JSHandle.evaluate!(last_event, "e => e.key") == media_key.key
      assert JSHandle.evaluate!(last_event, "e => e.code") == media_key.code
      assert JSHandle.evaluate!(last_event, "e => e.location") == 0
    end
  end

  test "should throw on unknown keys", %{page: page} do
    {:error, error} = Keyboard.press(Page.keyboard(page), "NotARealKey")
    assert Exception.message(error) =~ ~s(Unknown key: "NotARealKey")

    {:error, error} = Keyboard.press(Page.keyboard(page), "ё")
    assert error && Exception.message(error) =~ ~s(Unknown key: "ё")

    {:error, error} = Keyboard.press(Page.keyboard(page), "😊")
    assert error && Exception.message(error) =~ ~s(Unknown key: "😊")
  end

  test "should type emoji", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.type!(page, "textarea", "👹 Tokyo street Japan 🇯🇵")
    assert Page.eval_on_selector!(page, "textarea", "textarea => textarea.value") == "👹 Tokyo street Japan 🇯🇵"
  end

  test "should type emoji into an iframe", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Utils.attach_frame(page, "emoji-test", server.prefix <> "/input/textarea.html")
    frame = Enum.at(Page.frames(page), 1)
    textarea = Frame.query_selector!(frame, "textarea")
    ElementHandle.type!(textarea, "👹 Tokyo street Japan 🇯🇵")
    assert Frame.eval_on_selector!(frame, "textarea", "textarea => textarea.value") == "👹 Tokyo street Japan 🇯🇵"
  end

  test "should handle selectAll", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    textarea = Page.query_selector!(page, "textarea")
    ElementHandle.type!(textarea, "some text")
    Keyboard.down!(Page.keyboard(page), "ControlOrMeta")
    Keyboard.press!(Page.keyboard(page), "a")
    Keyboard.up!(Page.keyboard(page), "ControlOrMeta")
    Keyboard.press!(Page.keyboard(page), "Backspace")
    assert Page.eval_on_selector!(page, "textarea", "textarea => textarea.value") == ""
  end

  test "pressing Meta should not result in any text insertion on any platform", %{page: page} do
    Page.set_content!(page, ~s(<input type="text" value="hello world">))
    input = Page.locator(page, "input")
    Expect.to_have_value!(input, "hello world")
    Locator.focus!(input)
    Keyboard.press!(Page.keyboard(page), "Meta")
    Expect.to_have_value!(input, "hello world")
  end

  test "should be able to prevent selectAll", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    textarea = Page.query_selector!(page, "textarea")
    ElementHandle.type!(textarea, "some text")

    Page.eval_on_selector!(page, "textarea", """
    textarea => {
      textarea.addEventListener('keydown', event => {
        if (event.key === 'a' && (event.metaKey || event.ctrlKey))
          event.preventDefault();
      }, false);
    }
    """)

    Keyboard.down!(Page.keyboard(page), "ControlOrMeta")
    Keyboard.press!(Page.keyboard(page), "a")
    Keyboard.up!(Page.keyboard(page), "ControlOrMeta")
    Keyboard.press!(Page.keyboard(page), "Backspace")
    assert Page.eval_on_selector!(page, "textarea", "textarea => textarea.value") == "some tex"
  end

  @tag skip:
         (cond do
            !@is_mac ->
              "it.skip(platform !== 'darwin')"

            System.get_env("BROWSER", "chromium") == "firefox" ->
              "fixme: https://github.com/microsoft/playwright/issues/5721"

            true ->
              nil
          end)
  test "should support MacOS shortcuts", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    textarea = Page.query_selector!(page, "textarea")
    ElementHandle.type!(textarea, "some text")
    # select one word backwards
    Keyboard.press!(Page.keyboard(page), "Shift+Control+Alt+KeyB")
    Keyboard.press!(Page.keyboard(page), "Backspace")
    assert Page.eval_on_selector!(page, "textarea", "textarea => textarea.value") == "some "
  end

  test "should press the meta key", %{page: page} do
    last_event = capture_last_keydown(page)
    Keyboard.press!(Page.keyboard(page), "Meta")
    %{"key" => key, "code" => code, "metaKey" => meta_key} = JSHandle.json_value!(last_event)
    assert key == "Meta"
    assert code == "MetaLeft"
    assert meta_key == true
  end

  test "should work with keyboard events with empty.html", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")
    last_event = capture_last_keydown(page)
    Keyboard.press!(Page.keyboard(page), "a")
    assert JSHandle.evaluate!(last_event, "l => l.key") == "a"
  end

  test "should work after a cross origin navigation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/empty.html")
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    last_event = capture_last_keydown(page)
    Keyboard.press!(Page.keyboard(page), "a")
    assert JSHandle.evaluate!(last_event, "l => l.key") == "a"
  end

  @tag skip:
         if(System.get_env("BROWSER", "chromium") != "webkit",
           do: "event.keyIdentifier has been removed from all browsers except WebKit"
         )
  test "should expose keyIdentifier in webkit", %{page: page} do
    last_event = capture_last_keydown(page)

    key_map = [
      {"ArrowUp", "Up"},
      {"ArrowDown", "Down"},
      {"ArrowLeft", "Left"},
      {"ArrowRight", "Right"},
      {"Backspace", "U+0008"},
      {"Tab", "U+0009"},
      {"Delete", "U+007F"},
      {"a", "U+0041"},
      {"b", "U+0042"},
      {"F12", "F12"}
    ]

    for {key, key_identifier} <- key_map do
      Keyboard.press!(Page.keyboard(page), key)
      assert JSHandle.evaluate!(last_event, "e => e.keyIdentifier") == key_identifier
    end
  end

  test "should scroll with PageDown", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    # A click is required for WebKit to send the event into the body.
    Page.click!(page, "body")
    Keyboard.press!(Page.keyboard(page), "PageDown")
    # We can't wait for the scroll to finish, so just wait for it to start.
    Page.wait_for_function!(page, "() => scrollY > 0")
  end

  test "should move around the selection in a contenteditable", %{page: page} do
    Page.set_content!(page, "<div contenteditable></div>")
    Page.focus!(page, "div")
    modifier = if @is_mac, do: "Alt", else: "Control"
    Keyboard.type!(Page.keyboard(page), "Hello World")
    Keyboard.down!(Page.keyboard(page), modifier)
    Keyboard.down!(Page.keyboard(page), "Shift")
    Keyboard.press!(Page.keyboard(page), "ArrowLeft")
    Keyboard.up!(Page.keyboard(page), "Shift")
    Keyboard.up!(Page.keyboard(page), modifier)
    assert Page.evaluate!(page, "() => window.getSelection().toString()") == "World"
  end

  @tag skip: if(!@is_mac, do: "it.skip(!isMac)")
  test "should move to the start of the document", %{page: page} do
    Page.set_content!(page, "<div contenteditable></div>")
    Page.focus!(page, "div")
    Keyboard.type!(Page.keyboard(page), "1\n2\n3\n")
    Keyboard.press!(Page.keyboard(page), "Shift+Meta+ArrowUp")
    assert Page.evaluate!(page, "() => window.getSelection().toString()") == "1\n2\n3\n"
  end

  test "should dispatch a click event on a button when Space gets pressed", %{page: page} do
    Page.set_content!(page, ~s(<button type="button">a11y</button>))

    actual =
      Page.evaluate_handle!(page, """
      () => {
        const actual = { clicked: false };
        document.querySelector('button').addEventListener('click', () => (actual.clicked = true));
        return actual;
      }
      """)

    Page.focus!(page, "button")
    Keyboard.press!(Page.keyboard(page), "Space")
    assert JSHandle.json_value!(actual)["clicked"] == true
  end

  test "should dispatch a click event on a button when Enter gets pressed", %{page: page} do
    Page.set_content!(page, ~s(<button type="button">a11y</button>))

    actual =
      Page.evaluate_handle!(page, """
      () => {
        const actual = { clicked: false };
        document.querySelector('button').addEventListener('click', () => (actual.clicked = true));
        return actual;
      }
      """)

    Page.focus!(page, "button")
    Keyboard.press!(Page.keyboard(page), "Enter")
    assert JSHandle.json_value!(actual)["clicked"] == true
  end

  test "should support simple copy-pasting", %{page: page} do
    Page.set_content!(page, "<div contenteditable>123</div>")
    Page.focus!(page, "div")
    Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyA")
    Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyC")
    Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyV")
    Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyV")
    assert Page.evaluate!(page, "() => document.querySelector('div').textContent") == "123123"
  end

  test "should support simple cut-pasting", %{page: page} do
    Page.set_content!(page, "<div contenteditable>123</div>")
    Page.focus!(page, "div")
    Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyA")
    Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyX")
    Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyV")
    Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyV")
    assert Page.evaluate!(page, "() => document.querySelector('div').textContent") == "123123"
  end

  test "should support undo-redo", %{page: page, browser_name: browser_name} do
    # it.fixme(browserName === 'webkit' && isLinux || channel === 'webkit-wsl', 'https://github.com/microsoft/playwright/issues/12000');
    if !(browser_name == "webkit" and match?({:unix, :linux}, :os.type())) do
      Page.set_content!(page, "<div contenteditable></div>")
      div = Page.locator(page, "div")
      Expect.to_have_text!(div, "")
      Locator.type!(div, "123")
      Expect.to_have_text!(div, "123")
      Keyboard.press!(Page.keyboard(page), "ControlOrMeta+KeyZ")
      Expect.to_have_text!(div, "")
      Keyboard.press!(Page.keyboard(page), "Shift+ControlOrMeta+KeyZ")
      Expect.to_have_text!(div, "123")
    end
  end

  test "should type repeatedly in contenteditable in shadow dom", %{page: page} do
    Page.set_content!(page, """
      <html>
        <body>
          <shadow-element></shadow-element>
          <script>
            customElements.define('shadow-element', class extends HTMLElement {
              constructor() {
                super();
                this.attachShadow({ mode: 'open' });
              }

              connectedCallback() {
                this.shadowRoot.innerHTML = `
                  <style>
                    .editor { padding: 1rem; margin: 1rem; border: 1px solid #ccc; }
                  </style>
                  <div class=editor contenteditable id=foo></div>
                  <hr>
                  <section>
                    <div class=editor contenteditable id=bar></div>
                  </section>
                `;
              }
            });
          </script>
        </body>
      </html>
    """)

    editor = Locator.first(Page.locator(page, "shadow-element > .editor"))
    Locator.type!(editor, "This is the first box.")

    section_editor = Page.locator(page, "section .editor")
    Locator.type!(section_editor, "This is the second box.")

    assert Locator.text_content!(editor) == "This is the first box."
    assert Locator.text_content!(section_editor) == "This is the second box."
  end

  test "should type repeatedly in contenteditable in shadow dom with nested elements", %{page: page} do
    Page.set_content!(page, """
      <html>
        <body>
          <shadow-element></shadow-element>
          <script>
            customElements.define('shadow-element', class extends HTMLElement {
              constructor() {
                super();
                this.attachShadow({ mode: 'open' });
              }

              connectedCallback() {
                this.shadowRoot.innerHTML = `
                  <style>
                    .editor { padding: 1rem; margin: 1rem; border: 1px solid #ccc; }
                  </style>
                  <div class=editor contenteditable id=foo><p>hello</p></div>
                  <hr>
                  <section>
                    <div class=editor contenteditable id=bar><p>world</p></div>
                  </section>
                `;
              }
            });
          </script>
        </body>
      </html>
    """)

    editor = Locator.first(Page.locator(page, "shadow-element > .editor"))
    Locator.type!(editor, "This is the first box: ")

    section_editor = Page.locator(page, "section .editor")
    Locator.type!(section_editor, "This is the second box: ")

    assert Locator.text_content!(editor) == "This is the first box: hello"
    assert Locator.text_content!(section_editor) == "This is the second box: world"
  end

  test "should type repeatedly in input in shadow dom", %{page: page} do
    Page.set_content!(page, """
      <html>
        <body>
          <shadow-element></shadow-element>
          <script>
            customElements.define('shadow-element', class extends HTMLElement {
              constructor() {
                super();
                this.attachShadow({ mode: 'open' });
              }

              connectedCallback() {
                this.shadowRoot.innerHTML = `
                  <style>
                    .editor { padding: 1rem; margin: 1rem; border: 1px solid #ccc; }
                  </style>
                  <input class=editor id=foo>
                  <hr>
                  <section>
                    <input class=editor id=bar>
                  </section>
                `;
              }
            });
          </script>
        </body>
      </html>
    """)

    editor = Locator.first(Page.locator(page, "shadow-element > .editor"))
    Locator.type!(editor, "This is the first box.")

    section_editor = Page.locator(page, "section .editor")
    Locator.type!(section_editor, "This is the second box.")

    assert Locator.input_value!(editor) == "This is the first box."
    assert Locator.input_value!(section_editor) == "This is the second box."
  end

  test "type to non-focusable element should maintain old focus", %{page: page} do
    Page.set_content!(page, """
      <div id="focusable" tabindex="0">focusable div</div>
      <div id="non-focusable-and-non-editable">non-editable, non-focusable</div>
    """)

    Locator.focus!(Page.locator(page, "#focusable"))
    assert Page.evaluate!(page, "() => document.activeElement?.id") == "focusable"
    Locator.type!(Page.locator(page, "#non-focusable-and-non-editable"), "foo")
    assert Page.evaluate!(page, "() => document.activeElement?.id") == "focusable"
  end

  defp capture_last_keydown(page) do
    Page.evaluate_handle!(page, """
    () => {
      const lastEvent = {
        repeat: false,
        location: -1,
        code: '',
        key: '',
        metaKey: false,
        keyIdentifier: 'unsupported'
      };
      document.addEventListener('keydown', e => {
        lastEvent.repeat = e.repeat;
        lastEvent.location = e.location;
        lastEvent.key = e.key;
        lastEvent.code = e.code;
        lastEvent.metaKey = e.metaKey;
        lastEvent.keyIdentifier = 'keyIdentifier' in e && typeof e['keyIdentifier'] === 'string' && e['keyIdentifier'];
      }, true);
      return lastEvent;
    }
    """)
  end

  @tag skip:
         if(System.get_env("BROWSER", "chromium") == "chromium" and match?({:win32, _}, :os.type()),
           do: "context menu support is best-effort for Linux and MacOS"
         )
  test "should dispatch insertText after context menu was opened", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")

    Page.evaluate!(page, """
    () => {
      window['contextMenuPromise'] = new Promise(x => {
        window.addEventListener('contextmenu', x, false);
      });
    }
    """)

    box = Locator.bounding_box!(Page.locator(page, "textarea"))
    cx = box.x + box.width / 2
    cy = box.y + box.height / 2
    Mouse.click!(Page.mouse(page), cx, cy, button: :right)
    Page.evaluate!(page, "() => window['contextMenuPromise']")

    Keyboard.insert_text!(Page.keyboard(page), "嗨")
    Utils.poll(fn -> Locator.input_value!(Page.locator(page, "textarea")) end, &assert(&1 == "嗨"))
  end

  @tag skip:
         if(System.get_env("BROWSER", "chromium") == "chromium" and match?({:win32, _}, :os.type()),
           do: "context menu support is best-effort for Linux and MacOS"
         )
  test "should type after context menu was opened", %{page: page} do
    Page.evaluate!(page, """
    () => {
      window['keys'] = [];
      window.addEventListener('keydown', event => window['keys'].push(event.key));
      window['contextMenuPromise'] = new Promise(x => {
        window.addEventListener('contextmenu', x, false);
      });
    }
    """)

    Mouse.move!(Page.mouse(page), 100, 100)
    Mouse.down!(Page.mouse(page), button: :right)
    Page.evaluate!(page, "() => window['contextMenuPromise']")

    Keyboard.down!(Page.keyboard(page), "ArrowDown")

    Utils.poll(fn -> Page.evaluate!(page, "window.keys") end, &assert(&1 == ["ArrowDown"]))
  end

  test "should have correct Keydown/Keyup order when pressing Escape key", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.press!(Page.keyboard(page), "Escape")

    assert Page.evaluate!(page, "getResult()") ==
             String.trim("""
             Keydown: Escape Escape STANDARD []
             Keyup: Escape Escape STANDARD []
             """)
  end

  test "should close dialog on Escape key press in contenteditable", %{page: page} do
    # it.skip(isFrozenWebkit);  -- we run a current browser
    Page.set_content!(page, """
      <dialog>
        <div contenteditable>Edit Me</div>
      </dialog>
    """)

    dialog = Page.locator(page, "dialog")
    widget = Locator.locator(dialog, "[contenteditable]")
    Locator.evaluate!(dialog, "node => node.showModal()")
    Expect.to_have_js_property!(dialog, "open", true)
    Expect.to_be_visible!(widget)

    Locator.press!(widget, "Escape")
    Expect.to_have_js_property!(dialog, "open", false)
    Expect.not_to_be_visible!(widget)
  end
end
