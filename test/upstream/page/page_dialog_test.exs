defmodule PlaywrightEx.Page.PageDialogTest do
  @upstream "tests/page/page-dialog.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Utils

  @moduletag :page

  test "DI-001 should fire", %{page: page} do
    test = self()

    Page.on(page, :dialog, fn dialog ->
      send(test, {:dialog, Dialog.type(dialog), Dialog.default_value(dialog), Dialog.message(dialog)})
      Dialog.accept(dialog)
    end)

    Page.evaluate!(page, "() => alert('yo')")
    assert_received {:dialog, "alert", "", "yo"}
  end

  test "DI-002 should fire dialogclosed when dialog is accepted", %{page: page} do
    {:ok, closed} = Agent.start_link(fn -> [] end)
    Page.on(page, :dialog_closed, fn dialog -> Agent.update(closed, &(&1 ++ [dialog])) end)
    test = self()

    Page.on(page, :dialog, fn dialog ->
      send(test, {:opened, dialog})
      Dialog.accept(dialog)
    end)

    Page.evaluate!(page, "() => alert('yo')")
    Utils.poll(fn -> length(Agent.get(closed, & &1)) end, &assert(&1 == 1))
    assert_received {:opened, opened}
    assert hd(Agent.get(closed, & &1)) == opened
    # Perform some roundtrips to ensure the event does not fire twice.
    Page.evaluate!(page, "() => 1")
    Page.evaluate!(page, "() => 1")
    assert length(Agent.get(closed, & &1)) == 1
  end

  test "DI-003 should fire dialogclosed when dialog is dismissed", %{page: page} do
    closed_promise = Page.wait_for_event(page, :dialog_closed)
    Page.on(page, :dialog, fn dialog -> Dialog.dismiss(dialog) end)
    Page.evaluate!(page, "() => confirm('boolean?')")
    dialog = Promise.await!(closed_promise)
    assert Dialog.type(dialog) == "confirm"
    assert Dialog.message(dialog) == "boolean?"
  end

  test "DI-004 should fire dialogclosed for auto-dismissed dialogs", %{page: page} do
    closed_promise = Page.wait_for_event(page, :dialog_closed)
    Page.evaluate!(page, "() => alert('yo')")
    dialog = Promise.await!(closed_promise)
    assert Dialog.message(dialog) == "yo"
  end

  test "DI-005 should allow accepting prompts @smoke", %{page: page} do
    test = self()

    Page.on(page, :dialog, fn dialog ->
      send(test, {:dialog, Dialog.type(dialog), Dialog.default_value(dialog), Dialog.message(dialog)})
      Dialog.accept(dialog, "answer!")
    end)

    result = Page.evaluate!(page, "() => prompt('question?', 'yes.')")
    assert_received {:dialog, "prompt", "yes.", "question?"}
    assert result == "answer!"
  end

  test "DI-006 should dismiss the prompt", %{page: page} do
    Page.on(page, :dialog, fn dialog -> Dialog.dismiss(dialog) end)
    result = Page.evaluate!(page, "() => prompt('question?')")
    assert result == :null
  end

  test "DI-007 should accept the confirm prompt", %{page: page} do
    Page.on(page, :dialog, fn dialog ->
      Dialog.accept(dialog)
    end)

    result = Page.evaluate!(page, "() => confirm('boolean?')")
    assert result == true
  end

  test "DI-008 should dismiss the confirm prompt", %{page: page} do
    Page.on(page, :dialog, fn dialog ->
      Dialog.dismiss(dialog)
    end)

    result = Page.evaluate!(page, "() => confirm('boolean?')")
    assert result == false
  end

  test "DI-009 should be able to close context with open alert", %{page: page} do
    alert_promise = Page.wait_for_event(page, :dialog)

    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => alert('hello'), 0);
    }
    """)

    Promise.await!(alert_promise)
  end

  test "DI-010 should handle multiple alerts", %{page: page} do
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

  test "DI-011 should handle multiple confirms", %{page: page} do
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

  test "DI-012 should auto-dismiss the prompt without listeners", %{page: page} do
    result = Page.evaluate!(page, "() => prompt('question?')")
    assert result == :null
  end

  test "DI-013 should auto-dismiss the alert without listeners", %{page: page} do
    Page.set_content!(page, ~s[<div onclick="window.alert(123); window._clicked=true">Click me</div>])
    Page.click!(page, "div")
    assert Page.evaluate!(page, "window._clicked") == true
  end
end
