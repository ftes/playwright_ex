defmodule PlaywrightEx.Library.Events.RemoveAllListenersWaitTest do
  @upstream "tests/library/events/remove-all-listeners-wait.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import ExUnit.CaptureLog

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.Promise

  # The emitters live in a heap of their own loop (no driver needed).
  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  defp new_ee(loop), do: EventLoop.with_baton(loop, fn -> Heap.new_object(EventEmitter) end)

  # `new ManualPromise()`. A call without `await` is `Promise.async/1` (it returns at the
  # call's first suspension point).
  defp manual_promise(loop), do: EventLoop.with_baton(loop, fn -> Promise.new() end)

  # Client calls run under the baton (the facade takes it).
  defp remove_all_listeners(ee, type, options),
    do: EventLoop.with_baton(ee.loop, fn -> EventEmitter.remove_all_listeners(ee, type, options) end)

  test "should not throw with ignoreErrors", %{loop: loop} do
    ee = new_ee(loop)
    release_handler = manual_promise(loop)

    EventEmitter.on(ee, "console", fn _ ->
      Promise.await(release_handler)
      raise "Error in console handler"
    end)

    EventEmitter.emit(ee, "console")

    log =
      capture_log(fn ->
        remove_all_listeners(ee, "console", %{behavior: "ignoreErrors"})
        Promise.resolve(release_handler, nil)
        # Let the handler run to its end.
        Process.sleep(100)
      end)

    refute log =~ "Error in console handler"
  end

  test "should wait", %{loop: loop} do
    ee = new_ee(loop)
    release_handler = manual_promise(loop)
    test = self()

    EventEmitter.on(ee, "console", fn _ ->
      Promise.await(release_handler)
      send(test, {:value, 42})
    end)

    EventEmitter.emit(ee, "console")
    remove_promise = Promise.async(fn -> remove_all_listeners(ee, "console", %{behavior: "wait"}) end)
    Promise.resolve(release_handler, nil)
    Promise.await(remove_promise)
    assert_received {:value, 42}
  end

  test "should wait all", %{loop: loop} do
    ee = new_ee(loop)
    release_handler = manual_promise(loop)
    test = self()

    EventEmitter.on(ee, "a", fn _ ->
      Promise.await(release_handler)
      send(test, {:value, 42})
    end)

    EventEmitter.on(ee, "b", fn _ ->
      Promise.await(release_handler)
      send(test, {:value, 43})
    end)

    EventEmitter.emit(ee, "a")
    EventEmitter.emit(ee, "b")
    remove_promise = Promise.async(fn -> remove_all_listeners(ee, nil, %{behavior: "wait"}) end)
    Promise.resolve(release_handler, nil)
    Promise.await(remove_promise)
    assert {:messages, [{:value, 42}, {:value, 43}]} = Process.info(self(), :messages)
  end

  test "wait should throw", %{loop: loop} do
    ee = new_ee(loop)
    release_handler = manual_promise(loop)

    EventEmitter.on(ee, "console", fn _ ->
      Promise.await(release_handler)
      raise "Error in handler"
    end)

    EventEmitter.emit(ee, "console")
    remove_promise = Promise.async(fn -> remove_all_listeners(ee, "console", %{behavior: "wait"}) end)
    Promise.resolve(release_handler, nil)
    assert_raise RuntimeError, ~r/Error in handler/, fn -> Promise.await(remove_promise) end
  end
end
