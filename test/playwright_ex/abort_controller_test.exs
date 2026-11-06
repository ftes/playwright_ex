defmodule PlaywrightEx.AbortControllerTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.AbortError
  alias PlaywrightEx.AbortSignal
  alias PlaywrightEx.Runtime.ProcessOwner
  alias PlaywrightEx.Runtime.Promise

  test "a new signal is not aborted; abort sets the reason once" do
    controller = AbortController.new()
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

  test "the default reason is an AbortError; an exception reason is raised as is" do
    controller = AbortController.new()
    AbortController.abort(controller)
    assert %AbortError{message: "This operation was aborted"} = AbortSignal.reason(AbortController.signal(controller))

    controller = AbortController.new()
    AbortController.abort(controller, %RuntimeError{message: "stop"})
    assert_raise RuntimeError, "stop", fn -> AbortSignal.throw_if_aborted(AbortController.signal(controller)) end
  end

  test "listeners run in the aborting process; a late listener does not run" do
    controller = AbortController.new()
    signal = AbortController.signal(controller)
    test = self()
    AbortSignal.add_event_listener(signal, "abort", fn -> send(test, {:early, self()}) end)

    aborter = Task.async(fn -> AbortController.abort(controller) && self() end)
    aborter_pid = Task.await(aborter)
    assert_received {:early, ^aborter_pid}

    AbortSignal.add_event_listener(signal, "abort", fn -> send(test, {:late, self()}) end)
    refute_received {:late, _}
  end

  test "a listener added after a check of `aborted` runs when an abort came in between" do
    controller = AbortController.new()
    signal = AbortController.signal(controller)
    test = self()
    refute AbortSignal.aborted(signal)
    # Another process aborts between the caller's check and its add (one synchronous section in JS).
    Task.await(Task.async(fn -> AbortController.abort(controller) end))
    AbortSignal.add_event_listener_after_check(signal, fn -> send(test, :ran) end)
    assert_received :ran
  end

  test "a signal's rows are freed when its creator exits" do
    signal = Task.await(Task.async(fn -> AbortController.signal(AbortController.new()) end))
    # The owner handles the creator's exit asynchronously.
    :sys.get_state(AbortSignal)
    refute AbortSignal.aborted(signal)
    assert :ets.select(AbortSignal, [{{{signal.id, :_, :_}, :_}, [], [true]}]) == []
  end

  test "any process aborts a signal another process awaits through a listener" do
    controller = AbortController.new()
    signal = AbortController.signal(controller)
    # A latch: awaitable from any process.
    promise = Promise.new(ProcessOwner.owner())
    AbortSignal.add_event_listener(signal, "abort", fn -> Promise.reject(promise, AbortSignal.reason(signal)) end)

    waiter =
      Task.async(fn ->
        try do
          Promise.await(promise)
        rescue
          e -> e
        end
      end)

    Task.await(
      Task.async(fn -> AbortController.abort(controller, %RuntimeError{message: "from a task"}) end),
      :infinity
    )

    assert %RuntimeError{message: "from a task"} = Task.await(waiter, :infinity)
  end

  test "listeners run once, in order; removed listeners do not run" do
    controller = AbortController.new()
    signal = AbortController.signal(controller)
    test = self()
    first = fn -> send(test, :first) end
    second = fn -> send(test, :second) end
    removed = fn -> send(test, :removed) end

    AbortSignal.add_event_listener(signal, "abort", first, once: true)
    AbortSignal.add_event_listener(signal, :abort, second)
    AbortSignal.add_event_listener(signal, "abort", first)
    AbortSignal.add_event_listener(signal, "abort", removed)
    AbortSignal.remove_event_listener(signal, "abort", removed)

    AbortController.abort(controller)
    AbortController.abort(controller)
    assert_received :first
    assert_received :second
    refute_received :first
    refute_received :removed
    assert {:messages, []} = Process.info(self(), :messages)
  end
end
