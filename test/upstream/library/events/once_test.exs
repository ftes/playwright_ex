defmodule PlaywrightEx.Library.Events.OnceTest do
  @upstream "tests/library/events/once.spec.ts"
  # Deviation: plain ExUnit case, these specs test the client EventEmitter without a browser.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  @moduletag upstream: @upstream

  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop)), test_pid: self()}
  end

  # mustCall(fn): the returned listener reports each call; afterEach is `assert_calls/1`.
  defp must_call(test_pid, fun \\ fn _ -> nil end) do
    ref = make_ref()
    send(test_pid, {:must_call, ref})

    fn arg ->
      fun.(arg)
      send(test_pid, {:called, ref})
    end
  end

  defp assert_calls do
    receive do
      {:must_call, ref} ->
        assert_received {:called, ^ref}
        refute_received {:called, ^ref}
        assert_calls()
    after
      0 -> refute_received {:called, _}
    end
  end

  test "should work", %{loop: loop, test_pid: test_pid} do
    e = EventLoop.with_baton(loop, &EventEmitter.new/0)

    EventEmitter.once(e, "hello", must_call(test_pid))

    EventEmitter.emit(e, "hello", ["a", "b"])
    EventEmitter.emit(e, "hello", ["a", "b"])
    EventEmitter.emit(e, "hello", ["a", "b"])
    EventEmitter.emit(e, "hello", ["a", "b"])

    remove = fn _ -> send(test_pid, :must_not_call) end

    EventEmitter.once(e, "foo", remove)
    EventEmitter.remove_listener(e, "foo", remove)
    EventEmitter.emit(e, "foo")

    EventEmitter.once(e, "e", must_call(test_pid, fn _ -> EventEmitter.emit(e, "e") end))

    EventEmitter.once(e, "e", must_call(test_pid))

    EventEmitter.emit(e, "e")

    # Verify that the listener must be a function (JS `null` is `:null`; TypeError is ArgumentError)
    assert_raise ArgumentError, fn ->
      ee = EventLoop.with_baton(loop, &EventEmitter.new/0)

      EventEmitter.once(ee, "foo", :null)
    end

    refute_received :must_not_call
    assert_calls()
  end

  @tag skip: "not ported: rest parameters (Elixir functions have a fixed arity; emit passes one argument)"
  test "once() has different code paths based on the number of arguments being emitted"
end
