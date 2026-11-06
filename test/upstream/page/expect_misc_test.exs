defmodule PlaywrightEx.Page.ExpectMiscTest do
  @upstream "tests/page/expect-misc.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime

  @moduletag :page

  # "Locator:" lines are Elixir syntax, call logs JS (architecture: Driver language and rendering).

  defp date(ms), do: DateTime.from_unix!(ms, :millisecond)

  describe "toHaveCount" do
    test "toHaveCount pass", %{page: page} do
      Page.set_content!(page, "<select><option>One</option></select>")
      locator = Page.locator(page, "option")
      promise = Runtime.Promise.async(fn -> Expect.to_have_count!(locator, 2) end, shared: true)
      Page.wait_for_timeout!(page, 1000)
      refute Runtime.Promise.settled?(promise)
      Page.set_content!(page, "<select><option>One</option><option>Two</option></select>")
      assert Runtime.Promise.await(promise) == :ok
    end

    test "pass zero", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "span")
      Expect.to_have_count!(locator, 0)
      Expect.not_to_have_count!(locator, 1)
    end

    test "eventually pass zero", %{page: page} do
      Page.set_content!(page, "<div><span>hello</span></div>")
      locator = Page.locator(page, "span")

      Task.start(fn ->
        Process.sleep(200)
        Page.evaluate(page, "() => document.querySelector('div').textContent = ''")
      end)

      Expect.to_have_count!(locator, 0)
      Expect.not_to_have_count!(locator, 1)
    end

    test "eventually pass non-zero", %{page: page} do
      Page.set_content!(page, "<ul></ul>")

      Task.start(fn ->
        Process.sleep(500)
        Page.set_content!(page, "<ul><li>one</li><li>two</li></ul>")
      end)

      locator = Page.locator(page, "li")
      Expect.to_have_count!(locator, 2)
    end

    test "eventually pass not non-zero", %{page: page} do
      Page.set_content!(page, "<ul><li>one</li><li>two</li></ul>")

      Task.start(fn ->
        Process.sleep(500)
        Page.set_content!(page, "<ul></ul>")
      end)

      locator = Page.locator(page, "li")
      Expect.not_to_have_count!(locator, 2)
    end

    test "fail zero", %{page: page} do
      Page.set_content!(page, "<div><span></span></div>")
      locator = Page.locator(page, "span")
      {:error, error} = Expect.to_have_count(locator, 0, timeout: 1000)

      assert error.message =~ """
             expect(locator).toHaveCount(expected) failed

             Locator:  Page.locator(page, "span")
             Expected: 0
             Received: 1
             Timeout:  1000ms\
             """

      assert error.message =~ ~s|- Expect "toHaveCount" locator('span') with timeout 1000ms|
    end

    test "fail zero 2", %{page: page} do
      Page.set_content!(page, "<div><span></span></div>")
      locator = Page.locator(page, "span")
      {:error, error} = Expect.not_to_have_count(locator, 1, timeout: 1000)

      assert error.message =~ """
             expect(locator).not.toHaveCount(expected) failed

             Locator:  Page.locator(page, "span")
             Expected: not 1
             Received: 1
             Timeout:  1000ms\
             """

      assert error.message =~ ~s|- Expect "not toHaveCount" locator('span') with timeout 1000ms|
    end
  end

  describe "toHaveJSProperty" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = { a: 1, b: 'string', c: new Date(1627503992000) }")
      locator = Page.locator(page, "div")
      Expect.to_have_js_property!(locator, "foo", %{a: 1, b: "string", c: date(1_627_503_992_000)})
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = { a: 1, b: 'string', c: new Date(1627503992000) }")
      locator = Page.locator(page, "div")

      {:error, error} =
        Expect.to_have_js_property(locator, "foo", %{a: 1, b: "string", c: date(1_627_503_992_001)}, timeout: 1000)

      assert error.message =~ ~s|-   "c"|
    end

    test "pass string", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = 'string'")
      locator = Page.locator(page, "div")
      Expect.to_have_js_property!(locator, "foo", "string")
    end

    test "fail string", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = 'string'")
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_have_js_property(locator, "foo", "error", timeout: 200)

      assert error.message =~ """
             expect(locator).toHaveJSProperty(expected) failed

             Locator:  Page.locator(page, "div")
             Expected: "error"
             Received: "string"
             Timeout:  200ms\
             """

      assert error.message =~ ~s|- Expect "toHaveJSProperty" locator('div') with timeout 200ms|
    end

    test "pass number", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = 2021")
      locator = Page.locator(page, "div")
      Expect.to_have_js_property!(locator, "foo", 2021)
    end

    test "fail number", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = 2021")
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_have_js_property(locator, "foo", 1, timeout: 200)

      assert error.message =~ """
             expect(locator).toHaveJSProperty(expected) failed

             Locator:  Page.locator(page, "div")
             Expected: 1
             Received: 2021
             Timeout:  200ms\
             """

      assert error.message =~ ~s|- Expect "toHaveJSProperty" locator('div') with timeout 200ms|
    end

    test "pass boolean", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = true")
      locator = Page.locator(page, "div")
      Expect.to_have_js_property!(locator, "foo", true)
    end

    test "fail boolean", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = false")
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_have_js_property(locator, "foo", true, timeout: 200)

      assert error.message =~ """
             expect(locator).toHaveJSProperty(expected) failed

             Locator:  Page.locator(page, "div")
             Expected: true
             Received: false
             Timeout:  200ms\
             """

      assert error.message =~ ~s|- Expect "toHaveJSProperty" locator('div') with timeout 200ms|
    end

    test "pass boolean 2", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = false")
      locator = Page.locator(page, "div")
      Expect.to_have_js_property!(locator, "foo", false)
    end

    test "fail boolean 2", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = false")
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_have_js_property(locator, "foo", true, timeout: 200)

      assert error.message =~ """
             expect(locator).toHaveJSProperty(expected) failed

             Locator:  Page.locator(page, "div")
             Expected: true
             Received: false
             Timeout:  200ms\
             """

      assert error.message =~ ~s|- Expect "toHaveJSProperty" locator('div') with timeout 200ms|
    end

    test "pass undefined", %{page: page} do
      Page.set_content!(page, "<div></div>")
      locator = Page.locator(page, "div")
      Expect.to_have_js_property!(locator, "foo", nil)
    end

    test "pass null", %{page: page} do
      Page.set_content!(page, "<div></div>")
      Page.eval_on_selector!(page, "div", "e => e.foo = null")
      locator = Page.locator(page, "div")
      Expect.to_have_js_property!(locator, "foo", :null)
    end

    test "pass nested", %{page: page} do
      Page.set_content!(page, "<div></div>")

      Page.eval_on_selector!(
        page,
        "div",
        "e => e.foo = { nested: { a: 1, b: 'string', c: new Date(1627503992000) } }"
      )

      locator = Page.locator(page, "div")
      Expect.to_have_js_property!(locator, "foo.nested", %{a: 1, b: "string", c: date(1_627_503_992_000)})
      Expect.to_have_js_property!(locator, "foo.nested.a", 1)
      Expect.to_have_js_property!(locator, "foo.nested.b", "string")
      Expect.to_have_js_property!(locator, "foo.nested.c", date(1_627_503_992_000))
    end

    test "fail nested", %{page: page} do
      Page.set_content!(page, "<div></div>")

      Page.eval_on_selector!(
        page,
        "div",
        "e => e.foo = { nested: { a: 1, b: 'string', c: new Date(1627503992000) } }"
      )

      locator = Page.locator(page, "div")

      {:error, error1} =
        Expect.to_have_js_property(locator, "foo.bar", %{a: 1, b: "string", c: date(1_627_503_992_001)}, timeout: 1000)

      assert error1.message =~ "Received: undefined"
      {:error, error2} = Expect.to_have_js_property(locator, "foo.nested.a", 2, timeout: 1000)
      assert error2.message =~ "Received: 1"
    end
  end

  describe "toHaveClass" do
    test "pass", %{page: page} do
      Page.set_content!(page, ~s|<div class="foo bar baz"></div>|)
      locator = Page.locator(page, "div")
      Expect.to_have_class!(locator, "foo bar baz")
    end

    test "pass with SVGs", %{page: page} do
      Page.set_content!(
        page,
        ~s|<svg class="c1 c2" role="img" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"></svg>|
      )

      Expect.to_have_class!(Page.locator(page, "svg"), ~r/c1/)
    end

    test "fail", %{page: page} do
      Page.set_content!(page, ~s|<div class="bar baz"></div>|)
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_have_class(locator, "foo bar baz", timeout: 1000)

      assert error.message =~ """
             expect(locator).toHaveClass(expected) failed

             Locator:  Page.locator(page, "div")
             Expected: "foo bar baz"
             Received: "bar baz"
             Timeout:  1000ms

             Call log:
             """

      assert error.message =~ ~s|- Expect "toHaveClass" locator('div') with timeout 1000ms|
    end

    test "pass with array", %{page: page} do
      Page.set_content!(page, ~s|<div class="foo"></div><div class="bar"></div><div class="baz"></div>|)
      locator = Page.locator(page, "div")
      Expect.to_have_class!(locator, ["foo", "bar", ~r/[a-z]az/])
    end

    test "fail with array", %{page: page} do
      Page.set_content!(page, ~s|<div class="foo"></div><div class="bar"></div><div class="bar"></div>|)
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_have_class(locator, ["foo", "bar", ~r/[a-z]az/], timeout: 1000)
      assert error.message =~ "expect(locator).toHaveClass(expected) failed"
      assert error.message =~ "Timeout: 1000ms"
      assert error.message =~ ~s|- Expect "toHaveClass" locator('div') with timeout 1000ms|
    end
  end

  describe "toContainClass" do
    test "pass", %{page: page} do
      Page.set_content!(page, ~s|<div class="foo bar baz"></div>|)
      locator = Page.locator(page, "div")
      Expect.to_contain_class!(locator, "")
      Expect.to_contain_class!(locator, "bar")
      Expect.to_contain_class!(locator, "baz bar")
      Expect.to_contain_class!(locator, "  bar   foo ")
      # Strip whitespace and match individual classes
      Expect.not_to_contain_class!(locator, "  baz   not-matching ")
      {:error, e} = Expect.to_contain_class(locator, ~r/foo|bar/)
      assert Exception.message(e) =~ ~r/"expected\" argument in toContainClass cannot be a RegExp value/
    end

    test "pass with SVGs", %{page: page} do
      Page.set_content!(
        page,
        ~s|<svg class="c1 c2" role="img" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"></svg>|
      )

      Expect.to_contain_class!(Page.locator(page, "svg"), "c1")
    end

    test "fail", %{page: page} do
      Page.set_content!(page, ~s|<div class="bar baz"></div>|)
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_contain_class(locator, "does-not-exist", timeout: 1000)

      assert error.message =~ """
             expect(locator).toContainClass(expected) failed

             Locator:  Page.locator(page, "div")
             Expected: "does-not-exist"
             Received: "bar baz"
             Timeout:  1000ms

             Call log:
             """

      assert error.message =~ ~s|- Expect "toContainClass" locator('div') with timeout 1000ms|
    end

    test "pass with array", %{page: page} do
      Page.set_content!(page, ~s|<div class="foo"></div><div class="hello bar"></div><div class="baz"></div>|)
      locator = Page.locator(page, "div")
      Expect.to_contain_class!(locator, ["foo", "hello", "baz"])
      {:error, e} = Expect.to_contain_class(locator, ["foo", "hello", ~r/baz/])
      assert Exception.message(e) =~ ~r/"expected" argument in toContainClass cannot contain RegExp values/
      # Class not there
      Expect.not_to_have_class!(locator, ["not-there", "hello", "baz"])
      # Length mismatch
      Expect.not_to_have_class!(locator, ["foo", "hello"])
    end

    test "fail with array", %{page: page} do
      Page.set_content!(page, ~s|<div class="foo"></div><div class="bar"></div><div class="bar"></div>|)
      locator = Page.locator(page, "div")
      {:error, error} = Expect.to_contain_class(locator, ["foo", "bar", "baz"], timeout: 1000)
      assert error.message =~ "expect(locator).toContainClass(expected) failed"
      assert error.message =~ "Timeout: 1000ms"
      assert error.message =~ ~s|- Expect "toContainClass" locator('div') with timeout 1000ms|
    end
  end

  describe "toHaveTitle" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<title>  Hello     world</title>")
      Expect.to_have_title!(page, "Hello  world")
    end

    test "fail", %{page: page} do
      Page.set_content!(page, "<title>Bye</title>")
      {:error, error} = Expect.to_have_title(page, "Hello", timeout: 1000)

      assert error.message =~ """
             expect(page).toHaveTitle(expected) failed

             Expected: "Hello"
             Received: "Bye"
             Timeout:  1000ms

             Call log:
             """

      assert error.message =~ ~s|- Expect "toHaveTitle" with timeout 1000ms|
    end
  end

  describe "toHaveURL" do
    test "pass", %{page: page} do
      Page.goto!(page, "data:text/html,<div>A</div>")
      Expect.to_have_url!(page, "data:text/html,<div>A</div>")
    end

    test "fail string", %{page: page} do
      Page.goto!(page, "data:text/html,<div>A</div>")
      {:error, error} = Expect.to_have_url(page, "wrong", timeout: 1000)

      assert error.message =~ """
             expect(page).toHaveURL(expected) failed

             Expected: "wrong"
             Received: "data:text/html,<div>A</div>"
             Timeout:  1000ms

             Call log:
             """
    end

    test "fail with invalid argument", %{page: page} do
      Page.goto!(page, "data:text/html,<div>A</div>")
      {:error, error} = Expect.to_have_url(page, %{})

      assert Exception.message(error) =~ """
             expect(page).toHaveURL(expected) failed

             Error: expected value must be a string or regular expression
             Expected has type:  object
             Expected has value: {}
             """
    end

    test "fail with positive predicate", %{page: page} do
      Page.goto!(page, "data:text/html,<div>A</div>")
      {:error, error} = Expect.to_have_url(page, fn _url -> false end)

      assert error.message =~ """
             expect(page).toHaveURL(expected) failed

             Expected: predicate to succeed
             Received: "data:text/html,<div>A</div>"
             Timeout:  10000ms
             """
    end

    test "fail with negative predicate", %{page: page} do
      Page.goto!(page, "data:text/html,<div>A</div>")
      {:error, error} = Expect.not_to_have_url(page, fn _url -> true end)

      assert error.message =~ """
             expect(page).not.toHaveURL(expected) failed

             Expected: predicate to fail
             Received: "data:text/html,<div>A</div>"
             Timeout:  10000ms
             """
    end

    test "resolve predicate on initial call", %{page: page} do
      Page.goto!(page, "data:text/html,<div>A</div>")
      Expect.to_have_url!(page, fn url -> url == "data:text/html,<div>A</div>" end, timeout: 1000)
    end

    test "resolve predicate after retries", %{page: page} do
      Page.goto!(page, "data:text/html,<div>A</div>")

      expect_promise =
        Runtime.Promise.async(fn ->
          Expect.to_have_url!(page, fn url -> url == "data:text/html,<div>B</div>" end, timeout: 1000)
        end)

      Task.start(fn ->
        Process.sleep(500)
        Page.goto(page, "data:text/html,<div>B</div>")
      end)

      assert Runtime.Promise.await(expect_promise) == :ok
    end

    test "support ignoreCase", %{page: page} do
      Page.goto!(page, "data:text/html,<div>A</div>")
      Expect.to_have_url!(page, "DATA:teXT/HTml,<div>a</div>", ignore_case: true)
    end

    test "support URLPattern"
  end

  describe "toHaveAttribute" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_have_attribute!(locator, "id", "node")
    end

    test "should not match missing attribute", %{page: page} do
      Page.set_content!(page, "<div checked id=node>Text content</div>")
      locator = Page.locator(page, "#node")

      {:error, error} = Expect.to_have_attribute(locator, "disabled", "", timeout: 1000)

      assert error.message =~ """
             expect(locator).toHaveAttribute(expected) failed

             Locator:  Page.locator(page, "#node")
             Expected: ""
             Received: serializes to the same string
             Timeout:  1000ms

             Call log:
             """

      assert error.message =~ ~s|- Expect "toHaveAttribute" locator('#node') with timeout 1000ms|

      {:error, error} = Expect.to_have_attribute(locator, "disabled", ~r/.*/, timeout: 1000)

      assert error.message =~ """
             expect(locator).toHaveAttribute(expected) failed

             Locator: Page.locator(page, "#node")
             Expected pattern: /.*/
             Received string:  ""
             Timeout: 1000ms

             Call log:
             """

      assert error.message =~ ~s|- Expect "toHaveAttribute" locator('#node') with timeout 1000ms|

      Expect.not_to_have_attribute!(locator, "disabled", "")
      Expect.not_to_have_attribute!(locator, "disabled", ~r/.*/)
    end

    test "should match boolean attribute", %{page: page} do
      Page.set_content!(page, "<div checked id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_have_attribute!(locator, "checked", "")
      Expect.to_have_attribute!(locator, "checked", ~r/.*/)

      # `expect(locator).not` as `Expect.not_/1` here, as `not_to_*` elsewhere.
      {:error, error} = locator |> Expect.not_() |> Expect.to_have_attribute("checked", "", timeout: 1000)

      assert error.message =~ """
             expect(locator).not.toHaveAttribute(expected) failed

             Locator:  Page.locator(page, "#node")
             Expected: not ""
             Received: ""
             Timeout:  1000ms

             Call log:
             """

      assert error.message =~ ~s|- Expect "not toHaveAttribute" locator('#node') with timeout 1000ms|

      {:error, error} = Expect.not_to_have_attribute(locator, "checked", ~r/.*/, timeout: 1000)

      assert error.message =~ """
             expect(locator).not.toHaveAttribute(expected) failed

             Locator: Page.locator(page, "#node")
             Expected pattern: not /.*/
             Received string: ""
             Timeout: 1000ms\
             """

      assert error.message =~ ~s|- Expect "not toHaveAttribute" locator('#node') with timeout 1000ms|
    end

    test "should match attribute without value", %{page: page} do
      Page.set_content!(page, "<div checked id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_have_attribute!(locator, "id")
      Expect.to_have_attribute!(locator, "checked")
      Expect.not_to_have_attribute!(locator, "open")
    end

    test "should support boolean attribute with options", %{page: page} do
      Page.set_content!(page, "<div checked id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_have_attribute!(locator, "id", timeout: 5000)
      Expect.to_have_attribute!(locator, "checked", %{timeout: 5000})
      locator |> Expect.not_() |> Expect.to_have_attribute!("open", timeout: 5000)
    end

    test "support ignoreCase", %{page: page} do
      Page.set_content!(page, "<div id=NoDe>Text content</div>")
      locator = Page.locator(page, "#NoDe")
      Expect.to_have_attribute!(locator, "id", "node", ignore_case: true)
      Expect.not_to_have_attribute!(locator, "id", "node")
    end
  end

  describe "toHaveCSS" do
    test "pass", %{page: page} do
      Page.set_content!(page, ~s|<div id=node style="color: rgb(255, 0, 0)">Text content</div>|)
      locator = Page.locator(page, "#node")
      Expect.to_have_css!(locator, "color", "rgb(255, 0, 0)")
    end

    test "should support pseudo element", %{page: page} do
      Page.set_content!(page, """
        <style>
          #node::before {
            color: rgb(255, 0, 0);
            content: "Text content";
          }
        </style>
        <div id=node></div>
      """)

      locator = Page.locator(page, "#node")
      Expect.to_have_css!(locator, "color", "rgb(255, 0, 0)", pseudo: :before)
    end

    test "custom css properties", %{page: page} do
      Page.set_content!(page, ~s|<div id=node style="--custom-color-property:#FF00FF;">Text content</div>|)
      locator = Page.locator(page, "#node")
      Expect.to_have_css!(locator, "--custom-color-property", "#FF00FF")
    end
  end

  describe "toHaveId" do
    test "pass", %{page: page} do
      Page.set_content!(page, "<div id=node>Text content</div>")
      locator = Page.locator(page, "#node")
      Expect.to_have_id!(locator, "node")
    end
  end

  describe "toBeInViewport" do
    test "should work", %{page: page} do
      Page.set_content!(page, """
        <div id=big style="height: 10000px;"></div>
        <div id=small>foo</div>
      """)

      Expect.to_be_in_viewport!(Page.locator(page, "#big"))
      Expect.not_to_be_in_viewport!(Page.locator(page, "#small"))
      Locator.scroll_into_view_if_needed!(Page.locator(page, "#small"))
      Expect.to_be_in_viewport!(Page.locator(page, "#small"))
      Expect.to_be_in_viewport!(Page.locator(page, "#small"), ratio: 1)
    end

    test "should respect ratio option", %{page: page} do
      Page.set_content!(page, """
        <style>body, div, html { padding: 0; margin: 0; }</style>
        <div id=big style="height: 400vh;"></div>
      """)

      Expect.to_be_in_viewport!(Page.locator(page, "div"))
      Expect.to_be_in_viewport!(Page.locator(page, "div"), ratio: 0.1)
      Expect.to_be_in_viewport!(Page.locator(page, "div"), ratio: 0.2)

      Expect.to_be_in_viewport!(Page.locator(page, "div"), ratio: 0.24)
      # In this test, element's ratio is 0.25.
      Expect.to_be_in_viewport!(Page.locator(page, "div"), ratio: 0.25)
      Expect.not_to_be_in_viewport!(Page.locator(page, "div"), ratio: 0.26)

      Expect.not_to_be_in_viewport!(Page.locator(page, "div"), ratio: 0.3)
      Expect.not_to_be_in_viewport!(Page.locator(page, "div"), ratio: 0.7)
      Expect.not_to_be_in_viewport!(Page.locator(page, "div"), ratio: 0.8)
    end

    # `error.stack` is the stack trace of the raised error. Its `at` frames are the frames outside
    # the libraries (`@playwright/test` hides its own): here the frames of modules in no OTP
    # application (the library, ExUnit and OTP frames are).
    test "should have good stack", %{page: page} do
      {error, stacktrace} =
        try do
          Expect.not_to_be_in_viewport!(Page.locator(page, "body"), timeout: 3000)
          {nil, nil}
        rescue
          e -> {e, __STACKTRACE__}
        end

      assert error
      assert Exception.format(:error, error, stacktrace) =~ ~r/unexpected value "viewport ratio \d+/

      stack_frames =
        Enum.filter(stacktrace, fn {module, _, _, _} -> :application.get_application(module) == :undefined end)

      assert length(stack_frames) == 1
      assert Exception.format_stacktrace(stack_frames) =~ Path.relative_to_cwd(__ENV__.file)
    end

    test "should report intersection even if fully covered by other element", %{page: page} do
      Page.set_content!(page, """
        <h1>hello</h1>
        <div style="position: relative; height: 10000px; top: -5000px;></div>
      """)

      Expect.to_be_in_viewport!(Page.locator(page, "h1"))
    end
  end

  test "toHaveCount should not produce logs twice", %{page: page} do
    Page.set_content!(page, "<select><option>One</option></select>")
    {:error, error} = Expect.to_have_count(Page.locator(page, "option"), 2, timeout: 2000)
    waiting_for_message = "waiting for locator('option')"
    assert error.message =~ waiting_for_message
    assert error.message =~ "locator resolved to 1 element"
    assert error.message =~ ~s|unexpected value "1"|
    refute String.replace(error.message, waiting_for_message, "<redacted>", global: false) =~ waiting_for_message
  end

  test "toHaveText should not produce logs twice", %{page: page} do
    Page.set_content!(page, "<div>hello</div>")
    {:error, error} = Expect.to_have_text(Page.locator(page, "div"), "world", timeout: 2000)
    waiting_for_message = "waiting for locator('div')"
    assert error.message =~ waiting_for_message
    assert error.message =~ "locator resolved to <div>hello</div>"
    assert error.message =~ ~s|unexpected value "hello"|
    refute String.replace(error.message, waiting_for_message, "<redacted>", global: false) =~ waiting_for_message
  end

  test "toHaveText that does not match should not produce logs twice", %{page: page} do
    Page.set_content!(page, "<div>hello</div>")
    {:error, error} = Expect.to_have_text(Page.locator(page, "span"), "world", timeout: 2000)
    waiting_for_message = "waiting for locator('span')"
    assert error.message =~ waiting_for_message
    refute error.message =~ "locator resolved to"
    refute String.replace(error.message, waiting_for_message, "<redacted>", global: false) =~ waiting_for_message
  end

  test "strict mode violation error format", %{page: page} do
    Page.set_content!(page, "<div>a</div><div>b</div>")
    {:error, error} = Expect.to_have_text(Page.locator(page, "div"), "foo")

    assert error.message =~ """
           expect(locator).toHaveText(expected) failed

           Locator: Page.locator(page, "div")
           Expected: "foo"
           Error: strict mode violation: locator('div') resolved to 2 elements:
               1) <div>a</div> aka getByText('a')
               2) <div>b</div> aka getByText('b')

           Call log:
           """
  end

  test "invalid selector error format", %{page: page} do
    Page.set_content!(page, "<div>a</div><div>b</div>")
    {:error, error} = Expect.to_be_visible(Page.locator(page, "##"))

    # Deviation: invalid CSS is rendered, not returned as is (parseCSS is not ported).
    assert error.message =~ """
           expect(locator).toBeVisible() failed

           Locator: Page.locator(page, "##")
           Expected: visible
           Error: Unexpected token "#" while parsing css selector "##". Did you mean to CSS.escape it?

           Call log:
           """
  end

  test "should report expect error details when page closes during expect", %{page: page} do
    Page.set_content!(page, "<div>hello</div>")
    promise = Runtime.Promise.async(fn -> Expect.to_have_text(Page.locator(page, "div"), "world", timeout: 10_000) end)
    Page.wait_for_timeout!(page, 1000)
    Page.close!(page)
    {:error, error} = Runtime.Promise.await(promise)
    assert Exception.message(error) =~ "expect(locator).toHaveText(expected) failed"
    assert Exception.message(error) =~ ~s|Expected: "world"|
    assert Exception.message(error) =~ ~s|Received: "hello"|
  end

  test "should report page close reason when page closes during expect", %{page: page} do
    Page.set_content!(page, "<div>hello</div>")
    # `Runtime.Promise.async/1` returns once the expect is sent: a `Task` could start it after the close.
    promise =
      Runtime.Promise.async(fn -> Expect.to_have_text(Page.locator(page, "non-existent"), "world", timeout: 10_000) end)

    Page.close!(page, reason: "Bye bye.")
    {:error, error} = Promise.await!(promise)
    assert Exception.message(error) =~ "expect(locator).toHaveText(expected) failed"
    assert Exception.message(error) =~ "Bye bye."
    refute Exception.message(error) =~ "Internal server error"
  end
end
