defmodule PlaywrightEx.Runtime.GC do
  @moduledoc """
  Runtime support (not ported from upstream): the garbage collector of the heaps.

  JS frees an object once nothing references it. Heap rows (`PlaywrightEx.Runtime.Heap`) are
  freed here by tracing, so that a long-running driver (thousands of pages) keeps a bounded heap.
  It runs under the baton, at the end of a unit (see `PlaywrightEx.Runtime.EventLoop`), once
  `new_object/1` allocations reach a threshold (twice the reachable objects, at least 2000).

  Roots, the references the heap cannot see:

    * the `:connection` object of every open connection heap (and so the live channel owners,
      `_objects`),
    * the last 500 disposed channel owners and closed connections (`dispose/1`,
      `close_heap/1`): a handle kept after `close` still reads its fields, as in JS,
    * values returned from the baton to a caller (a promise handle from `wait_for_event`), until
      the caller exits or `unroot/1` (at most 1000 per process, the oldest go first),
    * callbacks of pending timers and macrotasks, and promises with suspended awaiters.

  Tracing follows field values, map keys and the environment of closures (`listener` funs).
  Locals of suspended units are invisible, so an object unreachable at one collection is freed
  at a later one, once every unit in flight at the first has ended (epoch-based reclamation).
  A unit that never ends (a listener awaiting forever) postpones all reclamation.
  """
  alias PlaywrightEx.Runtime.EventLoop

  @min_threshold 2000
  @graveyard 500
  @returned_per_process 1000

  @doc false
  def new_roots, do: :ets.new(:playwright_ex_roots, [:ordered_set, :public, write_concurrency: true])

  # [allocations since the last collection, threshold]
  @doc false
  def new_counters do
    counters = :atomics.new(2, signed: false)
    :atomics.put(counters, 2, @min_threshold)
    counters
  end

  @doc false
  def count_allocation(%EventLoop{gc: counters}), do: :atomics.add(counters, 1, 1)

  @doc false
  def maybe_collect(%EventLoop{gc: counters} = loop) do
    if :atomics.get(counters, 1) >= :atomics.get(counters, 2), do: collect(loop)
    :ok
  end

  @doc "A disposed channel owner: kept readable while it is among the last #{@graveyard} disposed."
  def dispose(%{loop: %EventLoop{roots: roots} = loop} = object) do
    :ets.insert(roots, {{:graveyard, :erlang.unique_integer([:monotonic])}, object})
    count_allocation(loop)
  end

  @doc "A closed connection: its heap stops being a root and is deleted once nothing in it is reachable."
  def close_heap(%{loop: %EventLoop{pid: pid}, heap: heap} = connection) do
    GenServer.cast(pid, {:close_heap, heap})
    dispose(connection)
  end

  @doc false
  def root_returned(%EventLoop{pid: pid, roots: roots}, owner, value) do
    case objects(value) do
      [] ->
        :ok

      objects ->
        GenServer.cast(pid, {:watch, owner})

        for object <- objects,
            do: :ets.insert(roots, {{{:returned, owner}, :erlang.unique_integer([:monotonic])}, object})

        count = :ets.select_count(roots, [{{{{:returned, owner}, :_}, :_}, [], [true]}])

        if count > @returned_per_process do
          {oldest, _} =
            :ets.select(roots, [{{{{:returned, owner}, :"$1"}, :_}, [], [:"$1"]}], count - @returned_per_process)

          for seq <- oldest, do: :ets.delete(roots, {{:returned, owner}, seq})
        end
    end
  end

  @doc false
  def drop_returned(%EventLoop{roots: roots}, owner), do: :ets.match_delete(roots, {{{:returned, owner}, :_}, :_})

  @doc """
  The calling process no longer holds the heap objects in `value` (a promise handle it awaited).
  """
  def unroot(value) do
    for %{loop: %EventLoop{roots: roots}} = object <- objects(value),
        do: :ets.match_delete(roots, {{{:returned, self()}, :_}, object})

    :ok
  end

  # Runtime objects (reference guids) in a returned value. Channel owners live through their connection.
  defp objects(value), do: value |> refs([], fn obj, acc -> if is_reference(obj.guid), do: [obj | acc], else: acc end)

  @doc """
  Collect now (under the baton): returns `%{objects: live, freed: count, deferred: count}`.
  An unreachable object is freed by the first collection after every unit in flight when it was
  found unreachable has ended, so freeing takes two collections.
  """
  def collect(%EventLoop{roots: roots, gc: counters} = loop) do
    if !EventLoop.held?(), do: raise("GC.collect/1 outside the baton")
    heaps = EventLoop.heaps(loop)
    trim_graveyard(roots)
    objects = snapshot(heaps)
    marked = mark(objects, root_keys(heaps, roots, objects), heaps)
    unreachable = for key <- Map.keys(objects), not Map.has_key?(marked, key), into: MapSet.new(), do: key
    units = units_in_flight(roots)

    {freed, deferred} =
      case :ets.lookup(roots, :gc_batch) do
        [{_, batch_units, candidates}] ->
          if MapSet.disjoint?(batch_units, units) do
            freed = MapSet.intersection(candidates, unreachable)
            for key <- freed, row <- Map.fetch!(objects, key), do: :ets.delete(elem(key, 0), elem(row, 0))
            deferred = MapSet.difference(unreachable, freed)
            :ets.insert(roots, {:gc_batch, units, deferred})
            {MapSet.size(freed), MapSet.size(deferred)}
          else
            {0, MapSet.size(candidates)}
          end

        [] ->
          :ets.insert(roots, {:gc_batch, units, unreachable})
          {0, MapSet.size(unreachable)}
      end

    delete_closed_heaps(loop, heaps)
    :atomics.put(counters, 1, 0)
    # Reachable objects only: counting the garbage awaiting its second collection would compound.
    :atomics.put(counters, 2, max(@min_threshold, 2 * map_size(marked)))
    %{objects: map_size(objects) - freed, freed: freed, deferred: deferred}
  end

  defp trim_graveyard(roots) do
    keys = :ets.select(roots, [{{{:graveyard, :"$1"}, :_}, [], [:"$1"]}])
    for seq <- Enum.take(keys, max(length(keys) - @graveyard, 0)), do: :ets.delete(roots, {:graveyard, seq})
  end

  # %{{heap, guid} => rows}. The tables are ordered: one object's fields are adjacent, then its Map entries.
  defp snapshot(heaps) do
    for {heap, _} <- heaps, rows <- heap |> safe_tab2list() |> Enum.chunk_by(&guid/1), reduce: %{} do
      acc -> Map.update(acc, {heap, guid(hd(rows))}, rows, &(rows ++ &1))
    end
  end

  defp guid(row), do: row |> elem(0) |> elem(0)

  defp safe_tab2list(heap) do
    :ets.tab2list(heap)
  rescue
    ArgumentError -> []
  end

  defp root_keys(heaps, roots, objects) do
    connections = for {heap, :open} <- heaps, do: {heap, :connection}

    # Promises with suspended awaiters: the awaiting unit resumes once they settle.
    awaited =
      for {{_, guid} = key, rows} <- objects,
          is_reference(guid),
          Enum.any?(rows, &match?({{_, :awaiters}, [_ | _]}, &1)),
          do: key

    held =
      for {key, value} <- :ets.tab2list(roots),
          not match?({:unit, _}, key) and key != :gc_batch,
          obj <- refs(value, [], &[&1 | &2]),
          Map.has_key?(heaps, obj.heap),
          do: {obj.heap, obj.guid}

    connections ++ awaited ++ held
  end

  # The marked keys, as a map (key => true).
  defp mark(objects, root_keys, heaps), do: mark(root_keys, objects, heaps, %{})

  defp mark([], _objects, _heaps, marked), do: marked

  defp mark([{heap, guid} = key | rest], objects, heaps, marked) do
    if Map.has_key?(marked, key) or not Map.has_key?(objects, key) do
      mark(rest, objects, heaps, marked)
    else
      found =
        objects
        |> Map.fetch!(key)
        |> Enum.reduce([], fn row, acc ->
          # The key's extra elements are Map keys (objects in JS Maps), then the values.
          [_guid | map_key] = row |> elem(0) |> Tuple.to_list()
          refs([map_key | row |> Tuple.delete_at(0) |> Tuple.to_list()], acc, &[&1 | &2])
        end)
        |> Enum.filter(&Map.has_key?(heaps, &1.heap))
        |> Enum.map(&{&1.heap, &1.guid})

      # A channel owner's protocol emitter (`ChannelOwner._channel/1`) lives as long as the owner.
      found = if is_binary(guid), do: [{heap, {:channel, guid}} | found], else: found
      mark(found ++ rest, objects, heaps, Map.put(marked, key, true))
    end
  end

  # Heap objects (`%{guid: _, heap: _}`) in a term, closures included.
  defp refs(%{guid: guid, heap: heap} = obj, acc, fun) when guid != nil and is_reference(heap),
    do: obj |> Map.values() |> refs(fun.(obj, acc), fun)

  defp refs(map, acc, fun) when is_map(map),
    do: :maps.fold(fn k, v, acc -> refs(v, refs(k, acc, fun), fun) end, acc, map)

  defp refs([head | tail], acc, fun), do: refs(tail, refs(head, acc, fun), fun)
  defp refs(tuple, acc, fun) when is_tuple(tuple), do: refs(Tuple.to_list(tuple), acc, fun)

  defp refs(f, acc, fun) when is_function(f) do
    case :erlang.fun_info(f, :env) do
      {:env, env} -> refs(env, acc, fun)
      _ -> acc
    end
  end

  defp refs(_other, acc, _fun), do: acc

  defp units_in_flight(roots) do
    for {{:unit, unit}, pid} <- :ets.select(roots, [{{{:unit, :_}, :_}, [], [:"$_"]}]), reduce: MapSet.new() do
      units ->
        # A process that died in a unit (a killed caller) holds nothing any more.
        if Process.alive?(pid) do
          MapSet.put(units, unit)
        else
          :ets.delete(roots, {:unit, unit})
          units
        end
    end
  end

  defp delete_closed_heaps(%EventLoop{pid: pid}, heaps) do
    for {heap, :closed} <- heaps, :ets.info(heap, :size) == 0 do
      :ets.delete(heap)
      GenServer.cast(pid, {:forget_heap, heap})
    end
  end
end
