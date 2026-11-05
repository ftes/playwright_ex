defmodule PlaywrightEx.Library.Events.PrependTest do
  @upstream "tests/library/events/prepend.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  # `new EventEmitter()` runs on the one JS thread: the playwright fixture's loop.
  defp new_emitter(playwright), do: EventLoop.with_baton(playwright.loop, &EventEmitter.new/0)

  test "EventEmitter functionality", %{playwright: playwright} do
    test = self()
    my_ee = new_emitter(playwright)
    # Listeners run in handed-off processes: `m++` is tracked by the order of messages.
    # This one comes last.
    EventEmitter.on(my_ee, "foo", fn _ -> send(test, {:m, 2}) end)
    # This one comes second.
    EventEmitter.prepend_listener(my_ee, "foo", fn _ -> send(test, {:m, 1}) end)
    # This one comes first.
    EventEmitter.prepend_once_listener(my_ee, "foo", fn _ -> send(test, {:m, 0}) end)

    EventEmitter.emit(my_ee, "foo")
    assert for(_ <- 1..3, do: receive(do: ({:m, m} -> m), after: (0 -> nil))) == [0, 1, 2]
  end

  @tag skip: "not ported: EventEmitter checkListener (listener type check)"
  test "Verify that the listener must be a function"
end
