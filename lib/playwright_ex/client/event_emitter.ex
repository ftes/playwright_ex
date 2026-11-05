defmodule PlaywrightEx.Client.EventEmitter do
  @upstream "packages/playwright-core/src/client/eventEmitter.ts"
  @moduledoc """
  Port of `#{@upstream}`, not line-equivalent by design: upstream re-implements Node's
  EventEmitter (listener arrays, newListener/removeListener meta events, leak warnings).
  This keeps the public surface (same names, same order) on top of the heap.

  `emit` runs under the baton and hands it to each listener in turn (fresh process, see
  `PlaywrightEx.Runtime.EventLoop.spawn_handoff/1`) until the listener returns or awaits, as JS
  runs listeners synchronously inside `emit`. A listener that awaited is still running when
  `emit` returns: that is JS's returned promise, kept in `_pendingHandlers` for
  `removeAllListeners(type, %{behavior: ...})`. A listener is a 1-arity function or an
  `{id, fun}` pair (so a closure can remove itself: JS `let listener = ...`).

  Not ported: `setMaxListeners`/`getMaxListeners` (no leak warnings), multiple `emit` args.
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
      defdelegate prepend_once_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate remove_listener(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate off(this, type, listener), to: PlaywrightEx.Client.EventEmitter
      defdelegate remove_all_listeners(this, type \\ nil, options \\ nil), to: PlaywrightEx.Client.EventEmitter
      defdelegate listeners(this, type), to: PlaywrightEx.Client.EventEmitter
      defdelegate listener_count(this, type), to: PlaywrightEx.Client.EventEmitter
      defdelegate event_names(this), to: PlaywrightEx.Client.EventEmitter
      defoverridable add_listener: 3, on: 3, prepend_listener: 3, remove_listener: 3, off: 3, remove_all_listeners: 3
    end
  end

  def new, do: new_object(__MODULE__)

  def emit(this, type, arg \\ nil) do
    EventLoop.with_baton(this.loop, fn ->
      handler = map_get(this, :_events, type) || []

      for entry <- handler, do: _call_handler(this, type, entry.fun, arg)

      handler != []
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
    {id, fun} = if is_tuple(listener), do: listener, else: {listener, listener}
    entry = %{id: id, fun: fun}

    EventLoop.with_baton(this.loop, fn ->
      map_set(
        this,
        :_events,
        type,
        if(prepend, do: [entry], else: []) ++
          (map_get(this, :_events, type) || []) ++ if(prepend, do: [], else: [entry])
      )
    end)

    this
  end

  def prepend_listener(this, type, listener), do: _add_listener(this, type, listener, true)

  # Upstream calls `this.on(...)` (virtual dispatch); here: dispatch via the struct module.
  def once(this, type, listener) do
    this.__struct__.on(this, type, OnceWrapper.new(this, type, listener).wrapperFunction)
    this
  end

  def prepend_once_listener(this, type, listener) do
    this.__struct__.prepend_listener(this, type, OnceWrapper.new(this, type, listener).wrapperFunction)
    this
  end

  def remove_listener(this, type, listener) do
    EventLoop.with_baton(this.loop, fn ->
      list = map_get(this, :_events, type) || []

      case list |> Enum.reverse() |> Enum.find(&(&1.id == listener or &1.fun == listener)) do
        nil -> nil
        entry -> _remove_entry(this, type, entry)
      end
    end)

    this
  end

  defp _remove_entry(this, type, entry) do
    list = map_get(this, :_events, type) || []
    index = length(list) - 1 - (list |> Enum.reverse() |> Enum.find_index(&(&1 == entry)))
    rest = List.delete_at(list, index)
    if rest == [], do: map_delete(this, :_events, type), else: map_set(this, :_events, type, rest)
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

  # Virtual `this.removeListener(...)` per listener, LIFO, as upstream does when anyone
  # listens for 'removeListener' (channel owners override it to update subscriptions).
  defp _remove_all_listeners(this, type) do
    types = if type == nil, do: event_names(this), else: [type]

    for type <- types,
        entry <- Enum.reverse(map_get(this, :_events, type) || []),
        do: this.__struct__.remove_listener(this, type, entry.id)
  end

  def listeners(this, type), do: Enum.map(map_get(this, :_events, type) || [], & &1.fun)

  # rawListeners  -- not ported: listeners are stored unwrapped

  def listener_count(this, type), do: length(map_get(this, :_events, type) || [])

  def event_names(%{heap: heap, guid: guid}),
    do: heap |> :ets.match({{guid, :_events, :"$1"}, :_}) |> Enum.map(&hd/1)

  defp _wait_for(this, type) do
    promises =
      if type,
        do: map_get(this, :_pendingHandlers, type) || [],
        else: Enum.concat(map_values(this, :_pendingHandlers))

    Promise.all(promises)
  end

  # _listeners  -- ported as listeners/2
  # checkListener  -- not ported: listeners are functions or {id, fun} by type
  # OnceWrapper  -- ported as EventEmitter.OnceWrapper
  # unwrapListener, unwrapListeners, wrappedListener  -- not ported: listeners are stored unwrapped
end

defmodule PlaywrightEx.Client.EventEmitter.OnceWrapper do
  @moduledoc false
  import PlaywrightEx.Runtime.Heap

  # The wrapper keeps the listener's id, so `removeListener(type, listener)` finds it (JS
  # `wrapperFunction.listener`).
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

    %{this | wrapperFunction: {id, &_handle(this, id, &1)}}
  end

  defp _handle(this, id, arg) do
    if !get(this, :_fired) do
      put(this, :_fired, true)
      this._eventEmitter.__struct__.remove_listener(this._eventEmitter, this._eventType, id)
      this._listener.(arg)
    end
  end
end
