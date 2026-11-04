defmodule PlaywrightEx.Client.EventEmitter do
  @upstream "packages/playwright-core/src/client/eventEmitter.ts"
  @moduledoc """
  Port of `#{@upstream}`, not line-equivalent by design: upstream re-implements Node's
  EventEmitter (listener arrays, newListener/removeListener meta events, leak warnings).
  This keeps the public surface (same names, same order) on top of the heap.

  `emit` runs under the baton and hands it to each listener in turn (fresh process, see
  `PlaywrightEx.Runtime.EventLoop.spawn_handoff/1`) until the listener returns or awaits, as JS
  runs listeners synchronously inside `emit`. A listener is a 1-arity function or an
  `{id, fun}` pair (so a closure can remove itself: JS `let listener = ...`).

  Not ported: `setMaxListeners`/`getMaxListeners` (no leak warnings), the `behavior` option of
  `removeAllListeners` (pending async handlers are not tracked yet), multiple `emit` args.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Runtime.EventLoop

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
      defdelegate remove_all_listeners(this, type \\ nil), to: PlaywrightEx.Client.EventEmitter
      defdelegate listeners(this, type), to: PlaywrightEx.Client.EventEmitter
      defdelegate listener_count(this, type), to: PlaywrightEx.Client.EventEmitter
      defdelegate event_names(this), to: PlaywrightEx.Client.EventEmitter
      defoverridable add_listener: 3, on: 3, prepend_listener: 3, remove_listener: 3, off: 3, remove_all_listeners: 2
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

  defp _call_handler(_this, _type, handler, arg), do: EventLoop.spawn_handoff(fn -> handler.(arg) end)

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
    {id, fun} = if is_tuple(listener), do: listener, else: {listener, listener}
    this.__struct__.on(this, type, {id, fn arg -> this.__struct__.remove_listener(this, type, id) && fun.(arg) end})
    this
  end

  def prepend_once_listener(this, type, listener) do
    {id, fun} = if is_tuple(listener), do: listener, else: {listener, listener}

    this.__struct__.prepend_listener(
      this,
      type,
      {id, fn arg -> this.__struct__.remove_listener(this, type, id) && fun.(arg) end}
    )

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

  # Virtual `this.removeListener(...)` per listener, LIFO, as upstream does when anyone
  # listens for 'removeListener' (channel owners override it to update subscriptions).
  def remove_all_listeners(this, type \\ nil) do
    types = if type == nil, do: event_names(this), else: [type]

    for type <- types,
        entry <- Enum.reverse(map_get(this, :_events, type) || []),
        do: this.__struct__.remove_listener(this, type, entry.id)

    this
  end

  # _removeAllListeners  -- ported as remove_all_listeners/2 (no behavior option)

  def listeners(this, type), do: Enum.map(map_get(this, :_events, type) || [], & &1.fun)

  # rawListeners  -- not ported: listeners are stored unwrapped

  def listener_count(this, type), do: length(map_get(this, :_events, type) || [])

  def event_names(%{heap: heap, guid: guid}),
    do: heap |> :ets.match({{guid, :_events, :"$1"}, :_}) |> Enum.map(&hd/1)

  # _waitFor, _listeners  -- ported as remove_all_listeners/2 and listeners/2 (no behavior option)
  # checkListener, OnceWrapper, unwrapListener, unwrapListeners, wrappedListener  -- not ported: once/3 wraps with {id, fun}
end
