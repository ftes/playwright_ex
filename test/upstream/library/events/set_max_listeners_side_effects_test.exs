defmodule PlaywrightEx.Library.Events.SetMaxListenersSideEffectsTest do
  @upstream "tests/library/events/set-max-listeners-side-effects.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  # The emitters live in a heap of their own loop (no driver needed).
  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  test "set max listeners test", %{loop: loop} do
    e = EventLoop.with_baton(loop, fn -> Heap.new_object(EventEmitter) end)

    # expect(!(e._events instanceof Object))  -- JS-only: `_events` is Object.create(null); a Map field here
    assert Heap.map_keys(e, :_events) == []

    EventEmitter.set_max_listeners(e, 5)
    assert Heap.map_keys(e, :_events) == []
  end
end
