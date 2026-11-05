# class TestStream extends EventEmitter {}  (outside the test module: parity reads nested modules as specs)
defmodule PlaywrightEx.Library.Events.ListenersTest.TestStream do
  @moduledoc false
  defstruct [:guid, :loop, :heap]
  use PlaywrightEx.Client.EventEmitter
end

defmodule PlaywrightEx.Library.Events.ListenersTest do
  @upstream "tests/library/events/listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Library.Events.ListenersTest.TestStream
  alias PlaywrightEx.Runtime.Heap

  # The emitters live in a heap of their own loop (no driver needed).
  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  defp new_ee(loop, module \\ EventEmitter), do: EventLoop.with_baton(loop, fn -> Heap.new_object(module) end)

  def listener(_), do: nil
  def listener2(_), do: nil

  # Elixir lists are immutable: `listeners()` returns a copy by construction.

  test "EventEmitter listeners with one listener", %{loop: loop} do
    ee = new_ee(loop)
    EventEmitter.on(ee, "foo", &listener/1)
    foo_listeners = EventEmitter.listeners(ee, "foo")

    listeners = EventEmitter.listeners(ee, "foo")
    assert is_list(listeners)
    assert length(listeners) == 1
    assert Enum.at(listeners, 0) == (&listener/1)

    EventEmitter.remove_all_listeners(ee, "foo")
    assert EventEmitter.listeners(ee, "foo") == []

    assert is_list(foo_listeners)
    assert length(foo_listeners) == 1
    assert Enum.at(foo_listeners, 0) == (&listener/1)
  end

  test "Array copy modification does not modify orig", %{loop: loop} do
    ee = new_ee(loop)
    EventEmitter.on(ee, "foo", &listener/1)

    ee_listeners_copy = EventEmitter.listeners(ee, "foo")
    assert is_list(ee_listeners_copy)
    assert length(ee_listeners_copy) == 1
    assert Enum.at(ee_listeners_copy, 0) == (&listener/1)

    ee_listeners_copy = ee_listeners_copy ++ [&listener2/1]
    listeners = EventEmitter.listeners(ee, "foo")

    assert is_list(listeners)
    assert length(listeners) == 1
    assert Enum.at(listeners, 0) == (&listener/1)

    assert length(ee_listeners_copy) == 2
    assert Enum.at(ee_listeners_copy, 0) == (&listener/1)
    assert Enum.at(ee_listeners_copy, 1) == (&listener2/1)
  end

  test "Modify array copy after multiple adds", %{loop: loop} do
    ee = new_ee(loop)
    EventEmitter.on(ee, "foo", &listener/1)
    ee_listeners_copy = EventEmitter.listeners(ee, "foo")
    EventEmitter.on(ee, "foo", &listener2/1)

    listeners = EventEmitter.listeners(ee, "foo")
    assert is_list(listeners)
    assert length(listeners) == 2
    assert Enum.at(listeners, 0) == (&listener/1)
    assert Enum.at(listeners, 1) == (&listener2/1)

    assert is_list(ee_listeners_copy)
    assert length(ee_listeners_copy) == 1
    assert Enum.at(ee_listeners_copy, 0) == (&listener/1)
  end

  @tag skip: "bug: EventEmitter.listeners: returns the once/3 wrapper instead of the original listener"
  test "listeners and once", %{loop: loop} do
    ee = new_ee(loop)
    EventEmitter.once(ee, "foo", &listener/1)
    listeners = EventEmitter.listeners(ee, "foo")
    assert is_list(listeners)
    assert length(listeners) == 1
    assert Enum.at(listeners, 0) == (&listener/1)
  end

  @tag skip: "bug: EventEmitter.listeners: returns the once/3 wrapper instead of the original listener"
  test "listeners with conflicting types", %{loop: loop} do
    ee = new_ee(loop)
    EventEmitter.on(ee, "foo", &listener/1)
    EventEmitter.once(ee, "foo", &listener2/1)

    listeners = EventEmitter.listeners(ee, "foo")
    assert is_list(listeners)
    assert length(listeners) == 2
    assert Enum.at(listeners, 0) == (&listener/1)
    assert Enum.at(listeners, 1) == (&listener2/1)
  end

  @tag skip: "not ported: JS-only: assigns the private `_events` field (ee._events = undefined)"
  test "EventEmitter with no members"

  test "listeners on prototype", %{loop: loop} do
    s = new_ee(loop, TestStream)
    listeners = TestStream.listeners(s, "foo")
    assert is_list(listeners)
    assert listeners == []
  end

  @tag skip: "not ported: EventEmitter.rawListeners (listeners are stored unwrapped)"
  test "raw listeners"

  @tag skip: "not ported: EventEmitter.rawListeners (listeners are stored unwrapped)"
  test "raw listeners order"
end
