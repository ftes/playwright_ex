defmodule PlaywrightEx.Library.Events.RemoveListenersTest do
  @upstream "tests/library/events/remove-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  # Listeners run in handed-off processes: `common.mustCall`/`mustNotCall` report by message.
  defp listener1(_), do: nil
  defp listener2(_), do: nil

  # `new EventEmitter()` runs on the one JS thread: the playwright fixture's loop.
  defp new_emitter(playwright), do: EventLoop.with_baton(playwright.loop, &EventEmitter.new/0)

  @tag skip: "not ported: EventEmitter removeListener event"
  test "First test"

  test "Second test", %{playwright: playwright} do
    test = self()
    ee = new_emitter(playwright)
    EventEmitter.on(ee, "hello", &listener1/1)
    EventEmitter.on(ee, "removeListener", fn _ -> send(test, :must_not_call) end)
    EventEmitter.remove_listener(ee, "hello", &listener2/1)

    listeners = EventEmitter.listeners(ee, "hello")
    assert length(listeners) == 1
    assert hd(listeners) == (&listener1/1)
    refute_received :must_not_call
  end

  @tag skip: "not ported: EventEmitter removeListener event"
  test "Third test"

  @tag skip: "not ported: EventEmitter removeListener event"
  test "Fourth test"

  test "Fifth test", %{playwright: playwright} do
    test = self()
    ee = new_emitter(playwright)
    listener4 = fn _ -> send(test, :listener4) end

    listener3 = fn _ ->
      send(test, :listener3)
      EventEmitter.remove_listener(ee, "hello", listener4)
    end

    EventEmitter.on(ee, "hello", listener3)
    EventEmitter.on(ee, "hello", listener4)

    # listener4 will still be called although it is removed by listener 3.
    EventEmitter.emit(ee, "hello")
    # This is so because the interal listener array at time of emit
    # was [listener3,listener4]

    # Interal listener array [listener3]
    EventEmitter.emit(ee, "hello")

    assert_received :listener3
    assert_received :listener3
    assert_received :listener4
    refute_received :listener3
    refute_received :listener4
  end

  @tag skip: "not ported: EventEmitter removeListener event"
  test "Sixth test"

  test "Seventh test", %{playwright: playwright} do
    ee = new_emitter(playwright)

    assert ee == EventEmitter.remove_listener(ee, "foo", fn _ -> nil end)
  end

  # Verify that the removed listener must be a function
  @tag skip: "not ported: EventEmitter checkListener (listener type check)"
  test "Eighth test"

  test "Ninth test", %{playwright: playwright} do
    ee = new_emitter(playwright)
    listener = fn _ -> nil end
    # ee._events = undefined: `_events` is heap state, a fresh emitter has none.
    e = EventEmitter.remove_listener(ee, "foo", listener)
    assert e == ee
  end

  # Deviation: `ee._events.foo` (Node stores a single listener unwrapped) is heap state here,
  # checked through `listeners/2`.
  test "Tenth test", %{playwright: playwright} do
    ee = new_emitter(playwright)

    EventEmitter.on(ee, "foo", &listener1/1)
    EventEmitter.on(ee, "foo", &listener2/1)
    listeners = EventEmitter.listeners(ee, "foo")
    assert listeners == [&listener1/1, &listener2/1]

    EventEmitter.remove_listener(ee, "foo", &listener1/1)
    assert EventEmitter.listeners(ee, "foo") == [&listener2/1]

    EventEmitter.on(ee, "foo", &listener1/1)
    listeners = EventEmitter.listeners(ee, "foo")
    assert listeners == [&listener2/1, &listener1/1]

    EventEmitter.remove_listener(ee, "foo", &listener1/1)
    assert EventEmitter.listeners(ee, "foo") == [&listener2/1]
  end
end
