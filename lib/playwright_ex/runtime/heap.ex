defmodule PlaywrightEx.Runtime.Heap do
  @moduledoc """
  Runtime support (not ported from upstream): mutable object fields.

  `this._foo` becomes `get(this, :_foo)`, `this._foo = x` becomes `put(this, :_foo, x)`.

  Fields of protocol objects (and of the objects they own) are rows of their connection's table
  (`PlaywrightEx.Runtime.Conn`), an `ordered_set` the connection process alone writes: reads are
  lock-free from any process, writes from other processes run in the connection
  (`PlaywrightEx.Runtime.Conn.run/2`), so a read-modify-write (`update/3`, `atomic/2`) is atomic
  as a synchronous JS section is.

  Rows are keyed `{owner_guid, local}`: a protocol object's fields are `{guid, field}`, those of an
  object it owns (`new_object/2`) `{guid, {ref, field}}`, `Map` entries `{.., {:map, field, key}}`
  (with an insertion sequence: JS Map order), latches (`PlaywrightEx.Runtime.Promise`)
  `{.., {:latch, ref}}`. So `_dispose` frees an object and all it owns with one bounded prefix
  delete (`free_rows/2`). `Set` fields are insertion-ordered lists.

  A handle carries the immutable part of its object (`guid`, `type`, `initializer`, its
  connection): `:_type`, `:_guid`, `:_initializer` and `:_connection` stay readable after dispose.
  A disposed object keeps its rows until its anchor is freed (see
  `_dispose` in `PlaywrightEx.Client.ChannelOwner`), so it reads and writes as in JS. Fields of a
  freed object raise `PlaywrightEx.TargetClosedError`; writes to it are dropped.

  `new_object(module)` is a process-local object: its fields live in the process dictionary of
  its creator, which alone may use it (another process raises); `free/1` erases it.
  """
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.TargetClosedError

  @special [:_type, :_guid, :_initializer, :_connection]

  @doc """
  `new X()` for a runtime object. With an `owner` (a protocol object, the connection, or an object
  they own), its rows live on the owner and go with it; without one, it is process-local.
  """
  def new_object(module, owner \\ nil)

  def new_object(module, nil), do: struct(module, guid: make_ref(), conn: self(), table: nil)
  def new_object(module, %{table: nil} = _local_owner), do: new_object(module, nil)

  def new_object(module, %{guid: guid, conn: conn, table: table}),
    do: struct(module, guid: {root(guid), make_ref()}, conn: conn, table: table)

  @doc "Frees a runtime object's fields (process-local: erases them; owned: deletes its rows)."
  def free(%{table: nil, guid: ref} = obj) do
    check_local!(obj)
    Process.delete({:pw_local, ref})
    :ok
  end

  def free(%{guid: {owner, ref}} = obj) do
    in_conn(obj, fn -> :ets.select_delete(obj.table, [{{{owner, {ref, :_}}, :_}, [], [true]}]) end)
    :ok
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

  @doc "Whether the object's rows exist: a disposed object (or one of a closed connection) is not alive."
  def alive?(%{table: nil}), do: true
  def alive?(%{guid: guid, table: table}), do: alive_guid?(table, guid)

  defp alive_guid?(table, :connection), do: table_alive?(table)
  defp alive_guid?(table, {owner, _ref}), do: alive_guid?(table, owner)
  # Rows owned by a process (`PlaywrightEx.Runtime.ProcessOwner`).
  defp alive_guid?(_table, pid) when is_pid(pid), do: Process.alive?(pid)

  defp alive_guid?(table, guid) do
    :ets.member(table, {:connection, {:map, :_objects, guid}})
  rescue
    ArgumentError -> false
  end

  defp table_alive?(table), do: :ets.info(table, :id) != :undefined

  def get(obj, field) when field in @special and is_binary(:erlang.map_get(:guid, obj)), do: special(obj, field)
  def get(%{table: nil} = obj, field), do: local(obj) |> Map.get(field)

  def get(obj, field) do
    case lookup(obj, key(obj, field)) do
      [{_, value}] -> value
      [] -> missing(obj)
    end
  end

  defp special(%{type: type}, :_type), do: type
  defp special(%{guid: guid}, :_guid), do: guid
  defp special(%{initializer: initializer}, :_initializer), do: initializer

  defp special(%{conn: conn, table: table}, :_connection),
    do: struct(PlaywrightEx.Client.Connection, guid: :connection, conn: conn, table: table)

  # An absent field: `undefined` while the object is alive or retained after dispose, else (its
  # rows freed) a TargetClosedError.
  defp missing(obj), do: if(readable?(obj), do: nil, else: raise(TargetClosedError.new()))

  @doc false
  # Alive, or disposed and retained: its fields read and write as in JS.
  def readable?(obj), do: alive?(obj) or retained?(obj)

  @doc false
  # Whether a disposed object's rows are kept (`PlaywrightEx.Client.ChannelOwner._dispose/2`).
  def retained?(%{table: nil}), do: false

  def retained?(%{guid: guid, table: table}) do
    :ets.member(table, {root(guid), :__retained__})
  rescue
    ArgumentError -> false
  end

  defp lookup(%{table: table}, key) do
    :ets.lookup(table, key)
  rescue
    # A deleted table: the connection is gone.
    ArgumentError -> []
  end

  @doc false
  # The row key of `sub` (a field, `{:map, field, key}`, `{:latch, ref}`) of an object.
  def key(%{guid: {owner, ref}}, sub), do: {owner, {ref, sub}}
  def key(%{guid: guid}, sub), do: {guid, sub}

  defp root({owner, _ref}), do: owner
  defp root(guid), do: guid

  # `delete this._foo`
  def delete(%{table: nil} = obj, field), do: put_local(obj, Map.delete(local(obj), field))
  def delete(obj, field), do: in_conn(obj, fn -> :ets.delete(obj.table, key(obj, field)) end)

  def put(%{table: nil} = obj, field, value) do
    put_local(obj, Map.put(local(obj), field, value))
    value
  end

  def put(obj, field, value) do
    in_conn(obj, fn -> insert(obj, key(obj, field), value) end)
    value
  end

  # In the connection: writes to a freed object are dropped (they would leak rows).
  defp insert(obj, key, value) do
    if readable?(obj), do: :ets.insert(obj.table, {key, value})
  end

  # A disposed object's update is dropped, as its writes are.
  def update(obj, field, fun), do: atomic(obj, fn -> if readable?(obj), do: put(obj, field, fun.(get(obj, field))) end)

  @doc """
  Runs `fun` atomically with respect to the object's connection (in it): a synchronous JS section
  that reads, decides and writes. `fun` must not await (it raises). Process-local objects run it here.
  """
  def atomic(%{table: nil}, fun), do: fun.()
  def atomic(obj, fun), do: in_conn(obj, fun)

  defp in_conn(%{conn: conn}, fun) do
    if self() == conn, do: fun.(), else: Conn.run(conn, fun)
  end

  # Set<T> fields (insertion ordered)
  def set_add(obj, field, item),
    do: update(obj, field, fn set -> if item in (set || []), do: set, else: (set || []) ++ [item] end)

  def set_delete(obj, field, item), do: update(obj, field, fn set -> List.delete(set || [], item) end)
  def set_has(obj, field, item), do: item in (get(obj, field) || [])

  # Map<K, V> fields: `{{.., {:map, field, key}}, {seq, value}}` rows. `seq` keeps JS insertion
  # order: setting an existing key keeps its position, delete + set moves it to the end.
  def map_get(%{table: nil} = obj, field, key), do: local(obj) |> Map.get({:map, field, key}) |> elem_or_nil()

  def map_get(obj, field, key) do
    case lookup(obj, key(obj, {:map, field, key})) do
      [{_, {_seq, value}}] -> value
      [] -> missing(obj)
    end
  end

  defp elem_or_nil(nil), do: nil
  defp elem_or_nil({_seq, value}), do: value

  def map_set(%{table: nil} = obj, field, key, value) do
    fields = local(obj)
    seq = elem(Map.get(fields, {:map, field, key}, {:erlang.unique_integer([:monotonic]), nil}), 0)
    put_local(obj, Map.put(fields, {:map, field, key}, {seq, value}))
    value
  end

  def map_set(obj, field, key, value) do
    in_conn(obj, fn ->
      row_key = key(obj, {:map, field, key})

      seq =
        case :ets.lookup(obj.table, row_key) do
          [{_, {seq, _}}] -> seq
          [] -> :erlang.unique_integer([:monotonic])
        end

      insert(obj, row_key, {seq, value})
    end)

    value
  end

  def map_delete(%{table: nil} = obj, field, key), do: put_local(obj, Map.delete(local(obj), {:map, field, key}))
  def map_delete(obj, field, key), do: in_conn(obj, fn -> :ets.delete(obj.table, key(obj, {:map, field, key})) end)

  # `map.keys()`, `map.values()`, `map.entries()` (insertion order)
  def map_keys(obj, field), do: obj |> map_entries(field) |> Enum.map(&elem(&1, 0))
  def map_values(obj, field), do: obj |> map_entries(field) |> Enum.map(&elem(&1, 1))

  def map_entries(%{table: nil} = obj, field) do
    for({{:map, ^field, key}, {seq, value}} <- local(obj), do: {seq, key, value})
    |> Enum.sort()
    |> Enum.map(fn {_seq, key, value} -> {key, value} end)
  end

  def map_entries(%{table: table} = obj, field) do
    table
    |> :ets.select([{{key(obj, {:map, field, :"$1"}), {:"$2", :"$3"}}, [], [{{:"$2", :"$1", :"$3"}}]}])
    |> Enum.sort()
    |> Enum.map(fn {_seq, key, value} -> {key, value} end)
  rescue
    ArgumentError -> reraise TargetClosedError.new(), __STACKTRACE__
  end

  def map_clear(%{table: nil} = obj, field),
    do: put_local(obj, Map.reject(local(obj), &match?({{:map, ^field, _}, _}, &1)))

  def map_clear(obj, field),
    do: in_conn(obj, fn -> :ets.select_delete(obj.table, [{{key(obj, {:map, field, :_}), :_}, [], [true]}]) end)

  @doc false
  # In the connection: all rows of a protocol object and of the objects it owns (a bounded prefix
  # select), as `{local, value}`; `free_rows/2` deletes them.
  def rows(%{table: table}, guid) when is_binary(guid),
    do: :ets.select(table, [{{{guid, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])

  @doc false
  # In the connection: frees a retained object's rows and those of the objects it anchors
  # (`{guid, {:retained, child}}`, see `PlaywrightEx.Client.ChannelOwner._dispose/2`).
  def release(table, guid) do
    for {{:retained, child}, _} <- rows(%{table: table}, guid), do: release(table, child)
    free_rows(%{table: table}, guid)
  end

  @doc false
  def free_rows(%{table: table}, guid) when is_binary(guid),
    do: :ets.select_delete(table, [{{{guid, :_}, :_}, [], [true]}])

  ## Process-local objects

  defp local(obj) do
    check_local!(obj)
    Process.get({:pw_local, obj.guid}, %{})
  end

  defp put_local(obj, fields) do
    check_local!(obj)
    Process.put({:pw_local, obj.guid}, fields)
    :ok
  end

  defp check_local!(%{conn: creator} = obj) do
    if creator != self(),
      do:
        raise(
          "#{inspect(obj.__struct__)} is a process-local object of #{inspect(creator)}, used from #{inspect(self())}"
        )
  end
end
