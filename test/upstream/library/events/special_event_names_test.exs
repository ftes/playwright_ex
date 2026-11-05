defmodule PlaywrightEx.Library.Events.SpecialEventNamesTest do
  @upstream "tests/library/events/special-event-names.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  # `new EventEmitter()` runs on the one JS thread: the playwright fixture's loop.
  defp new_emitter(playwright), do: EventLoop.with_baton(playwright.loop, &EventEmitter.new/0)

  # Deviation: `ee._events` is heap state here (no prototype), so its checks go through
  # `listeners/2`: `Object.prototype` names have no listeners.
  test "should support special event names", %{playwright: playwright} do
    ee = new_emitter(playwright)
    handler = fn _ -> nil end

    assert EventEmitter.event_names(ee) == []
    assert EventEmitter.listeners(ee, "hasOwnProperty") == []
    assert EventEmitter.listeners(ee, "toString") == []

    EventEmitter.on(ee, "__defineGetter__", handler)
    EventEmitter.on(ee, "toString", handler)
    EventEmitter.on(ee, "__proto__", handler)

    assert Enum.at(EventEmitter.event_names(ee), 0) == "__defineGetter__"
    assert Enum.at(EventEmitter.event_names(ee), 1) == "toString"

    assert length(EventEmitter.listeners(ee, "__defineGetter__")) == 1
    assert hd(EventEmitter.listeners(ee, "__defineGetter__")) == handler
    assert length(EventEmitter.listeners(ee, "toString")) == 1
    assert hd(EventEmitter.listeners(ee, "toString")) == handler
  end
end
