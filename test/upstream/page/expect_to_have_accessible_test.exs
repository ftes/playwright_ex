defmodule PlaywrightEx.Page.ExpectToHaveAccessibleTest do
  @upstream "tests/page/expect-to-have-accessible.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  @error_message_text "Error message"

  test "EX-259 toHaveAccessibleName", %{page: page} do
    Page.set_content!(page, """
    <div role="button" aria-label="Hello"></div>
    """)

    Expect.to_have_accessible_name!(Page.locator(page, "div"), "Hello")
    Expect.not_to_have_accessible_name!(Page.locator(page, "div"), "hello")
    Expect.to_have_accessible_name!(Page.locator(page, "div"), "hello", ignore_case: true)
    Expect.to_have_accessible_name!(Page.locator(page, "div"), ~r/ell\w/)
    Expect.not_to_have_accessible_name!(Page.locator(page, "div"), ~r/hello/)
    Expect.to_have_accessible_name!(Page.locator(page, "div"), ~r/hello/, ignore_case: true)

    Page.set_content!(page, "<button>foo&nbsp;bar\nbaz</button>")
    Expect.to_have_accessible_name!(Page.locator(page, "button"), "foo bar baz")

    Page.set_content!(page, """
    <select>
      <option>&nbsp;HTML</option>
    </select>
    """)

    Expect.to_have_accessible_name!(Page.locator(page, "option"), "HTML")
  end

  test "EX-260 toHaveAccessibleDescription", %{page: page} do
    Page.set_content!(page, """
    <div role="button" aria-description="Hello"></div>
    """)

    Expect.to_have_accessible_description!(Page.locator(page, "div"), "Hello")
    Expect.not_to_have_accessible_description!(Page.locator(page, "div"), "hello")
    Expect.to_have_accessible_description!(Page.locator(page, "div"), "hello", ignore_case: true)
    Expect.to_have_accessible_description!(Page.locator(page, "div"), ~r/ell\w/)
    Expect.not_to_have_accessible_description!(Page.locator(page, "div"), ~r/hello/)
    Expect.to_have_accessible_description!(Page.locator(page, "div"), ~r/hello/, ignore_case: true)

    Page.set_content!(page, """
    <div role="button" aria-describedby="desc"></div>
    <span id="desc">foo&nbsp;bar\nbaz</span>
    """)

    Expect.to_have_accessible_description!(Page.locator(page, "div"), "foo bar baz")
  end

  test "EX-261 toHaveAccessibleErrorMessage", %{page: page} do
    Page.set_content!(page, """
    <form>
      <input role="textbox" aria-invalid="true" aria-errormessage="error-message" />
      <div id="error-message">Hello</div>
      <div id="irrelevant-error">This should not be considered.</div>
    </form>
    """)

    locator = Page.locator(page, "input[role=\"textbox\"]")
    Expect.to_have_accessible_error_message!(locator, "Hello")
    Expect.not_to_have_accessible_error_message!(locator, "hello")
    Expect.to_have_accessible_error_message!(locator, "hello", ignore_case: true)
    Expect.to_have_accessible_error_message!(locator, ~r/ell\w/)
    Expect.not_to_have_accessible_error_message!(locator, ~r/hello/)
    Expect.to_have_accessible_error_message!(locator, ~r/hello/, ignore_case: true)
    Expect.not_to_have_accessible_error_message!(locator, "This should not be considered.")
  end

  test "EX-262 toHaveAccessibleErrorMessage should handle multiple aria-errormessage references", %{page: page} do
    Page.set_content!(page, """
    <form>
      <input role="textbox" aria-invalid="true" aria-errormessage="error1 error2" />
      <div id="error1">First error message.</div>
      <div id="error2">Second error message.</div>
      <div id="irrelevant-error">This should not be considered.</div>
    </form>
    """)

    locator = Page.locator(page, "input[role=\"textbox\"]")

    Expect.to_have_accessible_error_message!(locator, "First error message. Second error message.")
    Expect.to_have_accessible_error_message!(locator, ~r/first error message./i)
    Expect.to_have_accessible_error_message!(locator, ~r/second error message./i)
    Expect.not_to_have_accessible_error_message!(locator, ~r/This should not be considered./i)
  end

  defp setup_page(page, aria_invalid_value) do
    aria_invalid_attr = if aria_invalid_value == nil, do: "", else: "aria-invalid=\"#{aria_invalid_value}\""

    Page.set_content!(page, """
    <form>
      <input id="node" role="textbox" #{aria_invalid_attr} aria-errormessage="error-msg" />
      <div id="error-msg">#{@error_message_text}</div>
    </form>
    """)

    Page.locator(page, "#node")
  end

  describe "toHaveAccessibleErrorMessage should handle aria-invalid attribute evaluated in false" do
    test "EX-263 no aria-invalid attribute", %{page: page} do
      locator = setup_page(page, nil)
      Expect.not_to_have_accessible_error_message!(locator, @error_message_text)
    end

    test "EX-264 aria-invalid=\"false\"", %{page: page} do
      locator = setup_page(page, "false")
      Expect.not_to_have_accessible_error_message!(locator, @error_message_text)
    end

    test "EX-265 aria-invalid=\"\" (empty string)", %{page: page} do
      locator = setup_page(page, "")
      Expect.not_to_have_accessible_error_message!(locator, @error_message_text)
    end
  end

  describe "toHaveAccessibleErrorMessage should handle aria-invalid attribute evaluated in true" do
    test "EX-266 aria-invalid=\"true\"", %{page: page} do
      locator = setup_page(page, "true")
      Expect.to_have_accessible_error_message!(locator, @error_message_text)
    end

    test "EX-267 aria-invalid=\"foo\" (unrecognized value)", %{page: page} do
      locator = setup_page(page, "foo")
      Expect.to_have_accessible_error_message!(locator, @error_message_text)
    end
  end

  test "EX-268 should show error message when validity is false and aria-invalid is true", %{page: page} do
    Page.set_content!(page, """
    <form>
      <input id="node" role="textbox" type="number" min="1" max="100" aria-invalid="true" aria-errormessage="error-msg" />
      <div id="error-msg">#{@error_message_text}</div>
    </form>
    """)

    locator = Page.locator(page, "#node")
    Locator.fill!(locator, "101")
    Expect.to_have_accessible_error_message!(locator, @error_message_text)
  end

  test "EX-269 should show error message when validity is true and aria-invalid is true", %{page: page} do
    Page.set_content!(page, """
    <form>
      <input id="node" role="textbox" type="number" min="1" max="100" aria-invalid="true" aria-errormessage="error-msg" />
      <div id="error-msg">#{@error_message_text}</div>
    </form>
    """)

    locator = Page.locator(page, "#node")
    Locator.fill!(locator, "99")
    Expect.to_have_accessible_error_message!(locator, @error_message_text)
  end

  test "EX-270 should show error message when validity is false and aria-invalid is false", %{page: page} do
    Page.set_content!(page, """
    <form>
      <input id="node" role="textbox" type="number" min="1" max="100" aria-invalid="false" aria-errormessage="error-msg" />
      <div id="error-msg">#{@error_message_text}</div>
    </form>
    """)

    locator = Page.locator(page, "#node")
    Locator.fill!(locator, "101")
    Expect.to_have_accessible_error_message!(locator, @error_message_text)
  end

  test "EX-271 should not show error message when validity is true and aria-invalid is false", %{page: page} do
    Page.set_content!(page, """
    <form>
      <input id="node" role="textbox" type="number" min="1" max="100" aria-invalid="false" aria-errormessage="error-msg" />
      <div id="error-msg">#{@error_message_text}</div>
    </form>
    """)

    locator = Page.locator(page, "#node")
    Locator.fill!(locator, "99")
    Expect.not_to_have_accessible_error_message!(locator, @error_message_text)
  end

  test "EX-272 should show error message for all roles", %{page: page} do
    Page.set_content!(page, """
    <label for="file">File input</label>
    <input id="file" aria-invalid="true" aria-errormessage="file-error-id" type="file" />
    <p id="file-error-id" role="alert">File is incorrect</p>
    """)

    locator = Page.get_by_label(page, "File input")
    Expect.to_have_accessible_error_message!(locator, "File is incorrect")
  end

  test "EX-273 toHaveRole", %{page: page} do
    Page.set_content!(page, "<div role=\"button\">Button!</div>")
    Expect.to_have_role!(Page.locator(page, "div"), "button")
    Expect.not_to_have_role!(Page.locator(page, "div"), "checkbox")

    # Upstream passes the regex past the types (@ts-expect-error).
    {:error, error} = Expect.to_have_role(Page.locator(page, "div"), ~r/button|checkbox/)
    assert Exception.message(error) == "\"role\" argument in toHaveRole must be a string"
  end
end
