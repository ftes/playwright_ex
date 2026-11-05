defmodule PlaywrightEx.Library.Events.ListenerCountTest do
  @upstream "tests/library/events/listener-count.spec.ts"
  # Deviation: plain ExUnit case, these specs test the client EventEmitter without a browser.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  @moduletag upstream: @upstream

  test "Listener count test" do
    loop = EventLoop.get(start_supervised!(EventLoop))
    emitter = EventLoop.with_baton(loop, &EventEmitter.new/0)
    EventEmitter.on(emitter, "foo", fn _ -> nil end)
    EventEmitter.on(emitter, "foo", fn _ -> nil end)
    EventEmitter.on(emitter, "baz", fn _ -> nil end)
    # Allow any type
    EventEmitter.on(emitter, 123, fn _ -> nil end)

    assert EventEmitter.listener_count(emitter, "foo") == 2
    assert EventEmitter.listener_count(emitter, "bar") == 0
    assert EventEmitter.listener_count(emitter, "baz") == 1
    assert EventEmitter.listener_count(emitter, 123) == 1
  end
end
