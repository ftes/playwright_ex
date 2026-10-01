defmodule PlaywrightEx.EventWaiterIntegrationTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.EventWaiter
  alias PlaywrightEx.Frame

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

  test "synchronous removal restores dialog auto-dismiss while the subscriber stays alive", %{page: page, frame: frame} do
    connection = PlaywrightEx.Supervisor.connection_name(PlaywrightEx.Supervisor)
    assert :ok = Connection.subscribe_event(connection, self(), page.guid, :dialog)
    assert :ok = Connection.unsubscribe_sync(connection, self(), page.guid)
    assert {:ok, false} = eval(frame.guid, "() => confirm('Automatically dismissed')")
  end

  test "page waiters observe main-frame and newly created child-frame navigation", %{page: page, frame: frame} do
    {:ok, main_wait} = EventWaiter.arm(page.guid, :frame_navigated, timeout: @timeout)
    assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank#navigated", timeout: @timeout)
    assert {:ok, %{params: %{frame: %{guid: main_id}, url: "about:blank#navigated"}}} = EventWaiter.await(main_wait)
    assert main_id == frame.guid

    {:ok, child_wait} =
      EventWaiter.arm(page.guid, :frame_navigated, timeout: @timeout, predicate: &(&1.params.url == "about:srcdoc"))

    assert {:ok, _} =
             eval(frame.guid, """
             () => {
               const child = document.createElement('iframe');
               child.srcdoc = '<p>Child</p>';
               document.body.appendChild(child);
             }
             """)

    assert {:ok, %{params: %{frame: %{guid: child_id}, url: "about:srcdoc"}}} = EventWaiter.await(child_wait)
    assert child_id != frame.guid
    assert {:ok, %{url: "about:srcdoc"}} = Frame.snapshot(child_id)

    {:ok, existing_child_wait} = EventWaiter.arm(page.guid, :frame_navigated, timeout: @timeout)
    assert {:ok, _} = eval(child_id, "() => location.hash = 'updated'")

    assert {:ok, %{params: %{frame: %{guid: ^child_id}, url: "about:srcdoc#updated"}}} =
             EventWaiter.await(existing_child_wait)
  end
end
