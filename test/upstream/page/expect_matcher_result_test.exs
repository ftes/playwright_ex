defmodule PlaywrightEx.Page.ExpectMatcherResultTest do
  @upstream "tests/page/expect-matcher-result.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page

  @moduletag :page

  # "Locator:" lines are Elixir syntax (the client renders them, PLAN); call logs stay JS (the driver).

  # JS `Error.prototype.toString()`
  defp to_string_js(e), do: "Error: " <> e.message

  test "toMatchText-based assertions should have matcher result", %{page: page} do
    Page.set_content!(page, "<div id=node>Text content</div>")
    locator = Page.locator(page, "#node")

    {:error, e} = Expect.to_have_text(locator, ~r/Text2/, timeout: 1)

    assert %{
             actual: "Text content",
             expected: %Regex{source: "Text2"},
             message: message,
             name: "toHaveText",
             pass: false,
             log: log,
             timeout: 1,
             ariaSnapshot: aria_snapshot
           } = e.matcherResult

    assert map_size(e.matcherResult) == 8
    assert message =~ "expect(locator).toHaveText(expected) failed"
    assert is_list(log)
    assert is_binary(aria_snapshot)

    assert to_string_js(e) =~ """
           Error: expect(locator).toHaveText(expected) failed

           Locator: Page.locator(page, "#node")
           Expected pattern: /Text2/
           Received string:  \"Text content\"
           Timeout: 1ms

           Call log\
           """

    {:error, e} = Expect.not_to_have_text(locator, ~r/Text/, timeout: 1)

    assert %{
             actual: "Text content",
             expected: %Regex{source: "Text"},
             message: message,
             name: "toHaveText",
             pass: true,
             log: log,
             timeout: 1,
             ariaSnapshot: aria_snapshot
           } = e.matcherResult

    assert map_size(e.matcherResult) == 8
    assert message =~ "expect(locator).not.toHaveText(expected) failed"
    assert is_list(log)
    assert is_binary(aria_snapshot)

    assert to_string_js(e) =~ """
           Error: expect(locator).not.toHaveText(expected) failed

           Locator: Page.locator(page, "#node")
           Expected pattern: not /Text/
           Received string: \"Text content\"
           Timeout: 1ms

           Call log\
           """
  end

  test "toBeTruthy-based assertions should have matcher result", %{page: page} do
    Page.set_content!(page, "<div id=node>Text content</div>")

    {:error, e} = Expect.to_be_visible(Page.locator(page, "#node2"), timeout: 1)

    assert %{
             expected: "visible",
             message: message,
             name: "toBeVisible",
             pass: false,
             log: log,
             timeout: 1,
             ariaSnapshot: aria_snapshot
           } = e.matcherResult

    assert map_size(e.matcherResult) == 7
    assert message =~ "expect(locator).toBeVisible() failed"
    assert is_list(log)
    assert is_binary(aria_snapshot)

    assert to_string_js(e) =~ """
           Error: expect(locator).toBeVisible() failed

           Locator: Page.locator(page, "#node2")
           Expected: visible
           Timeout: 1ms
           Error: element(s) not found

           Call log:
           """

    {:error, e} = Expect.not_to_be_visible(Page.locator(page, "#node"), timeout: 1)

    assert %{
             actual: "visible",
             expected: "visible",
             message: message,
             name: "toBeVisible",
             pass: true,
             log: log,
             timeout: 1,
             ariaSnapshot: aria_snapshot
           } = e.matcherResult

    assert map_size(e.matcherResult) == 8
    assert message =~ "expect(locator).not.toBeVisible() failed"
    assert is_list(log)
    assert is_binary(aria_snapshot)

    assert to_string_js(e) =~ """
           Error: expect(locator).not.toBeVisible() failed

           Locator:  Page.locator(page, "#node")
           Expected: not visible
           Received: visible
           Timeout:  1ms

           Call log:
           """
  end

  test "toEqual-based assertions should have matcher result", %{page: page} do
    Page.set_content!(page, "<div id=node>Text content</div>")

    {:error, e} = Expect.to_have_count(Page.locator(page, "#node2"), 1, timeout: 1)

    assert %{
             actual: 0,
             expected: 1,
             message: message,
             name: "toHaveCount",
             pass: false,
             log: log,
             timeout: 1
           } = e.matcherResult

    assert map_size(e.matcherResult) == 7
    assert message =~ "expect(locator).toHaveCount(expected) failed"
    assert is_list(log)

    assert to_string_js(e) =~ """
           Error: expect(locator).toHaveCount(expected) failed

           Locator:  Page.locator(page, "#node2")
           Expected: 1
           Received: 0
           Timeout:  1ms

           Call log\
           """

    {:error, e} = Expect.not_to_have_count(Page.locator(page, "#node"), 1, timeout: 1)

    assert %{
             actual: 1,
             expected: 1,
             message: message,
             name: "toHaveCount",
             pass: true,
             log: log,
             timeout: 1
           } = e.matcherResult

    assert map_size(e.matcherResult) == 7
    assert message =~ "expect(locator).not.toHaveCount(expected) failed"
    assert is_list(log)

    assert to_string_js(e) =~ """
           Error: expect(locator).not.toHaveCount(expected) failed

           Locator:  Page.locator(page, "#node")
           Expected: not 1
           Received: 1
           Timeout:  1ms

           Call log\
           """
  end

  test "toBeChecked({ checked }) should have expected", %{page: page} do
    Page.set_content!(page, """
        <input id=checked type=checkbox checked></input>
        <input id=unchecked type=checkbox></input>
    """)

    assert_checked_result = fn e, actual, expected, pass, hint ->
      assert %{
               actual: ^actual,
               expected: ^expected,
               message: message,
               name: "toBeChecked",
               pass: ^pass,
               log: log,
               timeout: 1,
               ariaSnapshot: aria_snapshot
             } = e.matcherResult

      assert map_size(e.matcherResult) == 8
      assert message =~ hint
      assert is_list(log)
      assert is_binary(aria_snapshot)
    end

    {:error, e} = Expect.to_be_checked(Page.locator(page, "#unchecked"), timeout: 1)
    assert_checked_result.(e, "unchecked", "checked", false, "expect(locator).toBeChecked() failed")

    assert to_string_js(e) =~ """
           Error: expect(locator).toBeChecked() failed

           Locator:  Page.locator(page, "#unchecked")
           Expected: checked
           Received: unchecked
           Timeout:  1ms

           Call log\
           """

    {:error, e} = Expect.not_to_be_checked(Page.locator(page, "#checked"), timeout: 1)
    assert_checked_result.(e, "checked", "checked", true, "expect(locator).not.toBeChecked() failed")

    assert to_string_js(e) =~ """
           Error: expect(locator).not.toBeChecked() failed

           Locator:  Page.locator(page, "#checked")
           Expected: not checked
           Received: checked
           Timeout:  1ms

           Call log\
           """

    {:error, e} = Expect.to_be_checked(Page.locator(page, "#checked"), checked: false, timeout: 1)

    assert_checked_result.(
      e,
      "checked",
      "unchecked",
      false,
      "expect(locator).toBeChecked({ checked: false }) failed"
    )

    assert to_string_js(e) =~ """
           Error: expect(locator).toBeChecked({ checked: false }) failed

           Locator:  Page.locator(page, "#checked")
           Expected: unchecked
           Received: checked
           Timeout:  1ms

           Call log\
           """

    {:error, e} = Expect.not_to_be_checked(Page.locator(page, "#unchecked"), checked: false, timeout: 1)

    assert_checked_result.(
      e,
      "unchecked",
      "unchecked",
      true,
      "expect(locator).not.toBeChecked({ checked: false }) failed"
    )

    assert to_string_js(e) =~ """
           Error: expect(locator).not.toBeChecked({ checked: false }) failed

           Locator:  Page.locator(page, "#unchecked")
           Expected: not unchecked
           Received: unchecked
           Timeout:  1ms

           Call log\
           """

    {:error, e} = Expect.to_be_checked(Page.locator(page, "#unchecked"), indeterminate: true, timeout: 1)

    assert_checked_result.(
      e,
      "unchecked",
      "indeterminate",
      false,
      "expect(locator).toBeChecked({ indeterminate: true }) failed"
    )

    assert to_string_js(e) =~ """
           Error: expect(locator).toBeChecked({ indeterminate: true }) failed

           Locator:  Page.locator(page, "#unchecked")
           Expected: indeterminate
           Received: unchecked
           Timeout:  1ms

           Call log\
           """
  end

  @tag :tmp_dir
  test "toHaveScreenshot should populate matcherResult",
       %{page: page, server: server, browser_name: browser_name, tmp_dir: tmp_dir} do
    # test.skip(isAndroid);
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.empty_page)

    # The runner resolves 'screenshot-sanity.png' to the spec's snapshot; failures write next to the copy.
    path = Path.join(tmp_dir, "screenshot-sanity.png")

    File.cp!(
      Path.join(
        PlaywrightEx.Upstream.dir(),
        "tests/page/expect-matcher-result.spec.ts-snapshots/screenshot-sanity-#{browser_name}.png"
      ),
      path
    )

    {:error, e} = Expect.to_have_screenshot(page, path: path)

    assert %{
             attachments: [%{}, %{}, %{}],
             actual: actual,
             expected: expected,
             diff: diff,
             message: message,
             name: "toHaveScreenshot",
             pass: false,
             log: log
           } = e.matcherResult

    assert map_size(e.matcherResult) == 8
    assert actual =~ "screenshot-sanity-actual"
    # expect.stringContaining('screenshot-sanity-'): the runner's snapshot name has the project suffix.
    assert expected =~ "screenshot-sanity"
    assert diff =~ "screenshot-sanity-diff"
    assert message =~ "expect(page).toHaveScreenshot(expected)"
    assert is_list(log)

    assert to_string_js(e) =~ """
           Error: expect(page).toHaveScreenshot(expected) failed

             23362 pixels (ratio 0.10 of all image pixels) are different.
           """
  end
end
