defmodule PlaywrightEx.Client.EventEmitter do
  @upstream "packages/playwright-core/src/client/eventEmitter.ts"
  @moduledoc """
  Port of `#{@upstream}` (upstream's re-implementation of Node's EventEmitter), on top of the
  heap: `_events` is a Map field from the event type to its listener entries.

  `emit` runs under the baton and hands it to each listener in turn (fresh process, see
  `PlaywrightEx.Runtime.EventLoop.spawn_handoff/1`) until the listener returns or awaits, as JS
  runs listeners synchronously inside `emit`. A listener that awaited is still running when
  `emit` returns: that is JS's returned promise, kept in `_pendingHandlers` for
  `removeAllListeners(type, %{behavior: ...})`. A listener is a 1-arity function or an
  `{id, fun}` pair (so a closure can remove itself: JS `let listener = ...`), removed by the
  listener, the pair or its id.

  Trimmed to what the client and the facade use, as the other language clients (Python's
  `pyee`, Java's listener holder): no Node extras (max listeners and the leak warning, the
  `newListener`/`removeListener` meta events, listener type checks, `rawListeners` & co.).
  Elixir has no variadic functions, so `emit` takes one event argument and listeners one
  parameter (as every listener in the client and the facade). Node keeps a single listener
  unwrapped: here an entry list per type.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.EventEmitter.OnceWrapper
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise

  defstruct [:guid, :loop, :heap]

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
      defoverridable add_listener: 3, on: 3, prepend_listener: 3, remove_listener: 3, off: 3
    end
  end

  # this._events = Object.create(null); this._eventsCount = 0;  -- not ported: `_events` is a Map field (absent rows: empty), `_eventsCount` its size
  # this.on = this.addListener; this.off = this.removeListener; (see on/3, off/3)
  def new, do: new_object(__MODULE__)

  # setMaxListeners, getMaxListeners  -- not ported: unused by the client (no listener leak warning)

  def emit(this, type, arg \\ nil) do
    EventLoop.with_baton(this.loop, fn ->
      case map_get(this, :_events, type) do
        nil ->
          false

        handler ->
          for entry <- handler, do: _call_handler(this, type, entry.fun, arg)
          true
      end
    end)
  end

  # A returned `%Promise{}` is not adopted: an Elixir listener that awaits is pending itself.
  defp _call_handler(this, type, handler, arg) do
    promise = Promise.new()

    EventLoop.spawn_handoff(fn ->
      try do
        Promise.resolve(promise, handler.(arg))
      catch
        kind, reason ->
          error = Exception.normalize(kind, reason, __STACKTRACE__)
          rejection_handler = get(this, :_rejectionHandler)
          if rejection_handler, do: rejection_handler.(error)
          Promise.reject(promise, error)
          # else throw e;  -- uncaught: EventLoop.spawn_handoff/1 logs it
          if !rejection_handler, do: :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)

    if get(promise, :state) == :pending do
      map_set(this, :_pendingHandlers, type, (map_get(this, :_pendingHandlers, type) || []) ++ [promise])

      Promise.on_settled(promise, fn _ ->
        map_set(this, :_pendingHandlers, type, List.delete(map_get(this, :_pendingHandlers, type) || [], promise))
      end)
    end

    nil
  end

  def add_listener(this, type, listener), do: _add_listener(this, type, listener, false)

  def on(this, type, listener), do: _add_listener(this, type, listener, false)

  # The listener check, the newListener meta event and the listener leak check: not ported (unused by the client).
  defp _add_listener(this, type, listener, prepend) do
    entry = _entry(listener)

    EventLoop.with_baton(this.loop, fn ->
      existing = map_get(this, :_events, type) || []
      map_set(this, :_events, type, if(prepend, do: [entry | existing], else: existing ++ [entry]))
    end)

    this
  end

  # A listener as stored: `%{id, fun, listener}`, `listener` being JS `.listener` (the
  # wrapped listener of a once wrapper, else `fun`).
  defp _entry(listener) do
    case listener do
      # A `OnceWrapper`'s function with the wrapped listener (JS `wrapperFunction.listener`).
      {id, fun, wrapped} -> %{id: id, fun: fun, listener: wrapped}
      {id, fun} -> %{id: id, fun: fun, listener: fun}
      fun -> %{id: fun, fun: fun, listener: fun}
    end
  end

  # The listener as added (JS: the function in `_events`).
  defp _raw(%{id: id, fun: fun, listener: listener}) do
    cond do
      listener != fun -> {id, fun, listener}
      id != fun -> {id, fun}
      true -> fun
    end
  end

  def prepend_listener(this, type, listener), do: _add_listener(this, type, listener, true)

  # Upstream calls `this.on(...)` (virtual dispatch); here: dispatch via the struct module.
  def once(this, type, listener) do
    impl(this).on(this, type, OnceWrapper.new(this, type, listener).wrapperFunction)
    this
  end

  # prependOnceListener  -- not ported: unused by the client

  # The removeListener meta event  -- not ported: unused by the client
  def remove_listener(this, type, listener) do
    EventLoop.with_baton(this.loop, fn ->
      list = map_get(this, :_events, type) || []

      position =
        list |> Enum.reverse() |> Enum.find_index(&(listener in [&1.id, &1.fun, wrapped_listener(&1), _raw(&1)]))

      if position != nil do
        case List.delete_at(list, length(list) - 1 - position) do
          [] -> map_delete(this, :_events, type)
          rest -> map_set(this, :_events, type, rest)
        end
      end
    end)

    this
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
        errors = new_object(__MODULE__)
        put(errors, :errors, [])
        put(this, :_rejectionHandler, fn error -> update(errors, :errors, &(&1 ++ [error])) end)

        Promise.await(
          Promise.then_(_wait_for(this, type), fn _ ->
            if get(errors, :errors) != [], do: raise(hd(get(errors, :errors)))
          end)
        )

        nil

      true ->
        if options[:behavior] == "ignoreErrors", do: put(this, :_rejectionHandler, fn _ -> nil end)
        nil
    end
  end

  # Only the "not listening for removeListener" branch: the meta event is not ported.
  defp _remove_all_listeners(this, type) do
    EventLoop.with_baton(this.loop, fn ->
      if type == nil, do: map_clear(this, :_events), else: map_delete(this, :_events, type)
    end)
  end

  # listeners, rawListeners  -- not ported: unused by the client

  def listener_count(this, type), do: length(map_get(this, :_events, type) || [])

  # eventNames  -- not ported: unused by the client

  defp _wait_for(this, type) do
    promises =
      if type,
        do: map_get(this, :_pendingHandlers, type) || [],
        else: Enum.concat(map_values(this, :_pendingHandlers))

    Promise.all(promises)
  end

  # _listeners, checkListener  -- not ported: unused by the client

  # OnceWrapper  -- ported as EventEmitter.OnceWrapper

  # unwrapListener, unwrapListeners  -- not ported: unused by the client (listeners and the meta events only)

  # The listener entries: `wrapped_listener` is JS `.listener` (set on a OnceWrapper's function only).
  defp wrapped_listener(l), do: if(l.listener != l.fun, do: l.listener)
end

defmodule PlaywrightEx.Client.EventEmitter.OnceWrapper do
  @moduledoc false
  import PlaywrightEx.Runtime.Heap

  # `wrapperFunction` is `{id, fun, listener}`: it keeps the listener's id, so
  # `removeListener(type, listener)` finds it by the listener's id too (JS `wrapperFunction.listener`).
  defstruct [:guid, :loop, :heap, :wrapperFunction, :_listener, :_eventEmitter, :_eventType]

  def new(event_emitter, event_type, listener) do
    {id, fun} = if is_tuple(listener), do: listener, else: {listener, listener}

    this = %__MODULE__{
      guid: make_ref(),
      loop: event_emitter.loop,
      heap: event_emitter.heap,
      _listener: fun,
      _eventEmitter: event_emitter,
      _eventType: event_type
    }

    %{this | wrapperFunction: _wrapper_function(this, id)}
  end

  # `this._handle.bind(this)`, with `.listener`. Rebuilt in `_handle` (it closes over `this`):
  # closures over the same code and environment are equal.
  defp _wrapper_function(this, id), do: {id, &_handle(this, id, &1), this._listener}

  defp _handle(this, id, arg) do
    if !get(this, :_fired) do
      put(this, :_fired, true)
      impl(this._eventEmitter).remove_listener(this._eventEmitter, this._eventType, _wrapper_function(this, id))
      this._listener.(arg)
    end
  end
end
