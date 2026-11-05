defmodule PlaywrightEx.Client.EventEmitter do
  @upstream "packages/playwright-core/src/client/eventEmitter.ts"
  @moduledoc """
  Port of `#{@upstream}` (upstream's re-implementation of Node's EventEmitter), on top of the
  connection (`PlaywrightEx.Runtime.Conn`): `_events` is a Map field from the event type to its
  listener entries, written in the connection process.

  `emit` runs in the connection: each listener becomes a dispatch step, run in order behind the
  barrier (the connection waits until the listener returns or first awaits), as JS runs
  listeners synchronously inside `emit`. Listener kinds:

    * internal (the default, for the client's own listeners): a process per event.
    * user (added under `PlaywrightEx.Runtime.Facade.listen/1`, i.e. through the facade): a
      process per subscription, which runs its events one at a time (FIFO).
    * sync (`on_sync/3`): runs in the connection process, for pure state updates (it must not
      await).
    * mailbox (`subscribe/3`): the event is a message to the subscribing process (a promise), for
      waiters.

  A listener that awaited is still running when `emit` returns: its invocation is pending
  (`_pendingHandlers`, kept by the connection) for `removeAllListeners(type, %{behavior: ...})`.
  A listener is a 1-arity function or an `{id, fun}` pair (so a closure can remove itself:
  JS `let listener = ...`), removed by the listener, the pair or its id.

  Trimmed to what the client and the facade use, as the other language clients (Python's
  `pyee`, Java's listener holder): no Node extras (max listeners and the leak warning, the
  `newListener`/`removeListener` meta events, listener type checks, `rawListeners` & co.).
  Elixir has no variadic functions, so `emit` takes one event argument and listeners one
  parameter (as every listener in the client and the facade).

  Deviation: an async user listener queues later events of its subscription behind it; JS
  interleaves them.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Promise
  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.TargetClosedError

  defstruct [:guid, :conn, :table]

  # "class Foo extends EventEmitter": inject the inherited methods.
  defmacro __using__(_opts) do
    quote do
      defdelegate emit(this, type, arg \\ nil), to: PlaywrightEx.Client.EventEmitter
      defdelegate add_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate on(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate prepend_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate once(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate remove_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate off(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate remove_all_listeners(this, type \\ nil, options \\ nil), to: PlaywrightEx.Client.EventEmitter
      defdelegate on_sync(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate subscribe(this, type, predicate \\ nil), to: PlaywrightEx.Client.EventEmitter

      defoverridable add_listener: 3,
                     on: 3,
                     once: 3,
                     prepend_listener: 3,
                     remove_listener: 3,
                     off: 3,
                     subscribe: 2,
                     subscribe: 3
    end
  end

  # this._events = Object.create(null); this._eventsCount = 0;  -- not ported: `_events` is a Map field (absent rows: empty), `_eventsCount` its size
  # this.on = this.addListener; this.off = this.removeListener; (see on/3, off/3)
  # Elixir only: `owner` owns its rows (`nil`: a process-local emitter, whose listeners run in `emit`).
  def new(owner \\ nil), do: new_object(__MODULE__, owner)

  # setMaxListeners, getMaxListeners  -- not ported: unused by the client (no listener leak warning)

  def emit(this, type, arg \\ nil) do
    zone = Zones.current_zone()
    atomic(this, fn -> _emit(this, type, arg, zone) end)
  end

  defp _emit(%{table: nil} = this, type, arg, _zone) do
    case map_get(this, :_events, type) do
      nil ->
        false

      handler ->
        _remove_once(this, type, handler)
        for entry <- handler, do: _call_handler_local(this, entry, arg)
        true
    end
  end

  defp _emit(this, type, arg, zone) do
    handler =
      try do
        map_get(this, :_events, type)
      rescue
        # A disposed object emits nothing.
        TargetClosedError -> nil
      end

    case handler do
      nil ->
        false

      handler ->
        _remove_once(this, type, handler)
        for entry <- handler, do: _call_handler(this, type, entry, arg, zone)
        true
    end
  end

  defp _remove_once(this, type, handler) do
    case Enum.reject(handler, & &1.once) do
      ^handler -> :ok
      [] -> map_delete(this, :_events, type)
      rest -> map_set(this, :_events, type, rest)
    end
  end

  # In the connection: the listener becomes a dispatch step (see `PlaywrightEx.Runtime.Conn`).
  defp _call_handler(this, type, entry, arg, zone) do
    case entry.kind do
      :internal ->
        Conn.push_step({:internal, entry.fun, arg, this, type, zone})

      :sync ->
        Conn.push_step({:sync, entry.fun, arg, this})

      :user ->
        Conn.push_step({:user, entry.pid, entry.fun, arg, this, type, zone})
        if entry.once, do: Conn.push_step({:stop, entry.pid})

      :mailbox ->
        Conn.push_step({:mailbox, entry.pid, entry.ref, arg})
    end
  end

  defp _call_handler_local(this, %{kind: :mailbox} = entry, arg) do
    send(entry.pid, {:pw, entry.ref, {:event, arg}})
    this
  end

  defp _call_handler_local(this, entry, arg), do: Conn.invoke(entry.fun, arg, this)

  def add_listener(this, type, listener), do: _add_listener(this, type, listener, false)

  def on(this, type, listener), do: _add_listener(this, type, listener, false)

  # The listener check, the newListener meta event and the listener leak check: not ported (unused by the client).
  defp _add_listener(this, type, listener, prepend, once \\ false) do
    entry = entry(this, listener, once)
    atomic(this, fn -> _insert(this, type, entry, prepend) end)
    this
  end

  @doc false
  # A listener as stored, built in the adding process: `%{kind, id, fun, once, pid, ref}`. A user
  # listener (see `PlaywrightEx.Runtime.Facade.listen/1`) gets its subscription process.
  def entry(this, listener, once \\ false) do
    {id, fun} = if is_tuple(listener), do: listener, else: {listener, listener}

    if Process.get(:pw_user_listener) && this.table != nil,
      do: %{kind: :user, id: id, fun: fun, once: once, pid: Conn.subscription(this.conn)},
      else: %{kind: :internal, id: id, fun: fun, once: once}
  end

  @doc false
  # In the connection (or on a local emitter): adds an entry; a disposed emitter drops it.
  def _insert(this, type, entry, prepend) do
    if alive?(this) do
      existing = map_get(this, :_events, type) || []
      map_set(this, :_events, type, if(prepend, do: [entry | existing], else: existing ++ [entry]))
    else
      _stop(entry)
    end

    :ok
  end

  defp _stop(%{kind: :user, pid: pid}), do: send(pid, :pw_stop)
  defp _stop(_entry), do: :ok

  def prepend_listener(this, type, listener), do: _add_listener(this, type, listener, true)

  # Upstream wraps the listener (`_onceWrap`, `OnceWrapper`) and calls `this.on(...)`: here the
  # entry is marked `once` and `emit` removes it (in the connection, so it fires once).
  def once(this, type, listener), do: _add_listener(this, type, listener, false, true)

  @doc """
  Elixir only: `on` for a listener that runs in the connection process (a pure state update; it
  must not await). Upstream: any listener.
  """
  def on_sync(this, type, listener) do
    {id, fun} = if is_tuple(listener), do: listener, else: {listener, listener}
    atomic(this, fn -> _insert(this, type, %{kind: :sync, id: id, fun: fun, once: false}, false) end)
    this
  end

  @doc """
  Elixir only: a listener whose events are messages to the calling process, as a promise of the
  first event `predicate` accepts (`nil`: any; it may return a promise, awaited). The promise's
  source is removed when it settles (or when the waiter disposes it, `Promise.cancel/1`).
  """
  def subscribe(this, type, predicate \\ nil) do
    {entry, promise} = _subscription(this, type, predicate)
    atomic(this, fn -> _insert(this, type, entry, false) end)
    promise
  end

  @doc false
  def _subscription(this, type, predicate) do
    ref = make_ref()
    entry = %{kind: :mailbox, id: ref, fun: nil, once: false, pid: self(), ref: ref}

    handler = fn
      {:event, arg} ->
        try do
          # await predicate(eventArg): a returned promise is awaited
          result = if predicate, do: predicate.(arg)
          result = if is_struct(result, Promise), do: Promise.await(result), else: result
          if predicate && !result, do: :continue, else: {:ok, arg}
        rescue
          e -> {:error, e}
        end

      other ->
        other
    end

    cancel = fn ->
      try do
        impl(this).remove_listener(this, type, ref)
      rescue
        TargetClosedError -> :ok
      end

      Promise.flush(ref)
    end

    {entry, Promise.from_messages(ref, handler, cancel)}
  end

  # prependOnceListener  -- not ported: unused by the client

  # The removeListener meta event  -- not ported: unused by the client
  def remove_listener(this, type, listener) do
    atomic(this, fn -> _take(this, type, listener) end)
    this
  end

  @doc false
  # In the connection: removes the last entry matching `listener` (its fun, id or `{id, fun}`).
  def _take(this, type, listener) do
    list =
      try do
        map_get(this, :_events, type) || []
      rescue
        TargetClosedError -> []
      end

    position = list |> Enum.reverse() |> Enum.find_index(&(listener in [&1.id, &1.fun, {&1.id, &1.fun}]))

    if position != nil do
      index = length(list) - 1 - position
      _stop(Enum.at(list, index))

      case List.delete_at(list, index) do
        [] -> map_delete(this, :_events, type)
        rest -> map_set(this, :_events, type, rest)
      end
    end

    position != nil
  end

  def off(this, type, listener), do: remove_listener(this, type, listener)

  # With `options`, upstream returns a promise (`await page.removeAllListeners(type, options)`):
  # awaited here, `nil` then.
  def remove_all_listeners(this, type \\ nil, options \\ nil) do
    _remove_all_listeners(this, type)

    cond do
      !options ->
        this

      options[:behavior] == "wait" ->
        me = self()
        ref = make_ref()
        put(this, :_rejectionHandler, fn error -> send(me, {ref, error}) end)
        _wait_for(this, type)
        errors = _collect(ref)
        if errors != [], do: raise(hd(errors))
        nil

      true ->
        if options[:behavior] == "ignoreErrors", do: put(this, :_rejectionHandler, fn _ -> nil end)
        nil
    end
  end

  defp _collect(ref) do
    receive do
      {^ref, error} -> [error | _collect(ref)]
    after
      0 -> []
    end
  end

  # Only the "not listening for removeListener" branch: the meta event is not ported.
  defp _remove_all_listeners(this, type) do
    atomic(this, fn ->
      entries = if type == nil, do: map_values(this, :_events), else: [map_get(this, :_events, type) || []]
      for list <- entries, entry <- list, do: _stop(entry)
      if type == nil, do: map_clear(this, :_events), else: map_delete(this, :_events, type)
    end)
  end

  # listeners, rawListeners  -- not ported: unused by the client

  def listener_count(this, type) do
    length(map_get(this, :_events, type) || [])
  rescue
    TargetClosedError -> 0
  end

  # eventNames  -- not ported: unused by the client

  # `Promise.all` of the pending handlers: the connection waits until none runs.
  defp _wait_for(%{table: nil}, _type), do: :ok
  defp _wait_for(this, type), do: Conn.wait_pending(this, type)

  # _listeners, checkListener  -- not ported: unused by the client

  # OnceWrapper  -- ported as `once` entries (see once/3)

  # unwrapListener, unwrapListeners  -- not ported: unused by the client (listeners and the meta events only)
end
