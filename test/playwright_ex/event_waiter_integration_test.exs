defmodule PlaywrightEx.EventWaiterIntegrationTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Dialog
  alias PlaywrightEx.EventWaiter

  test "enables console capture before the triggering command", %{browser_context: context, frame: frame} do
    {:ok, waiter} = EventWaiter.arm(context.guid, :console, timeout: @timeout, transform: & &1.params.text)
    assert {:ok, _} = eval(frame.guid, "() => console.log('captured')")
    assert {:ok, "captured"} = EventWaiter.await(waiter)
  end

  test "a transform can handle a dialog while the owner's command is blocked", %{page: page, frame: frame} do
    {:ok, waiter} =
      EventWaiter.arm(page.guid, :__create__,
        timeout: @timeout,
        subscription: :dialog,
        predicate: &match?(%{params: %{type: "Dialog"}}, &1),
        transform: fn %{params: params} ->
          {:ok, _} = Dialog.accept(params.guid, prompt_text: "accepted", timeout: @timeout)
          params.initializer.message
        end
      )

    assert {:ok, "accepted"} = eval(frame.guid, "() => prompt('Question?')")
    assert {:ok, "Question?"} = EventWaiter.await(waiter)
  end
end
