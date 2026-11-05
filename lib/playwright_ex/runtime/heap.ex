defmodule PlaywrightEx.Runtime.Heap do
  @moduledoc """
  Runtime support (not ported from upstream): mutable object fields.

  `this._foo` becomes `get(this, :_foo)`, `this._foo = x` becomes `put(this, :_foo, x)`.
  Fields live in the object's heap (an `ordered_set` ETS table: the connection's, or the loop's for
  runtime objects) as `{{guid, field}, value}` rows; `Map` fields as `{{guid, field, key}, value, seq}`
  rows, read in insertion order (`seq`); `Set` fields as insertion-ordered lists. The table is
  ordered so that one object's rows (a `{guid, ...}` key prefix) are a range.
  Reads are lock-free from any process; writes happen under the baton (acquired on demand).

  Objects with `loop: nil` are transient value objects (all fields `undefined`).

  Rows are freed by `PlaywrightEx.Runtime.GC` once their object is unreachable. A closed
  connection's table is deleted once nothing in it is reachable: reading a handle from it raises
  `TargetClosedError`.
  """
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.GC
  alias PlaywrightEx.TargetClosedError

  @doc "`new X()` for a runtime object: lives in the heap of the current loop (see `EventLoop.current!/0`)."
  def new_object(module, guid \\ make_ref()) do
    %EventLoop{heap: heap} = loop = EventLoop.current!()
    GC.count_allocation(loop)
    struct(module, guid: guid, loop: loop, heap: heap)
  end

  @doc """
  The module implementing an object's class, for calls that a subclass may override
  (`this.foo()` is `impl(this).foo(this)`). Handles of public classes are facade structs
  (`%PlaywrightEx.Page{}`), which name their client module (`__client__/0`).
  """
  def impl(%module{}) do
    Code.ensure_loaded(module)
    if function_exported?(module, :__client__, 0), do: module.__client__(), else: module
  end

  def get(%{heap: nil}, _field), do: nil

  def get(%{heap: heap, guid: guid}, field) do
    case lookup(heap, {guid, field}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  # `delete this._foo`
  def delete(%{loop: loop, heap: heap, guid: guid}, field),
    do: EventLoop.with_baton(loop, fn -> :ets.delete(heap, {guid, field}) end)

  # A deleted table: the connection closed and nothing in it was reachable any more.
  defp lookup(heap, key) do
    :ets.lookup(heap, key)
  rescue
    ArgumentError -> reraise TargetClosedError, __STACKTRACE__
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

  # Map<K, V> fields: `{{guid, field, key}, value, seq}` rows. `seq` keeps JS insertion order:
  # setting an existing key keeps its position, delete + set moves it to the end.
  def map_get(%{heap: heap, guid: guid}, field, key) do
    case lookup(heap, {guid, field, key}) do
      [{_, value, _}] -> value
      [] -> nil
    end
  end

  def map_set(%{loop: loop, heap: heap, guid: guid}, field, key, value) do
    EventLoop.with_baton(loop, fn ->
      seq =
        case :ets.lookup(heap, {guid, field, key}) do
          [{_, _, seq}] -> seq
          [] -> :erlang.unique_integer([:monotonic])
        end

      :ets.insert(heap, {{guid, field, key}, value, seq})
    end)

    value
  end

  def map_delete(%{loop: loop, heap: heap, guid: guid}, field, key),
    do: EventLoop.with_baton(loop, fn -> :ets.delete(heap, {guid, field, key}) end)

  # `map.keys()`, `map.values()`, `map.entries()` (insertion order)
  def map_keys(obj, field), do: obj |> map_entries(field) |> Enum.map(&elem(&1, 0))
  def map_values(obj, field), do: obj |> map_entries(field) |> Enum.map(&elem(&1, 1))

  def map_entries(%{heap: heap, guid: guid}, field) do
    heap
    |> :ets.select([{{{guid, field, :"$1"}, :"$2", :"$3"}, [], [{{:"$3", :"$1", :"$2"}}]}])
    |> Enum.sort()
    |> Enum.map(fn {_seq, key, value} -> {key, value} end)
  end

  def map_clear(%{loop: loop, heap: heap, guid: guid}, field),
    do: EventLoop.with_baton(loop, fn -> :ets.match_delete(heap, {{guid, field, :_}, :_, :_}) end)
end
