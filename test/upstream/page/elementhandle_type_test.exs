defmodule PlaywrightEx.Page.ElementhandleTypeTest do
  @upstream "tests/page/elementhandle-type.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Page

  @moduletag :page

  test "should work", %{page: page} do
    Page.set_content!(page, "<input type='text' />")
    Page.type!(page, "input", "hello")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "hello"
  end

  test "should not select existing value", %{page: page} do
    Page.set_content!(page, "<input type='text' value='hello' />")
    Page.type!(page, "input", "world")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "worldhello"
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

    Page.type!(page, "input", "world")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "worldhello"
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

    Page.type!(page, "input", "world")
    assert Page.eval_on_selector!(page, "input", "input => input.value") == "heworldo"
  end

  test "should work with number input", %{page: page} do
    # it.fail(browserName === 'webkit', 'Started failing after https://github.com/WebKit/WebKit/commit/c92a2aea185d63b5e9998608a9c0321a461c496c')
    expected_failure(@browser_name == "webkit", fn ->
      Page.set_content!(page, "<input type='number' value=2 />")
      Page.type!(page, "input", "13")
      assert Page.eval_on_selector!(page, "input", "input => input.value") == "132"
    end)
  end
end
