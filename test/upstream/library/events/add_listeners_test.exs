defmodule PlaywrightEx.Library.Events.AddListenersTest do
  @upstream "tests/library/events/add-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  describe "EventEmitter tests" do
    @tag skip: "not ported: EventEmitter newListener event"
    test "should work"

    @tag skip: "not ported: EventEmitter.setMaxListeners"
    test "set max listeners test"

    @tag skip: "not ported: EventEmitter newListener event"
    test "Listener order"

    @tag skip: "not ported: EventEmitter checkListener (listener type check)"
    test "listener type check"
  end
end
