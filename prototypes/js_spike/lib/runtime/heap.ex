defmodule PlaywrightJS.Runtime.Heap do
  @moduledoc """
  Runtime support (not ported from upstream): mutable object fields.

  `this._foo` becomes `get(this, :_foo)`, `this._foo = x` becomes `put(this, :_foo, x)`.
  Fields live in the connection's ETS table as `{{guid, field}, value}` rows; `Map` fields as
  `{{guid, field, key}, value}` rows; `Set` fields as insertion-ordered lists.
  Reads are lock-free from any process; writes happen under the baton (acquired on demand).

  Objects with `conn: nil` are transient value objects (all fields `undefined`).
  """
  alias PlaywrightJS.Runtime.Baton

  def new_object(%Baton{} = baton, module, guid \\ make_ref()), do: struct(module, guid: guid, conn: baton)

  def get(%{conn: nil}, _field), do: nil

  def get(%{conn: %Baton{table: table}, guid: guid}, field) do
    case :ets.lookup(table, {guid, field}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def put(%{conn: nil} = obj, field, _value), do: raise("cannot assign #{inspect(field)} on value object #{inspect(obj)}")

  def put(%{conn: %Baton{} = baton, guid: guid}, field, value) do
    Baton.with_baton(baton, fn -> :ets.insert(baton.table, {{guid, field}, value}) end)
    value
  end

  def update(%{conn: baton} = obj, field, fun), do: Baton.with_baton(baton, fn -> put(obj, field, fun.(get(obj, field))) end)

  # Set<T> fields (insertion ordered)
  def set_add(obj, field, item), do: update(obj, field, fn set -> if item in (set || []), do: set, else: (set || []) ++ [item] end)
  def set_delete(obj, field, item), do: update(obj, field, fn set -> List.delete(set || [], item) end)
  def set_has(obj, field, item), do: item in (get(obj, field) || [])

  # Map<K, V> fields
  def map_get(%{conn: %Baton{table: table}, guid: guid}, field, key) do
    case :ets.lookup(table, {guid, field, key}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  def map_set(%{conn: baton, guid: guid}, field, key, value) do
    Baton.with_baton(baton, fn -> :ets.insert(baton.table, {{guid, field, key}, value}) end)
    value
  end

  def map_delete(%{conn: baton, guid: guid}, field, key), do: Baton.with_baton(baton, fn -> :ets.delete(baton.table, {guid, field, key}) end)

  def map_values(%{conn: %Baton{table: table}, guid: guid}, field), do: :ets.match(table, {{guid, field, :_}, :"$1"}) |> Enum.map(&hd/1)

  def map_clear(%{conn: baton, guid: guid}, field), do: Baton.with_baton(baton, fn -> :ets.match_delete(baton.table, {{guid, field, :_}, :_}) end)
end
