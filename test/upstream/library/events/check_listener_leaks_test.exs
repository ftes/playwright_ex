defmodule PlaywrightEx.Library.Events.CheckListenerLeaksTest do
  @upstream "tests/library/events/check-listener-leaks.spec.ts"
  # Not async: `defaultMaxListeners` is process-wide, as in Node.
  use PlaywrightEx.UpstreamCase, async: false

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  # The leak warnings are logged (upstream prints them unless under test).
  @moduletag :capture_log

  # The emitters live in a heap of their own loop (no driver needed). Upstream leaves
  # `defaultMaxListeners` changed; restored here, as test order is random.
  setup do
    on_exit(fn -> EventEmitter.set_default_max_listeners(10) end)
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  defp new_ee(loop), do: EventLoop.with_baton(loop, fn -> Heap.new_object(EventEmitter) end)

  defp must_not_call, do: fn _ -> flunk("function should not have been called") end

  # `e._events[type].warned` (a property of the listener array) is the `_warned` Map field.
  defp warned?(e, type), do: Heap.map_get(e, :_warned, type) != nil

  test "defaultMaxListeners", %{loop: loop} do
    e = new_ee(loop)

    for _ <- 1..10, do: EventEmitter.on(e, "default", must_not_call())

    refute warned?(e, "default")
    EventEmitter.on(e, "default", must_not_call())
    assert warned?(e, "default")

    EventEmitter.set_max_listeners(e, 5)
    for _ <- 1..5, do: EventEmitter.on(e, "specific", must_not_call())

    refute warned?(e, "specific")
    EventEmitter.on(e, "specific", must_not_call())
    assert warned?(e, "specific")

    # only one
    EventEmitter.set_max_listeners(e, 1)
    EventEmitter.on(e, "only one", must_not_call())
    refute warned?(e, "only one")
    EventEmitter.on(e, "only one", must_not_call())
    assert warned?(e, "only one")

    # unlimited
    EventEmitter.set_max_listeners(e, 0)
    for _ <- 1..1000, do: EventEmitter.on(e, "unlimited", must_not_call())

    refute warned?(e, "unlimited")
  end

  test "process-wide", %{loop: loop} do
    EventEmitter.set_default_max_listeners(42)
    e = new_ee(loop)

    for _ <- 1..42, do: EventEmitter.on(e, "fortytwo", must_not_call())

    refute warned?(e, "fortytwo")
    EventEmitter.on(e, "fortytwo", must_not_call())
    assert warned?(e, "fortytwo")
    Heap.map_delete(e, :_warned, "fortytwo")

    EventEmitter.set_default_max_listeners(44)
    EventEmitter.on(e, "fortytwo", must_not_call())
    refute warned?(e, "fortytwo")
    EventEmitter.on(e, "fortytwo", must_not_call())
    assert warned?(e, "fortytwo")
  end

  test "_maxListeners still has precedence over defaultMaxListeners", %{loop: loop} do
    EventEmitter.set_default_max_listeners(42)
    e = new_ee(loop)
    EventEmitter.set_max_listeners(e, 1)
    EventEmitter.on(e, "uno", must_not_call())
    refute warned?(e, "uno")
    EventEmitter.on(e, "uno", must_not_call())
    assert warned?(e, "uno")
  end
end
