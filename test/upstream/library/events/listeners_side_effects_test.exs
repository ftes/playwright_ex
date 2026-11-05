defmodule PlaywrightEx.Library.Events.ListenersSideEffectsTest do
  @upstream "tests/library/events/listeners-side-effects.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  # `new EventEmitter()` runs on the one JS thread: the playwright fixture's loop.
  defp new_emitter(playwright), do: EventLoop.with_baton(playwright.loop, &EventEmitter.new/0)

  # Deviation: `e._events` is heap state here (one entry per event name, listeners unwrapped),
  # so its checks go through `event_names/1` and `listeners/2`.
  test "listeners empty check", %{playwright: playwright} do
    e = new_emitter(playwright)

    fl = EventEmitter.listeners(e, "foo")
    assert fl == []
    assert EventEmitter.event_names(e) == []

    fail = fn _ -> flunk("fail called") end
    EventEmitter.on(e, "foo", fail)
    fl = EventEmitter.listeners(e, "foo")

    assert EventEmitter.event_names(e) == ["foo"]
    assert fl == [fail]

    EventEmitter.listeners(e, "bar")

    pass = fn _ -> :ok end
    EventEmitter.on(e, "foo", pass)
    fl = EventEmitter.listeners(e, "foo")

    assert EventEmitter.event_names(e) == ["foo"]
    assert fl == [fail, pass]
  end
end
