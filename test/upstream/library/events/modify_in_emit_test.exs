defmodule PlaywrightEx.Library.Events.ModifyInEmitTest do
  @upstream "tests/library/events/modify-in-emit.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  # `events/utils` re-exports the client EventEmitter (no facade): it is called directly, on a loop of its own.
  # Upstream shares `e` and `callbacks_called` between the tests (run in order); here each test gets its own.
  setup do
    loop = EventLoop.get(start_supervised!(EventLoop))
    e = EventLoop.with_baton(loop, &EventEmitter.new/0)
    {:ok, called} = Agent.start_link(fn -> [] end)
    push = fn name -> Agent.update(called, &(&1 ++ [name])) end

    # The callbacks remove themselves: `{id, fun}` listeners (see EventEmitter).
    callback2 = {:callback2, fn _ -> push.("callback2") && EventEmitter.remove_listener(e, "foo", :callback2) end}
    callback3 = {:callback3, fn _ -> push.("callback3") && EventEmitter.remove_listener(e, "foo", :callback3) end}

    callback1 =
      {:callback1,
       fn _ ->
         push.("callback1")
         EventEmitter.on(e, "foo", callback2)
         EventEmitter.on(e, "foo", callback3)
         EventEmitter.remove_listener(e, "foo", :callback1)
       end}

    %{
      e: e,
      callbacks_called: fn -> Agent.get(called, & &1) end,
      callback1: callback1,
      callback2: callback2,
      callback3: callback3
    }
  end

  test "add and remove listeners", %{e: e, callbacks_called: callbacks_called} = ctx do
    EventEmitter.on(e, "foo", ctx.callback1)
    assert length(EventEmitter.listeners(e, "foo")) == 1

    EventEmitter.emit(e, "foo")
    assert length(EventEmitter.listeners(e, "foo")) == 2
    assert callbacks_called.() == ["callback1"]

    EventEmitter.emit(e, "foo")
    assert EventEmitter.listeners(e, "foo") == []
    assert callbacks_called.() == ["callback1", "callback2", "callback3"]

    EventEmitter.emit(e, "foo")
    assert EventEmitter.listeners(e, "foo") == []
    assert callbacks_called.() == ["callback1", "callback2", "callback3"]

    EventEmitter.on(e, "foo", ctx.callback1)
    EventEmitter.on(e, "foo", ctx.callback2)
    assert length(EventEmitter.listeners(e, "foo")) == 2
    EventEmitter.remove_all_listeners(e, "foo")
    assert EventEmitter.listeners(e, "foo") == []
  end

  test "removing callbacks in emit", %{e: e, callbacks_called: callbacks_called} = ctx do
    # Verify that removing callbacks while in emit allows emits to propagate to
    # all listeners
    EventEmitter.on(e, "foo", ctx.callback2)
    EventEmitter.on(e, "foo", ctx.callback3)
    assert length(EventEmitter.listeners(e, "foo")) == 2
    EventEmitter.emit(e, "foo")
    assert callbacks_called.() == ["callback2", "callback3"]
    assert EventEmitter.listeners(e, "foo") == []
  end
end
