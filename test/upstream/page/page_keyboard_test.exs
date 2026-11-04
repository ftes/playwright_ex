defmodule PlaywrightEx.Page.PageKeyboardTest do
  @upstream "tests/page/page-keyboard.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

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

  @tag skip: "not ported: ElementHandle"
  test "should send a character with ElementHandle.press"

  test "should send a character with insertText", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.focus!(page, "textarea")
    Keyboard.insert_text!(Page.keyboard(page), "嗨")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "嗨"
    Page.evaluate!(page, "() => window.addEventListener('keydown', e => e.preventDefault(), true)")
    Keyboard.insert_text!(Page.keyboard(page), "a")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "嗨a"
  end

  @tag skip: "not ported: expect"
  test "should not type text with Alt modifier"

  @tag skip: "not ported: evaluateHandle"
  test "insertText should only emit input event"

  @tag skip: "not ported: evaluateHandle"
  test "should emit keydown, keypress, textInput and input when typing a character"

  @tag skip: "not ported: evaluateHandle"
  test "should dispatch key events in separate tasks"

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

  @tag skip: "not ported: evaluateHandle"
  test "should specify repeat property"

  test "should type all kinds of characters", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.focus!(page, "textarea")
    text = "This text goes onto two lines.\nThis character is 嗨."
    Keyboard.type!(Page.keyboard(page), text)
    assert Page.eval_on_selector!(page, "textarea", "t => t.value") == text
  end

  @tag skip: "not ported: evaluateHandle"
  test "should specify location"

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

  @tag skip: "not ported: evaluateHandle"
  test "should press NumpadDecimal as Delete"

  @tag skip: "not ported: expect"
  test "should type numpad digits with Shift"

  @tag skip: "not ported: evaluateHandle"
  test "should press Enter"

  @tag skip: "not ported: evaluateHandle"
  test "should press audio and media control keys"

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

  @tag skip: "not ported: evaluateHandle (attachFrame)"
  test "should type emoji into an iframe"

  @tag skip: "not ported: ElementHandle"
  test "should handle selectAll"

  @tag skip: "not ported: expect"
  test "pressing Meta should not result in any text insertion on any platform"

  @tag skip: "not ported: ElementHandle"
  test "should be able to prevent selectAll"

  @tag skip: "not ported: ElementHandle"
  test "should support MacOS shortcuts"

  @tag skip: "not ported: evaluateHandle"
  test "should press the meta key"

  @tag skip: "not ported: evaluateHandle"
  test "should work with keyboard events with empty.html"

  @tag skip: "not ported: evaluateHandle"
  test "should work after a cross origin navigation"

  @tag skip: "not ported: evaluateHandle"
  test "should expose keyIdentifier in webkit"

  @tag skip: "not ported: waitForFunction"
  test "should scroll with PageDown"

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

  @tag skip: "not ported: evaluateHandle"
  test "should dispatch a click event on a button when Space gets pressed"

  @tag skip: "not ported: evaluateHandle"
  test "should dispatch a click event on a button when Enter gets pressed"

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

  @tag skip: "not ported: expect"
  test "should support undo-redo"

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

  @tag skip: "not ported: Locator.boundingBox (ElementHandle), expect.poll"
  test "should dispatch insertText after context menu was opened"

  @tag skip: "not ported: expect.poll"
  test "should type after context menu was opened"

  test "should have correct Keydown/Keyup order when pressing Escape key", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/keyboard.html")
    Keyboard.press!(Page.keyboard(page), "Escape")

    assert Page.evaluate!(page, "getResult()") ==
             String.trim("""
             Keydown: Escape Escape STANDARD []
             Keyup: Escape Escape STANDARD []
             """)
  end

  @tag skip: "not ported: Locator.evaluate (ElementHandle), expect"
  test "should close dialog on Escape key press in contenteditable"
end
