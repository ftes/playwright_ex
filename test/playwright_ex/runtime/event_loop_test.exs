defmodule PlaywrightEx.Runtime.EventLoopTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.Promise

  defmodule Obj do
    @moduledoc false
    defstruct [:guid, :loop, :heap]
  end

  setup do
    pid = start_supervised!(EventLoop)
    %{loop: EventLoop.get(pid)}
  end

  test "with_baton/2 is reentrant and releases afterwards", %{loop: loop} do
    refute EventLoop.held?()
    assert EventLoop.with_baton(loop, fn -> EventLoop.with_baton(loop, fn -> EventLoop.held?() end) end)
    refute EventLoop.held?()
  end

  test "heap fields, sets and maps", %{loop: loop} do
    obj = EventLoop.with_baton(loop, fn -> Heap.new_object(Obj) end)
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

  test "a connection heap is its own table on the same loop", %{loop: loop} do
    connection = %Obj{guid: :connection, loop: loop, heap: EventLoop.new_heap(loop)}
    runtime = EventLoop.with_baton(loop, fn -> Heap.new_object(Obj, :connection) end)
    Heap.put(connection, :_x, :connection)
    Heap.put(runtime, :_x, :runtime)
    assert Heap.get(connection, :_x) == :connection
    assert Heap.get(runtime, :_x) == :runtime
    assert runtime.heap == loop.heap
  end

  test "await releases the baton until the promise settles", %{loop: loop} do
    promise = EventLoop.with_baton(loop, &Promise.new/0)
    waiter = Task.async(fn -> Promise.await(promise) end)

    # The waiter does not hold the baton while suspended: we can take it and settle.
    Process.sleep(20)
    EventLoop.with_baton(loop, fn -> Promise.resolve(promise, :done) end)
    assert Task.await(waiter, :infinity) == :done
    # Settled promises are read without the baton.
    assert Promise.await(promise) == :done
  end

  test "rejections raise in the awaiter", %{loop: loop} do
    promise = EventLoop.with_baton(loop, fn -> Promise.rejected(%ArgumentError{message: "nope"}) end)
    assert_raise ArgumentError, "nope", fn -> Promise.await(promise) end
  end

  test "async/1 returns at the callee's first await, like calling an async function without await", %{loop: loop} do
    {gate, log, promise} =
      EventLoop.with_baton(loop, fn ->
        gate = Promise.new()
        log = Heap.new_object(Obj)
        Heap.put(log, :_log, [])

        promise =
          Promise.async(fn ->
            Heap.update(log, :_log, &(&1 ++ [:started]))
            Promise.await(gate)
            Heap.update(log, :_log, &(&1 ++ [:resumed]))
            :result
          end)

        {gate, log, promise}
      end)

    assert promise.task == nil
    assert Heap.get(log, :_log) == [:started]
    EventLoop.with_baton(loop, fn -> Promise.resolve(gate, nil) end)
    assert Promise.await(promise) == :result
    assert Heap.get(log, :_log) == [:started, :resumed]
  end

  test "async/1 outside the baton is Task-backed" do
    assert %Task{} = Promise.async(fn -> :ok end).task
  end

  test "settled awaiters resume before queued macrotasks (microtask order)", %{loop: loop} do
    test = self()
    promise = EventLoop.with_baton(loop, &Promise.new/0)

    waiter =
      Task.async(fn ->
        Promise.await(promise)
        send(test, {:order, :microtask})
      end)

    Process.sleep(20)

    EventLoop.with_baton(loop, fn ->
      EventLoop.post(loop, fn -> send(test, {:order, :macrotask}) end)
      Promise.resolve(promise, nil)
    end)

    Task.await(waiter, :infinity)
    assert_receive {:order, first}
    assert_receive {:order, second}
    assert [first, second] == [:microtask, :macrotask]
  end

  test "race/1, all/1 and set_timeout/2", %{loop: loop} do
    {race, all, empty} =
      EventLoop.with_baton(loop, fn ->
        slow = Promise.new()
        fast = Promise.new(fn resolve, _ -> EventLoop.set_timeout(fn -> resolve.(:fast) end, 10) end)
        one = Promise.new(fn resolve, _ -> resolve.(1) end)
        {Promise.race([slow, fast]), Promise.all([one, Promise.then_(one, &(&1 + 1))]), Promise.all([])}
      end)

    assert Promise.await(race) == :fast
    assert Promise.await(all) == [1, 2]
    assert Promise.await(empty) == []
  end

  test "current!/0 is the loop under every holder", %{loop: loop} do
    test = self()
    assert_raise RuntimeError, ~r/not holding/, fn -> EventLoop.current!() end

    EventLoop.with_baton(loop, fn -> EventLoop.spawn_handoff(fn -> send(test, {:handoff, EventLoop.current!()}) end) end)

    EventLoop.post(loop, fn -> send(test, {:task, EventLoop.current!()}) end)

    EventLoop.with_baton(loop, fn ->
      Promise.await(Promise.new(fn resolve, _ -> EventLoop.set_timeout(fn -> resolve.(nil) end, 5) end))
      send(test, {:resumed, EventLoop.current!()})
    end)

    assert_receive {:handoff, ^loop}
    assert_receive {:task, ^loop}
    assert_receive {:resumed, ^loop}
  end

  test "spawn_handoff/1 runs the callback under the baton and returns to the caller", %{loop: loop} do
    test = self()

    EventLoop.with_baton(loop, fn ->
      EventLoop.spawn_handoff(fn -> send(test, {:held, EventLoop.held?()}) end)
      assert EventLoop.held?()
    end)

    assert_received {:held, true}
  end

  test "a crashing handed-off callback is logged; the caller continues", %{loop: loop} do
    log =
      capture_log(fn ->
        EventLoop.with_baton(loop, fn -> EventLoop.spawn_handoff(fn -> raise "listener boom" end) end)
      end)

    assert log =~ "listener boom"
    assert EventLoop.with_baton(loop, fn -> :still_works end) == :still_works
  end

  test "a process killed while holding the baton is reclaimed", %{loop: loop} do
    test = self()

    holder =
      spawn(fn ->
        EventLoop.acquire(loop)
        send(test, :holding)
        Process.sleep(:infinity)
      end)

    assert_receive :holding

    log =
      capture_log(fn ->
        Process.exit(holder, :kill)
        assert EventLoop.with_baton(loop, fn -> :reclaimed end) == :reclaimed
      end)

    assert log =~ "died"
  end
end
