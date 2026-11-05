defmodule PlaywrightEx.Runtime.HeapTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  defmodule Obj do
    @moduledoc false
    defstruct [:guid, :loop, :heap]
  end

  setup do
    loop = EventLoop.get(start_supervised!(EventLoop))
    %{obj: EventLoop.with_baton(loop, fn -> Heap.new_object(Obj) end)}
  end

  describe "Map fields iterate in insertion order (JS Map)" do
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

    test "maps of different fields and objects are separate", %{obj: obj} do
      other = EventLoop.with_baton(obj.loop, fn -> Heap.new_object(Obj) end)
      Heap.map_set(obj, :_a, 1, :a)
      Heap.map_set(obj, :_b, 1, :b)
      Heap.map_set(other, :_a, 2, :other)
      assert Heap.map_entries(obj, :_a) == [{1, :a}]
      assert Heap.map_entries(obj, :_b) == [{1, :b}]
      Heap.map_clear(obj, :_a)
      assert Heap.map_entries(obj, :_a) == []
      assert Heap.map_entries(other, :_a) == [{2, :other}]
    end
  end

  test "map_keys/2 is in insertion order", %{obj: obj} do
    for key <- ["z", "a", "m"], do: Heap.map_set(obj, :_events, key, [])
    assert Heap.map_keys(obj, :_events) == ["z", "a", "m"]
  end
end
