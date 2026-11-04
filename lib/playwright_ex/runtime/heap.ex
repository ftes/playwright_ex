defmodule PlaywrightEx.Runtime.Heap do
  @moduledoc """
  Runtime support (not ported from upstream): mutable object fields.

  `this._foo` becomes `get(this, :_foo)`, `this._foo = x` becomes `put(this, :_foo, x)`.
  Fields live in the object's heap (an ETS table: the connection's, or the loop's for runtime objects) as `{{guid, field}, value}` rows; `Map` fields as
  `{{guid, field, key}, value}` rows; `Set` fields as insertion-ordered lists.
  Reads are lock-free from any process; writes happen under the baton (acquired on demand).

  Objects with `loop: nil` are transient value objects (all fields `undefined`).
  """
  alias PlaywrightEx.Runtime.EventLoop

  @doc "`new X()` for a runtime object: lives in the heap of the current loop (see `EventLoop.current!/0`)."
  def new_object(module, guid \\ make_ref()) do
    %EventLoop{heap: heap} = loop = EventLoop.current!()
    struct(module, guid: guid, loop: loop, heap: heap)
  end

  def get(%{heap: nil}, _field), do: nil

  def get(%{heap: heap, guid: guid}, field) do
    case :ets.lookup(heap, {guid, field}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def put(%{loop: nil} = obj, field, _value),
    do: raise("cannot assign #{inspect(field)} on value object #{inspect(obj)}")

  def put(%{loop: %EventLoop{} = loop, heap: heap, guid: guid}, field, value) do
    EventLoop.with_baton(loop, fn -> :ets.insert(heap, {{guid, field}, value}) end)
    value
  end

  def update(%{loop: loop} = obj, field, fun),
    do: EventLoop.with_baton(loop, fn -> put(obj, field, fun.(get(obj, field))) end)

  # Set<T> fields (insertion ordered)
  def set_add(obj, field, item),
    do: update(obj, field, fn set -> if item in (set || []), do: set, else: (set || []) ++ [item] end)

  def set_delete(obj, field, item), do: update(obj, field, fn set -> List.delete(set || [], item) end)
  def set_has(obj, field, item), do: item in (get(obj, field) || [])

  # Map<K, V> fields
  def map_get(%{heap: heap, guid: guid}, field, key) do
    case :ets.lookup(heap, {guid, field, key}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def map_set(%{loop: loop, heap: heap, guid: guid}, field, key, value) do
    EventLoop.with_baton(loop, fn -> :ets.insert(heap, {{guid, field, key}, value}) end)
    value
  end

  def map_delete(%{loop: loop, heap: heap, guid: guid}, field, key),
    do: EventLoop.with_baton(loop, fn -> :ets.delete(heap, {guid, field, key}) end)

  def map_values(%{heap: heap, guid: guid}, field),
    do: heap |> :ets.match({{guid, field, :_}, :"$1"}) |> Enum.map(&hd/1)

  def map_clear(%{loop: loop, heap: heap, guid: guid}, field),
    do: EventLoop.with_baton(loop, fn -> :ets.match_delete(heap, {{guid, field, :_}, :_}) end)
end
