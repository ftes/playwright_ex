defmodule PlaywrightEx.Page.PageDialogTest do
  @upstream "tests/page/page-dialog.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Page

  @moduletag :page

  test "should fire", %{page: page} do
    test = self()

    Page.on(page, :dialog, fn dialog ->
      send(test, {:dialog, Dialog.type(dialog), Dialog.default_value(dialog), Dialog.message(dialog)})
      Dialog.accept(dialog)
    end)

    Page.evaluate!(page, "() => alert('yo')")
    assert_received {:dialog, "alert", "", "yo"}
  end

  @tag skip: "not ported: expect.poll"
  test "should fire dialogclosed when dialog is accepted"

  @tag skip: "not ported: waitForEvent"
  test "should fire dialogclosed when dialog is dismissed"

  @tag skip: "not ported: waitForEvent"
  test "should fire dialogclosed for auto-dismissed dialogs"

  test "should allow accepting prompts @smoke", %{page: page} do
    test = self()

    Page.on(page, :dialog, fn dialog ->
      send(test, {:dialog, Dialog.type(dialog), Dialog.default_value(dialog), Dialog.message(dialog)})
      Dialog.accept(dialog, "answer!")
    end)

    result = Page.evaluate!(page, "() => prompt('question?', 'yes.')")
    assert_received {:dialog, "prompt", "yes.", "question?"}
    assert result == "answer!"
  end

  test "should dismiss the prompt", %{page: page} do
    Page.on(page, :dialog, fn dialog -> Dialog.dismiss(dialog) end)
    result = Page.evaluate!(page, "() => prompt('question?')")
    assert result == :null
  end

  test "should accept the confirm prompt", %{page: page} do
    Page.on(page, :dialog, fn dialog ->
      Dialog.accept(dialog)
    end)

    result = Page.evaluate!(page, "() => confirm('boolean?')")
    assert result == true
  end

  test "should dismiss the confirm prompt", %{page: page} do
    Page.on(page, :dialog, fn dialog ->
      Dialog.dismiss(dialog)
    end)

    result = Page.evaluate!(page, "() => confirm('boolean?')")
    assert result == false
  end

  @tag skip: "not ported: waitForEvent"
  test "should be able to close context with open alert"

  test "should handle multiple alerts", %{page: page} do
    Page.on(page, :dialog, fn dialog ->
      Dialog.accept(dialog)
    end)

    Page.set_content!(page, """
    <p>Hello World</p>
    <script>
      alert('Please dismiss this dialog');
      alert('Please dismiss this dialog');
      alert('Please dismiss this dialog');
    </script>
    """)

    assert Page.text_content!(page, "p") == "Hello World"
  end

  test "should handle multiple confirms", %{page: page} do
    Page.on(page, :dialog, fn dialog ->
      Dialog.accept(dialog)
    end)

    Page.set_content!(page, """
    <p>Hello World</p>
    <script>
      confirm('Please confirm me?');
      confirm('Please confirm me?');
      confirm('Please confirm me?');
    </script>
    """)

    assert Page.text_content!(page, "p") == "Hello World"
  end

  test "should auto-dismiss the prompt without listeners", %{page: page} do
    result = Page.evaluate!(page, "() => prompt('question?')")
    assert result == :null
  end

  test "should auto-dismiss the alert without listeners", %{page: page} do
    Page.set_content!(page, ~s[<div onclick="window.alert(123); window._clicked=true">Click me</div>])
    Page.click!(page, "div")
    assert Page.evaluate!(page, "window._clicked") == true
  end
end
