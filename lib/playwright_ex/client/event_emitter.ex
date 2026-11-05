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

  Deviations: Elixir has no variadic functions, so `emit` takes one event argument and
  listeners one parameter (as every listener in the client and the facade); the meta events
  `"newListener"` and `"removeListener"` pass their two arguments as one `{type, listener}`.
  Node keeps a single listener unwrapped and the listener array's `warned` flag as a property:
  here an entry list per type and the `_warned` Map field.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.EventEmitter.OnceWrapper
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise

  require Logger

  defstruct [:guid, :loop, :heap]

  # "class Foo extends EventEmitter": inject the inherited methods.
  defmacro __using__(_opts) do
    quote do
      defdelegate set_max_listeners(this, n), to: PlaywrightEx.Client.EventEmitter
      defdelegate get_max_listeners(this), to: PlaywrightEx.Client.EventEmitter
      defdelegate emit(this, type, arg \\ nil), to: PlaywrightEx.Client.EventEmitter
      defdelegate add_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate on(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate prepend_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate once(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate prepend_once_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate remove_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate off(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate remove_all_listeners(this, type \\ nil, options \\ nil), to: PlaywrightEx.Client.EventEmitter
      defdelegate listeners(this, type), to: PlaywrightEx.Client.EventEmitter
      defdelegate raw_listeners(this, type), to: PlaywrightEx.Client.EventEmitter
      defdelegate listener_count(this, type), to: PlaywrightEx.Client.EventEmitter
      defdelegate event_names(this), to: PlaywrightEx.Client.EventEmitter
      defoverridable add_listener: 3, on: 3, prepend_listener: 3, remove_listener: 3, off: 3, remove_all_listeners: 3
    end
  end

  # this._events = Object.create(null); this._eventsCount = 0;  -- not ported: `_events` is a Map field (absent rows: empty), `_eventsCount` its size
  # this.on = this.addListener; this.off = this.removeListener; (see on/3, off/3)
  def new, do: new_object(__MODULE__)

  def set_max_listeners(this, n) do
    if !is_number(n) or n < 0,
      do:
        raise(
          ArgumentError,
          ~s(The value of "n" is out of range. It must be a non-negative number. Received #{_string(n)}.)
        )

    put(this, :_maxListeners, n)
    this
  end

  def get_max_listeners(this) do
    max_listeners = get(this, :_maxListeners)
    if max_listeners == nil, do: default_max_listeners(), else: max_listeners
  end

  # Node's `EventEmitter.defaultMaxListeners` (its `events` module), which getMaxListeners reads:
  # process-wide, as in Node.
  def default_max_listeners, do: :persistent_term.get({__MODULE__, :defaultMaxListeners}, 10)

  def set_default_max_listeners(n) do
    if !is_number(n) or n < 0,
      do:
        raise(
          ArgumentError,
          ~s(The value of "defaultMaxListeners" is out of range. It must be a non-negative number. Received #{_string(n)})
        )

    :persistent_term.put({__MODULE__, :defaultMaxListeners}, n)
  end

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

  defp _add_listener(this, type, listener, prepend) do
    check_listener(listener)
    entry = _entry(listener)

    EventLoop.with_baton(this.loop, fn ->
      # To avoid recursion in the case that type === "newListener"! Before
      # adding it to the listeners, first emit "newListener".
      if map_get(this, :_events, "newListener") != nil,
        do: emit(this, "newListener", {type, unwrap_listener(entry)})

      # Read after the emit: a newListener handler could have added listeners.
      case map_get(this, :_events, type) do
        nil ->
          map_set(this, :_events, type, [entry])

        existing ->
          existing = if prepend, do: [entry | existing], else: existing ++ [entry]
          map_set(this, :_events, type, existing)

          # Check for listener leak
          m = get_max_listeners(this)

          if m > 0 and length(existing) > m and !map_get(this, :_warned, type) do
            map_set(this, :_warned, type, true)
            # No error code for this since it is a Warning
            message =
              "Possible EventEmitter memory leak detected. #{length(existing)} #{_string(type)} listeners added. " <>
                "Use emitter.setMaxListeners() to increase limit"

            # w.name = 'MaxListenersExceededWarning'; w.emitter = this; w.type = type; w.count = ...;
            # console.warn(w): Logger.warning here, with the line console.warn prints.
            if !_is_under_test(), do: Logger.warning("MaxListenersExceededWarning: " <> message)
          end
      end
    end)

    this
  end

  # A listener as stored: `%{id, fun, listener}`, `listener` being what `listeners/2` returns.
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
    check_listener(listener)
    impl(this).on(this, type, OnceWrapper.new(this, type, listener).wrapperFunction)
    this
  end

  def prepend_once_listener(this, type, listener) do
    check_listener(listener)
    impl(this).prepend_listener(this, type, OnceWrapper.new(this, type, listener).wrapperFunction)
    this
  end

  def remove_listener(this, type, listener) do
    # The id of an `{id, fun}` listener is any term but undefined and null.
    if listener in [nil, :null], do: check_listener(listener)

    EventLoop.with_baton(this.loop, fn ->
      list = map_get(this, :_events, type) || []

      position =
        list |> Enum.reverse() |> Enum.find_index(&(listener in [&1.id, &1.fun, wrapped_listener(&1), _raw(&1)]))

      if position != nil do
        position = length(list) - 1 - position
        removed = Enum.at(list, position)

        case List.delete_at(list, position) do
          [] ->
            map_delete(this, :_events, type)
            map_delete(this, :_warned, type)

          rest ->
            map_set(this, :_events, type, rest)
            # events[type] = list[0]: the array (and its `warned`) is gone.
            if length(rest) == 1, do: map_delete(this, :_warned, type)
        end

        if map_get(this, :_events, "removeListener") != nil,
          do: emit(this, "removeListener", {type, unwrap_listener(removed)})
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

  defp _remove_all_listeners(this, type) do
    EventLoop.with_baton(this.loop, fn ->
      cond do
        # not listening for removeListener, no need to emit
        map_get(this, :_events, "removeListener") == nil ->
          if type == nil do
            map_clear(this, :_events)
            map_clear(this, :_warned)
          else
            map_delete(this, :_events, type)
            map_delete(this, :_warned, type)
          end

        # emit removeListener for all listeners on all events
        type == nil ->
          # Object.keys: symbols (references here) are left out.
          for key <- map_keys(this, :_events),
              is_binary(key),
              key != "removeListener",
              do: _remove_all_listeners(this, key)

          _remove_all_listeners(this, "removeListener")
          map_clear(this, :_events)
          map_clear(this, :_warned)

        true ->
          # LIFO order. Virtual `this.removeListener(...)`: channel owners override it.
          for entry <- Enum.reverse(map_get(this, :_events, type) || []),
              do: impl(this).remove_listener(this, type, _raw(entry))
      end
    end)
  end

  def listeners(this, type), do: _listeners(this, type, true)

  def raw_listeners(this, type), do: _listeners(this, type, false)

  def listener_count(this, type), do: length(map_get(this, :_events, type) || [])

  def event_names(this), do: map_keys(this, :_events)

  defp _wait_for(this, type) do
    promises =
      if type,
        do: map_get(this, :_pendingHandlers, type) || [],
        else: Enum.concat(map_values(this, :_pendingHandlers))

    Promise.all(promises)
  end

  defp _listeners(target, type, unwrap) do
    listener = map_get(target, :_events, type) || []
    if unwrap, do: unwrap_listeners(listener), else: Enum.map(listener, &_raw/1)
  end

  # TypeError: ArgumentError. A function of another arity is rejected too (listeners take one
  # argument), with its arity after `typeof`.
  defp check_listener(listener) do
    valid =
      case listener do
        {_id, fun} -> is_function(fun, 1)
        {_id, fun, _wrapped} -> is_function(fun, 1)
        fun -> is_function(fun, 1)
      end

    if !valid,
      do:
        raise(ArgumentError, ~s(The "listener" argument must be of type Function. Received type ) <> _typeof(listener))
  end

  # JS `typeof` of the Elixir form of a value (`nil` is undefined, `:null` null, references symbols).
  defp _typeof(value) do
    cond do
      value == nil -> "undefined"
      is_boolean(value) -> "boolean"
      is_number(value) -> "number"
      is_binary(value) -> "string"
      is_function(value) -> "function of arity #{:erlang.fun_info(value)[:arity]}"
      (is_atom(value) and value != :null) or is_reference(value) -> "symbol"
      true -> "object"
    end
  end

  # String(value) / '' + value
  defp _string(value) when is_binary(value) or is_number(value), do: to_string(value)
  defp _string(value), do: inspect(value)

  # isUnderTest() (utils/debug.ts): getAsBooleanFromENV('PWTEST_UNDER_TEST')
  defp _is_under_test, do: System.get_env("PWTEST_UNDER_TEST") not in [nil, "", "false", "0"]

  # OnceWrapper  -- ported as EventEmitter.OnceWrapper

  # The listener entries: `wrapped_listener` is JS `.listener` (set on a OnceWrapper's function only).
  defp unwrap_listener(l), do: wrapped_listener(l) || l.fun

  defp unwrap_listeners(arr), do: Enum.map(arr, &(wrapped_listener(&1) || &1.fun))

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
