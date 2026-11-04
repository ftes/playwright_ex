# Spike 5: dialogs are auto-dismissed without a listener and handled by a listener;
# the listener count drives Page.updateSubscription (channelOwner._updateSubscription).
defmodule PlaywrightJS.DialogTest do
  use ExUnit.Case, async: false
  alias PlaywrightJS.TestHelper
  alias PlaywrightJS.Client.{Dialog, Page}

  test "auto-dismiss without listener, accept with listener, dismiss again after off" do
    %{page: page} = env = TestHelper.launch()

    assert Page.evaluate(page, "confirm('sure?')") == false
    assert Page.evaluate(page, "alert('hi')") == nil
    assert Page.evaluate(page, "prompt('name?', 'x')") == :null

    test = self()

    listener = fn dialog ->
      send(test, {:dialog, Dialog.type(dialog), Dialog.message(dialog)})
      if Dialog.type(dialog) == "prompt", do: Dialog.accept(dialog, "Ada"), else: Dialog.accept(dialog)
    end

    Page.on(page, "dialog", listener)

    for _ <- 1..5 do
      assert Page.evaluate(page, "confirm('sure?')") == true
      assert_received {:dialog, "confirm", "sure?"}
    end

    assert Page.evaluate(page, "prompt('name?', 'x')") == "Ada"
    assert_received {:dialog, "prompt", "name?"}

    Page.off(page, "dialog", listener)
    assert Page.evaluate(page, "confirm('sure?')") == false
    refute_received {:dialog, _, _}
    TestHelper.close(env)
  end
end
