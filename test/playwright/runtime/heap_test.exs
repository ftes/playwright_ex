defmodule Playwright.Runtime.HeapTest do
  use ExUnit.Case, async: true

  alias Playwright.Runtime.Heap
  alias Playwright.Runtime.ProcessOwner

  defmodule Obj do
    @moduledoc false
    defstruct [:guid, :conn, :table]
  end

  # A process-local object (pdict) and one with table rows (owned by the test process).
  defp new(:local), do: Heap.new_object(Obj)
  defp new(:rows), do: Heap.new_object(Obj, ProcessOwner.owner())

  for kind <- [:local, :rows] do
    describe "Map fields iterate in insertion order (JS Map), #{kind}" do
      setup do
        %{obj: new(unquote(kind)), kind: unquote(kind)}
      end

      test "keys, values and entries follow insertion, not key order", %{obj: obj} do
        for key <- [:c, "b", 3, :a, {:t, 1}, "a"], do: Heap.map_set(obj, :_map, key, to_string(inspect(key)))
        assert Heap.map_keys(obj, :_map) == [:c, "b", 3, :a, {:t, 1}, "a"]
        assert Heap.map_values(obj, :_map) == Enum.map([:c, "b", 3, :a, {:t, 1}, "a"], &inspect/1)
        assert hd(Heap.map_entries(obj, :_map)) == {:c, ":c"}
      end

      test "setting an existing key keeps its position", %{obj: obj} do
        for key <- [:x, :y, :z], do: Heap.map_set(obj, :_map, key, 1)
        Heap.map_set(obj, :_map, :x, 2)
        assert Heap.map_entries(obj, :_map) == [x: 2, y: 1, z: 1]
      end

      test "delete + set moves the key to the end", %{obj: obj} do
        for key <- [:x, :y, :z], do: Heap.map_set(obj, :_map, key, 1)
        Heap.map_delete(obj, :_map, :x)
        Heap.map_set(obj, :_map, :x, 2)
        assert Heap.map_keys(obj, :_map) == [:y, :z, :x]
      end

      test "maps of different fields and objects are separate", %{obj: obj, kind: kind} do
        other = new(kind)
        Heap.map_set(obj, :_a, 1, :a)
        Heap.map_set(obj, :_b, 1, :b)
        Heap.map_set(other, :_a, 2, :other)
        assert Heap.map_entries(obj, :_a) == [{1, :a}]
        assert Heap.map_entries(obj, :_b) == [{1, :b}]
        Heap.map_clear(obj, :_a)
        assert Heap.map_entries(obj, :_a) == []
        assert Heap.map_entries(other, :_a) == [{2, :other}]
      end

      test "free deletes the object's fields only", %{obj: obj, kind: kind} do
        other = new(kind)
        Heap.put(obj, :_x, 1)
        Heap.map_set(obj, :_m, :k, 1)
        Heap.put(other, :_x, 2)
        Heap.free(obj)
        assert Heap.get(obj, :_x) == nil
        assert Heap.map_entries(obj, :_m) == []
        assert Heap.get(other, :_x) == 2
      end
    end
  end

  test "a process-local object raises in another process" do
    obj = new(:local)
    Heap.put(obj, :_x, 1)

    assert {:error, %RuntimeError{message: message}} =
             Task.await(Task.async(fn -> safe(fn -> Heap.get(obj, :_x) end) end))

    assert message =~ "process-local object"
  end

  test "rows owned by a process are readable from any process and freed when it exits" do
    obj = new(:rows)
    Heap.put(obj, :_x, 1)
    assert Task.await(Task.async(fn -> Heap.get(obj, :_x) end)) == 1

    {owner, task_obj} =
      Task.await(Task.async(fn -> {self(), tap(new(:rows), &Heap.put(&1, :_x, 2))} end))

    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000
    :sys.get_state(ProcessOwner)
    await_freed(task_obj, :_x, 500)
    assert_raise Playwright.TargetClosedError, fn -> Heap.get(task_obj, :_x) end
    assert :ets.select(obj.table, [{{{owner, :_}, :_}, [], [true]}]) == []
  end

  test "get_or_freed reads a field, nil while unset, and its freed value once the rows are freed" do
    {owner, task_obj} =
      Task.await(
        Task.async(fn ->
          obj = tap(new(:rows), &Heap.put(&1, :_closed, false))
          assert Heap.get_or_freed(obj, :_closed, true) == false
          assert Heap.get_or_freed(obj, :_unset, true) == nil
          {self(), obj}
        end)
      )

    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000
    :sys.get_state(ProcessOwner)
    await_freed(task_obj, :_closed, 500)
    assert Heap.get_or_freed(task_obj, :_closed, true) == true
    assert_raise Playwright.TargetClosedError, fn -> Heap.get(task_obj, :_closed) end
  end

  test "get_or_freed reads a process-local object's field" do
    obj = tap(new(:local), &Heap.put(&1, :_closed, false))
    assert Heap.get_or_freed(obj, :_closed, true) == false
    assert Heap.get_or_freed(obj, :_unset, true) == nil
  end

  # `readable?/1` of a process-owned object is just `Process.alive?(owner)`, true before `ProcessOwner`
  # handles the owner's :DOWN; poll the field's row instead.
  defp await_freed(obj, field, 0), do: flunk("row #{inspect(field)} of #{inspect(obj.guid)} was not freed within 5 s")

  defp await_freed(obj, field, tries) do
    if Heap.get_or_freed(obj, field, :freed) != :freed do
      Process.sleep(10)
      await_freed(obj, field, tries - 1)
    end
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  end
end
