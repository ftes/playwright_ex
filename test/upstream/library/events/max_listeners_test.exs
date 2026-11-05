defmodule PlaywrightEx.Library.Events.MaxListenersTest do
  @upstream "tests/library/events/max-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  # The emitters live in a heap of their own loop (no driver needed).
  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  test "emit maxListeners on e", %{loop: loop} do
    e = EventLoop.with_baton(loop, fn -> Heap.new_object(EventEmitter) end)
    EventEmitter.on(e, "maxListeners", fn _ -> nil end)

    # Should not corrupt the 'maxListeners' queue.
    EventEmitter.set_max_listeners(e, 42)

    # NaN: Elixir floats have none. RangeError is ArgumentError.
    throws_objs = [-1, "and even this"]
    max_error = ~r/^The value of \"n\" is out of range. It must be a non-negative number./

    for obj <- throws_objs do
      assert_raise ArgumentError, max_error, fn ->
        EventEmitter.set_max_listeners(e, obj)
      end
    end

    EventEmitter.emit(e, "maxListeners")
  end
end
