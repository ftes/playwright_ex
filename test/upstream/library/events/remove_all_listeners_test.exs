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

  # expectWrapper: the `removeListener` listener (it gets `{name, listener}`) reports each name to
  # the test process; afterEach is `assert_wrappers/0`.
  defp expect_wrapper(expected) do
    test = self()
    ref = make_ref()
    send(test, {:wrapper, ref, expected})
    fn {name, _listener} -> send(test, {:actual, ref, name}) end
  end

  defp assert_wrappers do
    receive do
      {:wrapper, ref, expected} ->
        assert Enum.sort(actual(ref)) == Enum.sort(expected)
        assert_wrappers()
    after
      0 -> :ok
    end
  end

  defp actual(ref) do
    receive do
      {:actual, ^ref, name} -> [name | actual(ref)]
    after
      0 -> []
    end
  end

  test "listeners", %{loop: loop} do
    ee = new_ee(loop)
    noop = fn _ -> nil end
    EventEmitter.on(ee, "foo", noop)
    EventEmitter.on(ee, "bar", noop)
    EventEmitter.on(ee, "baz", noop)
    EventEmitter.on(ee, "baz", noop)
    foo_listeners = EventEmitter.listeners(ee, "foo")
    bar_listeners = EventEmitter.listeners(ee, "bar")
    baz_listeners = EventEmitter.listeners(ee, "baz")
    EventEmitter.on(ee, "removeListener", expect_wrapper(["bar", "baz", "baz"]))
    EventEmitter.remove_all_listeners(ee, "bar")
    EventEmitter.remove_all_listeners(ee, "baz")

    listeners = EventEmitter.listeners(ee, "foo")
    assert is_list(listeners)
    assert length(listeners) == 1
    assert Enum.at(listeners, 0) == noop

    listeners = EventEmitter.listeners(ee, "bar")
    assert is_list(listeners)
    assert listeners == []
    listeners = EventEmitter.listeners(ee, "baz")
    assert is_list(listeners)
    assert listeners == []

    assert length(foo_listeners) == 1
    assert Enum.at(foo_listeners, 0) == noop
    assert length(bar_listeners) == 1
    assert Enum.at(bar_listeners, 0) == noop
    assert length(baz_listeners) == 2
    assert Enum.at(baz_listeners, 0) == noop
    assert Enum.at(baz_listeners, 1) == noop

    refute EventEmitter.listeners(ee, "bar") == bar_listeners
    refute EventEmitter.listeners(ee, "baz") == baz_listeners

    assert_wrappers()
  end

  test "removeAllListeners removes all listeners", %{loop: loop} do
    ee = new_ee(loop)
    EventEmitter.on(ee, "foo", fn _ -> nil end)
    EventEmitter.on(ee, "bar", fn _ -> nil end)
    EventEmitter.on(ee, "removeListener", expect_wrapper(["foo", "bar", "removeListener"]))
    EventEmitter.on(ee, "removeListener", expect_wrapper(["foo", "bar"]))
    EventEmitter.remove_all_listeners(ee)

    listeners = EventEmitter.listeners(ee, "foo")
    assert is_list(listeners)
    assert listeners == []
    listeners = EventEmitter.listeners(ee, "bar")
    assert is_list(listeners)
    assert listeners == []

    assert_wrappers()
  end

  test "removeAllListeners with no event type", %{loop: loop} do
    ee = new_ee(loop)
    EventEmitter.on(ee, "removeListener", fn _ -> flunk("function should not have been called") end)
    # Check for regression where removeAllListeners() throws when
    # there exists a 'removeListener' listener, but there exists
    # no listeners for the provided event type.
    # (ee as any).removeAllListeners(ee, 'foo'): options 'foo' is truthy without a behavior.
    EventEmitter.remove_all_listeners(ee, ee, %{})
  end

  test "listener count after removeAllListeners", %{loop: loop} do
    test = self()
    ee = new_ee(loop)
    # `expect(expectLength--).toEqual(...)`: the listener reports the count, checked below.
    expect_length = 2
    EventEmitter.on(ee, "removeListener", fn _ -> send(test, {:count, length(EventEmitter.listeners(ee, "baz"))}) end)
    EventEmitter.on(ee, "baz", fn _ -> nil end)
    EventEmitter.on(ee, "baz", fn _ -> nil end)
    EventEmitter.on(ee, "baz", fn _ -> nil end)
    assert length(EventEmitter.listeners(ee, "baz")) == expect_length + 1
    EventEmitter.remove_all_listeners(ee, "baz")
    assert EventEmitter.listeners(ee, "baz") == []

    for length <- expect_length..0//-1, do: assert_received({:count, ^length})
    refute_received {:count, _}
  end

  test "removeAllListeners returns EventEmitter", %{loop: loop} do
    ee = new_ee(loop)
    assert ee == EventEmitter.remove_all_listeners(ee)
  end

  test "removeAllListeners on undefined _events", %{loop: loop} do
    ee = new_ee(loop)
    # ee._events = undefined: a Map field without rows is the empty one.
    Heap.map_clear(ee, :_events)
    assert ee == EventEmitter.remove_all_listeners(ee)
  end
end
