defmodule PlaywrightEx.Runtime.HeapTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.ProcessOwner

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

    :sys.get_state(ProcessOwner)
    refute Process.alive?(owner)
    assert_raise PlaywrightEx.TargetClosedError, fn -> Heap.get(task_obj, :_x) end
    assert :ets.select(obj.table, [{{{owner, :_}, :_}, [], [true]}]) == []
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  end
end
