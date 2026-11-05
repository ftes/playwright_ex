defmodule PlaywrightEx.AbortControllerTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.AbortError
  alias PlaywrightEx.AbortSignal
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise

  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  defp baton(loop, fun), do: EventLoop.with_baton(loop, fun)

  test "a new signal is not aborted; abort sets the reason once", %{loop: loop} do
    controller = AbortController.new(%{loop: loop})
    signal = AbortController.signal(controller)
    refute AbortSignal.aborted(signal)
    assert AbortSignal.reason(signal) == nil
    assert AbortSignal.throw_if_aborted(signal) == :ok

    assert AbortController.abort(controller, "first") == :ok
    AbortController.abort(controller, "second")
    assert AbortSignal.aborted(signal)
    assert AbortSignal.reason(signal) == "first"
    assert_raise AbortError, fn -> AbortSignal.throw_if_aborted(signal) end
  end

  test "the default reason is an AbortError; an exception reason is raised as is", %{loop: loop} do
    controller = AbortController.new(%{loop: loop})
    AbortController.abort(controller)
    assert %AbortError{message: "This operation was aborted"} = AbortSignal.reason(AbortController.signal(controller))

    controller = AbortController.new(%{loop: loop})
    AbortController.abort(controller, %RuntimeError{message: "stop"})
    assert_raise RuntimeError, "stop", fn -> AbortSignal.throw_if_aborted(AbortController.signal(controller)) end
  end

  test "new/0 under the baton uses the current loop", %{loop: loop} do
    controller = baton(loop, fn -> AbortController.new() end)
    assert AbortController.signal(controller).loop == loop
  end

  test "any process aborts a signal another process awaits through a listener", %{loop: loop} do
    controller = AbortController.new(%{loop: loop})
    signal = AbortController.signal(controller)

    promise =
      baton(loop, fn ->
        promise = Promise.new()
        AbortSignal.add_event_listener(signal, "abort", fn -> Promise.reject(promise, AbortSignal.reason(signal)) end)
        promise
      end)

    waiter =
      Task.async(fn ->
        try do
          Promise.await(promise)
        rescue
          e -> e
        end
      end)

    Task.await(Task.async(fn -> AbortController.abort(controller, %RuntimeError{message: "from a task"}) end))
    assert %RuntimeError{message: "from a task"} = Task.await(waiter)
  end

  test "listeners run once, in order; removed and late listeners do not run", %{loop: loop} do
    controller = AbortController.new(%{loop: loop})
    signal = AbortController.signal(controller)
    test = self()
    first = fn -> send(test, :first) end
    second = fn -> send(test, :second) end
    removed = fn -> send(test, :removed) end

    baton(loop, fn ->
      AbortSignal.add_event_listener(signal, "abort", first, once: true)
      AbortSignal.add_event_listener(signal, :abort, second)
      AbortSignal.add_event_listener(signal, "abort", first)
      AbortSignal.add_event_listener(signal, "abort", removed)
      AbortSignal.remove_event_listener(signal, "abort", removed)
    end)

    AbortController.abort(controller)
    AbortSignal.add_event_listener(signal, "abort", fn -> send(test, :late) end)
    AbortController.abort(controller)
    assert_received :first
    assert_received :second
    refute_received :first
    refute_received :removed
    refute_received :late
    assert {:messages, []} = Process.info(self(), :messages)
  end
end
