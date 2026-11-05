defmodule PlaywrightEx.Library.Events.RemoveAllListenersTest do
  @upstream "tests/library/events/remove-all-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  # The emitters live in a heap of their own loop (no driver needed).
  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  defp new_ee(loop), do: EventLoop.with_baton(loop, fn -> Heap.new_object(EventEmitter) end)

  @tag skip: "not ported: EventEmitter 'removeListener' meta event (Client.EventEmitter does not emit it)"
  test "listeners"

  @tag skip: "not ported: EventEmitter 'removeListener' meta event (Client.EventEmitter does not emit it)"
  test "removeAllListeners removes all listeners"

  test "removeAllListeners with no event type", %{loop: loop} do
    ee = new_ee(loop)
    EventEmitter.on(ee, "removeListener", fn _ -> flunk("function should not have been called") end)
    # Check for regression where removeAllListeners() throws when
    # there exists a 'removeListener' listener, but there exists
    # no listeners for the provided event type.
    # (ee as any).removeAllListeners(ee, 'foo'): options 'foo' is truthy without a behavior.
    EventEmitter.remove_all_listeners(ee, ee, %{})
  end

  @tag skip: "not ported: EventEmitter 'removeListener' meta event (Client.EventEmitter does not emit it)"
  test "listener count after removeAllListeners"

  test "removeAllListeners returns EventEmitter", %{loop: loop} do
    ee = new_ee(loop)
    assert ee == EventEmitter.remove_all_listeners(ee)
  end

  @tag skip: "not ported: JS-only: assigns the private `_events` field (ee._events = undefined)"
  test "removeAllListeners on undefined _events"
end
