defmodule PlaywrightJS.Runtime.Heap do
  @moduledoc """
  Runtime support (not ported from upstream): mutable object fields.

  `this._foo` becomes `get(this, :_foo)`, `this._foo = x` becomes `put(this, :_foo, x)`.
  Fields live in the loop's ETS table as `{{guid, field}, value}` rows; `Map` fields as
  `{{guid, field, key}, value}` rows; `Set` fields as insertion-ordered lists.
  Reads are lock-free from any process; writes are serialized through the loop.

  Objects with `conn: nil` are transient value objects (all fields `undefined`).
  """
  alias PlaywrightJS.Runtime.Loop

  def new_object(%Loop{} = loop, module, guid \\ make_ref()), do: struct(module, guid: guid, conn: loop)

  def get(%{conn: nil}, _field), do: nil

  def get(%{conn: %Loop{table: table}, guid: guid}, field) do
    case :ets.lookup(table, {guid, field}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def put(%{conn: nil} = obj, field, _value), do: raise("cannot assign #{inspect(field)} on value object #{inspect(obj)}")

  def put(%{conn: %Loop{} = loop, guid: guid}, field, value) do
    Loop.exec(loop, fn -> :ets.insert(loop.table, {{guid, field}, value}) end)
    value
  end

  def update(%{conn: loop} = obj, field, fun), do: Loop.exec(loop, fn -> put(obj, field, fun.(get(obj, field))) end)

  # Set<T> fields (insertion ordered)
  def set_add(obj, field, item), do: update(obj, field, fn set -> if item in (set || []), do: set, else: (set || []) ++ [item] end)
  def set_delete(obj, field, item), do: update(obj, field, fn set -> List.delete(set || [], item) end)
  def set_has(obj, field, item), do: item in (get(obj, field) || [])

  # Map<K, V> fields
  def map_get(%{conn: %Loop{table: table}, guid: guid}, field, key) do
    case :ets.lookup(table, {guid, field, key}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def map_set(%{conn: loop, guid: guid}, field, key, value) do
    Loop.exec(loop, fn -> :ets.insert(loop.table, {{guid, field, key}, value}) end)
    value
  end

  def map_delete(%{conn: loop, guid: guid}, field, key), do: Loop.exec(loop, fn -> :ets.delete(loop.table, {guid, field, key}) end)

  def map_values(%{conn: %Loop{table: table}, guid: guid}, field), do: :ets.match(table, {{guid, field, :_}, :"$1"}) |> Enum.map(&hd/1)

  def map_clear(%{conn: loop, guid: guid}, field), do: Loop.exec(loop, fn -> :ets.match_delete(loop.table, {{guid, field, :_}, :_}) end)
end
