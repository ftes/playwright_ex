defmodule PlaywrightEx.Runtime.GCTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.GC
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.Promise
  alias PlaywrightEx.TargetClosedError

  defmodule Obj do
    @moduledoc false
    defstruct [:guid, :loop, :heap]
  end

  setup do
    loop = EventLoop.get(start_supervised!(EventLoop))
    %{loop: loop, connection: %Obj{guid: :connection, loop: loop, heap: EventLoop.new_heap(loop)}}
  end

  defp baton(loop, fun), do: EventLoop.with_baton(loop, fun)

  # Freeing takes two collections (the first finds the garbage, the second frees it).
  defp collect(loop) do
    baton(loop, fn -> GC.collect(loop) end)
    baton(loop, fn -> GC.collect(loop) end)
  end

  defp rows(heap, guid), do: :ets.select(heap, [{{{guid, :_}, :_}, [], [true]}, {{{guid, :_, :_}, :_, :_}, [], [true]}])

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  test "a settled promise nothing references is freed", %{loop: loop} do
    guid = baton(loop, fn -> Promise.new(fn resolve, _ -> resolve.(:value) end).guid end)
    assert length(rows(loop.heap, guid)) == 1
    collect(loop)
    assert rows(loop.heap, guid) == []
  end

  test "a promise returned to a process stays awaitable after it settled; unroot/1 frees it", %{loop: loop} do
    promise = baton(loop, &Promise.new/0)
    waiter = Task.async(fn -> Promise.await(promise) end)
    eventually(fn -> Heap.get(promise, :awaiters) != [] end)
    baton(loop, fn -> Promise.resolve(promise, :value) end)
    collect(loop)
    assert Task.await(waiter) == :value
    assert Promise.await(promise) == :value
    assert Promise.await(promise) == :value

    GC.unroot(promise)
    collect(loop)
    assert rows(loop.heap, promise.guid) == []
    assert_raise RuntimeError, ~r/garbage collected/, fn -> Promise.await(promise) end
  end

  test "returned values are released when their process exits", %{loop: loop} do
    test = self()
    spawn(fn -> send(test, baton(loop, fn -> Promise.new(fn resolve, _ -> resolve.(:value) end) end).guid) end)
    assert_receive guid

    eventually(fn -> :ets.select_count(loop.roots, [{{{{:returned, :_}, :_}, :_}, [], [true]}]) == 0 end)
    collect(loop)
    assert rows(loop.heap, guid) == []
  end

  test "a value a Task returns stays rooted for its caller", %{loop: loop} do
    promise =
      fn -> baton(loop, fn -> Promise.new(fn resolve, _ -> resolve.(:value) end) end) end
      |> Task.async()
      |> Task.await()

    eventually(fn -> :ets.select_count(loop.roots, [{{{{:returned, :_}, :_}, :_}, [], [true]}]) == 1 end)
    collect(loop)
    assert Promise.await(promise) == :value
    GC.unroot(promise)
    collect(loop)
    assert rows(loop.heap, promise.guid) == []
  end

  test "a unit parked forever holds back only what was allocated before it parked", %{
    loop: loop,
    connection: connection
  } do
    {old, gate} =
      baton(loop, fn ->
        old = Heap.new_object(Obj)
        Heap.put(old, :value, :old)
        Heap.put(connection, :old, old)
        gate = Promise.new()
        Heap.put(connection, :gate, gate)
        {old, gate}
      end)

    parked =
      Task.async(fn ->
        baton(loop, fn ->
          old = Heap.get(connection, :old)
          Promise.await(gate)
          Heap.get(old, :value)
        end)
      end)

    eventually(fn -> :ets.select_count(loop.roots, [{{{:parked, :_}, :_}, [], [true]}]) == 1 end)
    baton(loop, fn -> Heap.delete(connection, :old) end)

    young =
      baton(loop, fn ->
        young = Heap.new_object(Obj)
        Heap.put(young, :value, :young)
        young.guid
      end)

    collect(loop)
    assert rows(loop.heap, young) == []
    assert rows(loop.heap, old.guid) != []

    baton(loop, fn -> Promise.resolve(gate, nil) end)
    assert Task.await(parked) == :old
  end

  test "a suspended unit keeps what it read, even once detached from the heap", %{loop: loop, connection: connection} do
    {x, gate} =
      baton(loop, fn ->
        x = Heap.new_object(Obj)
        Heap.put(x, :value, 1)
        Heap.put(connection, :x, x)
        Heap.put(connection, :gate, Promise.new())
        {x.guid, Heap.get(connection, :gate).guid}
      end)

    reader =
      Task.async(fn ->
        baton(loop, fn ->
          x = Heap.get(connection, :x)
          Promise.await(Heap.get(connection, :gate))
          Heap.get(x, :value)
        end)
      end)

    eventually(fn -> :ets.lookup(loop.heap, {gate, :awaiters}) != [{{gate, :awaiters}, []}] end)
    baton(loop, fn -> Heap.delete(connection, :x) end)
    collect(loop)
    assert rows(loop.heap, x) != []

    baton(loop, fn -> Promise.resolve(Heap.get(connection, :gate), nil) end)
    assert Task.await(reader) == 1
    collect(loop)
    assert rows(loop.heap, x) == []
  end

  test "timer callbacks are roots until they run", %{loop: loop} do
    test = self()

    baton(loop, fn ->
      x = Heap.new_object(Obj)
      Heap.put(x, :value, :kept)
      EventLoop.set_timeout(fn -> send(test, Heap.get(x, :value)) end, 100)
      :ok
    end)

    collect(loop)
    assert_receive :kept, 2000
  end

  test "objects in closures and Map keys of reachable objects are reachable", %{loop: loop, connection: connection} do
    {a, b} =
      baton(loop, fn ->
        a = Heap.new_object(Obj)
        b = Heap.new_object(Obj)
        Heap.put(a, :value, :a)
        Heap.put(b, :value, :b)
        Heap.put(connection, :listener, fn -> a end)
        Heap.map_set(connection, :_map, b, true)
        {a.guid, b.guid}
      end)

    collect(loop)
    assert rows(loop.heap, a) != []
    assert rows(loop.heap, b) != []

    baton(loop, fn ->
      Heap.delete(connection, :listener)
      Heap.map_clear(connection, :_map)
    end)

    collect(loop)
    assert rows(loop.heap, a) == []
    assert rows(loop.heap, b) == []
  end

  test "disposed objects stay readable among the last 500 disposed", %{loop: loop, connection: connection} do
    disposed = %Obj{guid: "page@1", loop: loop, heap: connection.heap}
    Heap.put(disposed, :_closed, true)
    baton(loop, fn -> GC.dispose(disposed) end)

    for i <- 1..499 do
      other = %Obj{guid: "other@#{i}", loop: loop, heap: connection.heap}
      baton(loop, fn -> GC.dispose(other) end)
    end

    collect(loop)
    assert Heap.get(disposed, :_closed)

    baton(loop, fn -> GC.dispose(%Obj{guid: "other@500", loop: loop, heap: connection.heap}) end)
    collect(loop)
    assert Heap.get(disposed, :_closed) == nil
  end

  test "a closed connection's heap is deleted once nothing in it is reachable", %{loop: loop, connection: connection} do
    Heap.put(connection, :_closedError, :closed)
    baton(loop, fn -> GC.close_heap(connection) end)
    collect(loop)
    assert Heap.get(connection, :_closedError) == :closed

    for i <- 1..500, do: baton(loop, fn -> GC.dispose(%Obj{guid: "other@#{i}", loop: loop, heap: loop.heap}) end)
    collect(loop)
    assert :ets.info(connection.heap) == :undefined
    assert_raise TargetClosedError, fn -> Heap.get(connection, :_closedError) end
  end

  test "the heap stays bounded without explicit collections", %{loop: loop} do
    sizes =
      for _ <- 1..10_000 do
        baton(loop, fn ->
          promise = Promise.new()
          Promise.then_(promise, & &1)
          Promise.resolve(promise, :value)
          nil
        end)

        :ets.info(loop.heap, :size)
      end

    # Two promises per unit; collections every 2000 allocations, freeing one collection later.
    assert Enum.max(sizes) <= 4100
    assert List.last(sizes) <= 4100
  end
end
