defmodule PlaywrightEx.Library.Events.RemoveListenersTest do
  @upstream "tests/library/events/remove-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  # Listeners run in handed-off processes: `common.mustCall`/`mustNotCall` report by message,
  # what they check is sent to the test process. `removeListener` listeners get `{name, cb}`.
  defp listener1(_), do: nil
  defp listener2(_), do: nil

  # `new EventEmitter()` runs on the one JS thread: the playwright fixture's loop.
  defp new_emitter(playwright), do: EventLoop.with_baton(playwright.loop, &EventEmitter.new/0)

  # common.mustCall(fn, exact): the returned listener reports each call; afterEach is `assert_calls/0`.
  defp must_call(fun \\ fn _ -> nil end, exact \\ 1) do
    test = self()
    ref = make_ref()
    send(test, {:must_call, ref, exact})

    fn arg ->
      fun.(arg)
      send(test, {:called, ref})
    end
  end

  defp assert_calls do
    receive do
      {:must_call, ref, exact} ->
        assert calls(ref) == exact
        assert_calls()
    after
      0 -> refute_received {:called, _}
    end
  end

  defp calls(ref) do
    receive do
      {:called, ^ref} -> 1 + calls(ref)
    after
      0 -> 0
    end
  end

  test "First test", %{playwright: playwright} do
    test = self()
    ee = new_emitter(playwright)
    EventEmitter.on(ee, "hello", &listener1/1)

    EventEmitter.on(
      ee,
      "removeListener",
      must_call(fn {name, cb} -> send(test, {:remove_listener, name, cb}) end)
    )

    EventEmitter.remove_listener(ee, "hello", &listener1/1)
    listeners = EventEmitter.listeners(ee, "hello")
    assert is_list(listeners)
    assert listeners == []

    assert_received {:remove_listener, "hello", cb}
    assert cb == (&listener1/1)
    assert_calls()
  end

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
    assert_calls()
  end

  test "Third test", %{playwright: playwright} do
    test = self()
    ee = new_emitter(playwright)
    EventEmitter.on(ee, "hello", &listener1/1)
    EventEmitter.on(ee, "hello", &listener2/1)

    EventEmitter.once(
      ee,
      "removeListener",
      must_call(fn {name, cb} -> send(test, {:remove_listener, name, cb, EventEmitter.listeners(ee, "hello")}) end)
    )

    EventEmitter.remove_listener(ee, "hello", &listener1/1)
    assert_received {:remove_listener, "hello", cb, listeners}
    assert cb == (&listener1/1)
    assert listeners == [&listener2/1]
    listeners = EventEmitter.listeners(ee, "hello")
    assert is_list(listeners)
    assert length(listeners) == 1
    assert Enum.at(listeners, 0) == (&listener2/1)

    EventEmitter.once(
      ee,
      "removeListener",
      must_call(fn {name, cb} -> send(test, {:remove_listener, name, cb, EventEmitter.listeners(ee, "hello")}) end)
    )

    EventEmitter.remove_listener(ee, "hello", &listener2/1)
    assert_received {:remove_listener, "hello", cb, listeners}
    assert cb == (&listener2/1)
    assert listeners == []
    listeners = EventEmitter.listeners(ee, "hello")
    assert is_list(listeners)
    assert listeners == []
    assert_calls()
  end

  test "Fourth test", %{playwright: playwright} do
    test = self()
    ee = new_emitter(playwright)

    # A listener that throws is only logged here (handed off): it reports instead.
    remove1 = fn _ -> send(test, {:must_not_call, "remove1 should not have been called"}) end

    remove2 = fn _ -> send(test, {:must_not_call, "remove2 should not have been called"}) end

    EventEmitter.on(
      ee,
      "removeListener",
      must_call(
        fn {_name, cb} ->
          if cb == remove1 do
            EventEmitter.remove_listener(ee, "quux", remove2)
            EventEmitter.emit(ee, "quux")
          end
        end,
        2
      )
    )

    EventEmitter.on(ee, "quux", remove1)
    EventEmitter.on(ee, "quux", remove2)
    EventEmitter.remove_listener(ee, "quux", remove1)

    refute_received {:must_not_call, _}
    assert_calls()
  end

  test "Fifth test", %{playwright: playwright} do
    ee = new_emitter(playwright)
    listener4 = must_call()
    listener3 = must_call(fn _ -> EventEmitter.remove_listener(ee, "hello", listener4) end, 2)

    EventEmitter.on(ee, "hello", listener3)
    EventEmitter.on(ee, "hello", listener4)

    # listener4 will still be called although it is removed by listener 3.
    EventEmitter.emit(ee, "hello")
    # This is so because the interal listener array at time of emit
    # was [listener3,listener4]

    # Interal listener array [listener3]
    EventEmitter.emit(ee, "hello")

    assert_calls()
  end

  test "Sixth test", %{playwright: playwright} do
    test = self()
    ee = new_emitter(playwright)

    EventEmitter.once(ee, "hello", &listener1/1)

    EventEmitter.on(
      ee,
      "removeListener",
      must_call(fn {event_name, listener} -> send(test, {:remove_listener, event_name, listener}) end)
    )

    EventEmitter.emit(ee, "hello")

    assert_received {:remove_listener, "hello", listener}
    assert listener == (&listener1/1)
    assert_calls()
  end

  test "Seventh test", %{playwright: playwright} do
    ee = new_emitter(playwright)

    assert ee == EventEmitter.remove_listener(ee, "foo", fn _ -> nil end)
    assert_calls()
  end

  # Verify that the removed listener must be a function
  # JS `null` is `:null`; TypeError is ArgumentError.
  test "Eighth test", %{playwright: playwright} do
    assert_raise ArgumentError, ~r/^The "listener" argument must be of type Function\. Received type object$/, fn ->
      ee = new_emitter(playwright)

      EventEmitter.remove_listener(ee, "foo", :null)
    end

    assert_calls()
  end

  test "Ninth test", %{playwright: playwright} do
    ee = new_emitter(playwright)
    listener = fn _ -> nil end
    # ee._events = undefined: a Map field without rows is the empty one.
    Heap.map_clear(ee, :_events)
    e = EventEmitter.remove_listener(ee, "foo", listener)
    assert e == ee
    assert_calls()
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
    assert_calls()
  end
end
