defmodule PlaywrightEx.Page.ExpectToHaveTextTest do
  @upstream "tests/page/expect-to-have-text.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  describe "toHaveText with regex" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div id=node>Text   content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_have_text!(locator, ~r/Text/)

      # Should not normalize whitespace.
      Expect.to_have_text!(locator, ~r/Text   content/)
      # Should respect ignoreCase.
      Expect.to_have_text!(locator, ~r/text   content/, ignore_case: true)
      # Should override regex flag with ignoreCase.
      Expect.not_to_have_text!(locator, ~r/text   content/i, ignore_case: false)
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      {:error, error} = Expect.to_have_text(locator, ~r/Text 2/, timeout: 1000)

      assert error.message =~ """
             expect(locator).toHaveText(expected) failed

             Locator: locator('#node')
             Expected pattern: /Text 2/
             Received string:  "Text content"
             Timeout: 1000ms

             Call log:
             """
    end
  end

  describe "toContainText with regex" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div id=node>Text   content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_contain_text!(locator, ~r/ex/)

      # Should not normalize whitespace.
      Expect.to_contain_text!(locator, ~r/ext   cont/)
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      {:error, error} = Expect.to_contain_text(locator, ~r/ex2/, timeout: 1000)
      assert error.message =~ "Expected pattern: /ex2/"
      assert error.message =~ "Received string:  \"Text content\""
    end
  end

  describe "toContainText with string" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div id=node>Text   content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_contain_text!(locator, "content")
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      {:error, error} = Expect.to_contain_text(locator, "foo", timeout: 1000)

      assert error.message =~ """
             expect(locator).toContainText(expected) failed

             Locator: locator('#node')
             Expected substring: "foo"
             Received string:    "Text content"
             Timeout: 1000ms

             Call log:
             """
    end
  end

  describe "toHaveText with text" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div id=node><span></span>Text \ncontent&nbsp;    </div>")
      locator = Page.locator(page, "#node")
      # Should normalize whitespace.
      Expect.to_have_text!(locator, "Text                        content")
      # Should normalize zero width whitespace.
      Expect.to_have_text!(locator, "T​e​x​t content")
      # Should support ignoreCase.
      Expect.to_have_text!(locator, "text CONTENT", ignore_case: true)
      # Should support falsy ignoreCase.
      Expect.not_to_have_text!(locator, "TEXT", ignore_case: false)
      # Should normalize soft hyphens.
      Expect.to_have_text!(locator, "T­e­xt content")
    end

    test "pass contain", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_contain_text!(locator, "Text")
      # Should normalize whitespace.
      Expect.to_contain_text!(locator, "   ext        cont\n  ")
      # Should support ignoreCase.
      Expect.to_contain_text!(locator, "EXT", ignore_case: true)
      # Should support falsy ignoreCase.
      Expect.not_to_contain_text!(locator, "TEXT", ignore_case: false)
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      {:error, error} = Expect.to_have_text(locator, "Text", timeout: 1000)
      assert error.message =~ "Expected: \"Text\""
      assert error.message =~ "Received: \"Text content\""
    end

    test "pass eventually", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")

      tasks = [
        Task.async(fn -> Expect.to_have_text!(locator, ~r/Text 2/) end),
        Task.async(fn ->
          Page.wait_for_timeout!(page, 1000)
          Locator.evaluate!(locator, "element => element.textContent = 'Text 2 content'")
        end)
      ]

      Task.await_many(tasks)
    end

    test "with userInnerText", %{page: page} do
      Page.set_content!(page, "<div id=node>Text <span hidden>garbage</span> content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_have_text!(locator, "Text content", use_inner_text: true)
    end

    test "in shadow dom", %{page: page} do
      Page.set_content!(page, """
        <div></div>
        <script>
          const div = document.querySelector('div');
          const span = document.createElement('span');
          span.textContent = 'some text';
          div.attachShadow({ mode: 'open' }).appendChild(span);
        </script>
      """)

      Expect.to_have_text!(Page.locator(page, "span"), "some text")
      Expect.to_contain_text!(Page.locator(page, "span"), "text")
      Expect.to_have_text!(Page.locator(page, "div"), "some text")
      Expect.to_contain_text!(Page.locator(page, "div"), "text")
      Expect.to_have_text!(Page.locator(page, "span"), "some text", use_inner_text: true)
      Expect.to_contain_text!(Page.locator(page, "span"), "text", use_inner_text: true)
      # Playwright intentionally does not perform innerText piercing on shadow dom.
      Expect.not_to_have_text!(Page.locator(page, "div"), "some text", use_inner_text: true)
      Expect.not_to_contain_text!(Page.locator(page, "div"), "text", use_inner_text: true)
    end

    test "fail with impossible timeout", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      {:error, error} = Expect.to_have_text(Page.locator(page, "#node"), "Text", timeout: 1)
      assert error.message =~ "Expected: \"Text\""
      assert error.message =~ "Received: \"Text content\""
    end

    @tag skip: if(System.get_env("PW_CLOCK") == "frozen", do: "upstream skip: The element is attached after 1 second.")
    test "do not show \"element(s) not found\" when the real failure is a string mismatch", %{page: page} do
      Page.set_content!(page, """
        <div>Initial</div>
        <script>
          const field = document.querySelector('div');
          setTimeout(() => {
            field.id = 'field';
            field.textContent = 'Final value';
          }, 1000);
        </script>
      """)

      cell = Page.locator(page, "#field")
      {:error, error} = Expect.to_have_text(cell, "Something", timeout: 3000)
      assert error.message =~ "Expected: \"Something\""
      assert error.message =~ "Received: \"Final value\""
    end
  end

  describe "not.toHaveText" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      Expect.not_to_have_text!(locator, "Text2")
      # Should be case-sensitive by default.
      Expect.not_to_have_text!(locator, "TEXT")
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      {:error, error} = Expect.not_to_have_text(locator, "Text content", timeout: 1000)
      assert error.message =~ "Expected: not \"Text content\""
      assert error.message =~ "Received: \"Text content"
    end

    test "should work when selector does not match", %{page: page} do
      Page.set_content!(page, "<div>hello</div>")
      {:error, error} = Expect.not_to_have_text(Page.locator(page, "span"), "hello", timeout: 1000)
      assert error.message =~ "Expected: not \"hello\""
      assert error.message =~ "Error: element(s) not found"
      assert error.message =~ "waiting for locator('span')"
    end
  end

  describe "toHaveText with array" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div>Text    \n1</div><div>Text   2a</div>")
      locator = Page.locator(page, "div")
      # Should only normalize whitespace in the first item.
      Expect.to_have_text!(locator, ["Text  1", ~r/Text   \d+a/])
      # Should support ignoreCase.
      Expect.to_have_text!(locator, ["tEXT 1", "TExt 2A"], ignore_case: true)
    end

    test "pass lazy", %{page: page} do
      Page.set_content!(page, "<div id=div></div>")
      locator = Page.locator(page, "p")

      Task.start(fn ->
        Process.sleep(500)

        Page.evaluate(page, """
        () => {
          document.querySelector('div').innerHTML = '<p>Text 1</p><p>Text 2</p>';
        }
        """)
      end)

      Expect.to_have_text!(locator, ["Text 1", "Text 2"])
    end

    test "pass empty", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "p")
      Expect.to_have_text!(locator, [])
    end

    test "pass not empty", %{page: page} do
      Page.set_content!(page, "<div><p>Test</p></div>")
      locator = Page.locator(page, "p")
      Expect.not_to_have_text!(locator, [])
    end

    test "pass on empty", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "p")
      Expect.not_to_have_text!(locator, ["Test"])
    end

    test "fail on not+empty", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "p")
      {:error, error} = Expect.not_to_have_text(locator, [], timeout: 1000)
      assert error.message =~ "expect(locator).not.toHaveText(expected)"
      assert error.message =~ "Timeout:  1000ms"
      assert error.message =~ "- Expect \"not toHaveText\" locator('p') with timeout 1000ms"
    end

    test "pass eventually empty", %{page: page} do
      Page.set_content!(page, "<div id=div><p>Text</p></div>")
      locator = Page.locator(page, "p")

      Task.start(fn ->
        Process.sleep(500)
        Page.evaluate(page, "() => document.querySelector('div').innerHTML = ''")
      end)

      Expect.not_to_have_text!(locator, [])
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<div>Text 1</div><div>Text 3</div>")
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_have_text(locator, ["Text 1", ~r/Text \d/, "Extra"], timeout: 1000)

      assert error.message =~ """
             expect(locator).toHaveText(expected) failed

             Locator: locator('div')
             Timeout: 1000ms
             - Expected  - 1
             + Received  + 0

               Array [
                 "Text 1",
                 "Text 3",
             -   "Extra",
               ]

             Call log:
               - Expect "toHaveText" locator('div') with timeout 1000ms
               - waiting for locator('div')
             """

      assert error.message =~ "locator resolved to 2 elements"
    end

    test "fail on repeating array matchers", %{page: page} do
      Page.set_content!(page, "<div>KekFoo</div>")
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_contain_text(locator, ["KekFoo", "KekFoo", "KekFoo"], timeout: 1000)
      assert error.message =~ "locator resolved to 1 element"
    end
  end

  describe "toContainText with array" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div>Text \n1</div><div>Text2</div><div>Text3</div>")
      locator = Page.locator(page, "div")
      Expect.to_contain_text!(locator, ["ext     1", ~r/ext3/])
      # Should support ignoreCase.
      Expect.to_contain_text!(locator, ["EXT 1", "eXt3"], ignore_case: true)
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<div>Text 1</div><div>Text 3</div>")
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_contain_text(locator, ["Text 2"], timeout: 1000)
      assert error.message =~ "-   \"Text 2\""
    end
  end
end
