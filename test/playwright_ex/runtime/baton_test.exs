defmodule PlaywrightEx.Runtime.BatonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PlaywrightEx.Runtime.Baton
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.Promise

  defmodule Obj do
    @moduledoc false
    defstruct [:guid, :baton]
  end

  setup do
    pid = start_supervised!(Baton)
    %{baton: Baton.get(pid)}
  end

  test "with_baton/2 is reentrant and releases afterwards", %{baton: baton} do
    refute Baton.held?()
    assert Baton.with_baton(baton, fn -> Baton.with_baton(baton, fn -> Baton.held?() end) end)
    refute Baton.held?()
  end

  test "heap fields, sets and maps", %{baton: baton} do
    obj = Heap.new_object(baton, Obj)
    assert Heap.get(obj, :_x) == nil
    Heap.put(obj, :_x, 1)
    assert Heap.update(obj, :_x, &(&1 + 1)) == 2
    Heap.set_add(obj, :_set, :a)
    Heap.set_add(obj, :_set, :b)
    Heap.set_add(obj, :_set, :a)
    assert Heap.get(obj, :_set) == [:a, :b]
    Heap.map_set(obj, :_map, "k", "v")
    assert Heap.map_get(obj, :_map, "k") == "v"
    assert Heap.map_values(obj, :_map) == ["v"]
    Heap.map_clear(obj, :_map)
    assert Heap.map_values(obj, :_map) == []
    assert_raise RuntimeError, ~r/value object/, fn -> Heap.put(%Obj{}, :_x, 1) end
  end

  test "await releases the baton until the promise settles", %{baton: baton} do
    promise = Promise.new(baton)
    waiter = Task.async(fn -> Promise.await(promise) end)

    # The waiter does not hold the baton while suspended: we can take it and settle.
    Process.sleep(20)
    Baton.with_baton(baton, fn -> Promise.resolve(promise, :done) end)
    assert Task.await(waiter) == :done
    # Settled promises are read without the baton.
    assert Promise.await(promise) == :done
  end

  test "rejections raise in the awaiter", %{baton: baton} do
    promise = Promise.rejected(baton, %ArgumentError{message: "nope"})
    assert_raise ArgumentError, "nope", fn -> Promise.await(promise) end
  end

  test "async/2 returns at the callee's first await, like calling an async function without await", %{baton: baton} do
    gate = Promise.new(baton)
    log = Heap.new_object(baton, Obj)
    Heap.put(log, :_log, [])

    promise =
      Promise.async(baton, fn ->
        Heap.update(log, :_log, &(&1 ++ [:started]))
        Promise.await(gate)
        Heap.update(log, :_log, &(&1 ++ [:resumed]))
        :result
      end)

    assert Heap.get(log, :_log) == [:started]
    Baton.with_baton(baton, fn -> Promise.resolve(gate, nil) end)
    assert Promise.await(promise) == :result
    assert Heap.get(log, :_log) == [:started, :resumed]
  end

  test "settled awaiters resume before queued macrotasks (microtask order)", %{baton: baton} do
    test = self()
    promise = Promise.new(baton)

    waiter =
      Task.async(fn ->
        Promise.await(promise)
        send(test, {:order, :microtask})
      end)

    Process.sleep(20)

    Baton.with_baton(baton, fn ->
      Baton.post(baton, fn -> send(test, {:order, :macrotask}) end)
      Promise.resolve(promise, nil)
    end)

    Task.await(waiter)
    assert_receive {:order, first}
    assert_receive {:order, second}
    assert [first, second] == [:microtask, :macrotask]
  end

  test "race/2, all/2 and set_timeout/3", %{baton: baton} do
    slow = Promise.new(baton)
    fast = Promise.new(baton)
    Baton.with_baton(baton, fn -> Baton.set_timeout(baton, fn -> Promise.resolve(fast, :fast) end, 10) end)
    assert Promise.await(Promise.race(baton, [slow, fast])) == :fast

    one = Promise.new(baton, fn resolve, _ -> resolve.(1) end)
    two = Promise.then_(one, &(&1 + 1))
    assert Promise.await(Promise.all(baton, [one, two])) == [1, 2]
    assert Promise.await(Promise.all(baton, [])) == []
  end

  test "spawn_handoff/1 runs the callback under the baton and returns to the caller", %{baton: baton} do
    test = self()

    Baton.with_baton(baton, fn ->
      Baton.spawn_handoff(fn -> send(test, {:held, Baton.held?()}) end)
      assert Baton.held?()
    end)

    assert_received {:held, true}
  end

  test "a crashing handed-off callback is logged; the caller continues", %{baton: baton} do
    log =
      capture_log(fn ->
        Baton.with_baton(baton, fn -> Baton.spawn_handoff(fn -> raise "listener boom" end) end)
      end)

    assert log =~ "listener boom"
    assert Baton.with_baton(baton, fn -> :still_works end) == :still_works
  end

  test "a process killed while holding the baton is reclaimed", %{baton: baton} do
    test = self()

    holder =
      spawn(fn ->
        Baton.acquire(baton)
        send(test, :holding)
        Process.sleep(:infinity)
      end)

    assert_receive :holding

    log =
      capture_log(fn ->
        Process.exit(holder, :kill)
        assert Baton.with_baton(baton, fn -> :reclaimed end) == :reclaimed
      end)

    assert log =~ "died"
  end
end
