defmodule PlaywrightEx.Page.ElementhandlePressTest do
  @upstream "tests/page/elementhandle-press.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "should work", %{page: page} do
    Page.set_content!(page, "<input type='text' />")
    Page.press!(page, "input", "h")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "h"
  end

  test "should not select existing value", %{page: page} do
    Page.set_content!(page, "<input type='text' value='hello' />")
    Page.press!(page, "input", "w")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "whello"
  end

  test "should reset selection when not focused", %{page: page} do
    Page.set_content!(page, "<input type='text' value='hello' /><div tabIndex=2>text</div>")

    Page.eval_on_selector!(page, "input", """
    input => {
      input.selectionStart = 2;
      input.selectionEnd = 4;
      document.querySelector('div').focus();
    }
    """)

    Page.press!(page, "input", "w")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "whello"
  end

  test "should not modify selection when focused", %{page: page} do
    Page.set_content!(page, "<input type='text' value='hello' />")

    Page.eval_on_selector!(page, "input", """
    input => {
      input.focus();
      input.selectionStart = 2;
      input.selectionEnd = 4;
    }
    """)

    Page.press!(page, "input", "w")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "hewo"
  end

  test "should work with number input", %{page: page, browser_name: browser_name} do
    # it.fail(browserName === 'webkit')
    if browser_name != "webkit" do
      Page.set_content!(page, "<input type='number' value=2 />")
      Page.press!(page, "input", "1")
      assert Page.eval_on_selector!(page, "input", "input => input.value") == "12"
    end
  end
end
