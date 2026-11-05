defmodule PlaywrightEx.Library.Events.SymbolsTest do
  @upstream "tests/library/events/symbols.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  # `events/utils` re-exports the client EventEmitter (no facade): it is called directly, on a loop of its own.
  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  test "should support symbols", %{loop: loop} do
    ee = EventLoop.with_baton(loop, &EventEmitter.new/0)
    # Symbol('foo')
    foo = make_ref()
    listener = fn _ -> nil end

    EventEmitter.on(ee, foo, listener)
    assert length(EventEmitter.listeners(ee, foo)) == 1
    assert hd(EventEmitter.listeners(ee, foo)) == listener

    EventEmitter.emit(ee, foo)

    EventEmitter.remove_all_listeners(ee)
    assert EventEmitter.listeners(ee, foo) == []

    EventEmitter.on(ee, foo, listener)
    assert length(EventEmitter.listeners(ee, foo)) == 1
    assert hd(EventEmitter.listeners(ee, foo)) == listener

    EventEmitter.remove_listener(ee, foo, listener)
    assert EventEmitter.listeners(ee, foo) == []
  end
end
