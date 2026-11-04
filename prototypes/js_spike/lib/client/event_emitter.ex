# upstream: packages/playwright-core/src/client/eventEmitter.ts
#
# Not line-equivalent by design: upstream re-implements Node's EventEmitter
# (listener arrays, newListener/removeListener meta events, leak warnings).
# This keeps the public surface (same names, same order) on top of the heap.
# `emit` runs under the baton and hands it to each listener in turn (fresh process, see
# `Baton.spawn_handoff/1`) until the listener returns or awaits, as JS runs listeners
# synchronously inside `emit`. A listener is a 1-arity function or an `{id, fun}` pair
# (so a closure can remove itself: JS `let listener = ...`).
defmodule PlaywrightJS.Client.EventEmitter do
  import PlaywrightJS.Runtime.Heap
  alias PlaywrightJS.Runtime.Baton

  defstruct [:guid, :conn]

  # "class Foo extends EventEmitter": inject the inherited methods.
  defmacro __using__(_opts) do
    quote do
      defdelegate emit(this, type, arg \\ nil), to: PlaywrightJS.Client.EventEmitter
      defdelegate add_listener(this, type, listener), to: PlaywrightJS.Client.EventEmitter
      defdelegate on(this, type, listener), to: PlaywrightJS.Client.EventEmitter
      defdelegate prepend_listener(this, type, listener), to: PlaywrightJS.Client.EventEmitter
      defdelegate once(this, type, listener), to: PlaywrightJS.Client.EventEmitter
      defdelegate remove_listener(this, type, listener), to: PlaywrightJS.Client.EventEmitter
      defdelegate off(this, type, listener), to: PlaywrightJS.Client.EventEmitter
      defdelegate listener_count(this, type), to: PlaywrightJS.Client.EventEmitter
      defoverridable add_listener: 3, on: 3, prepend_listener: 3, remove_listener: 3, off: 3
    end
  end

  # upstream: eventEmitter.ts:43
  def new(loop), do: new_object(loop, __MODULE__)

  # upstream: eventEmitter.ts:64
  def emit(this, type, arg \\ nil) do
    Baton.with_baton(this.conn, fn ->
      handler = map_get(this, :_events, type) || []

      for entry <- handler, do: _call_handler(this, type, entry.fun, arg)

      handler != []
    end)
  end

  # upstream: eventEmitter.ts:84
  defp _call_handler(_this, _type, handler, arg), do: Baton.spawn_handoff(fn -> handler.(arg) end)

  # upstream: eventEmitter.ts:102
  def add_listener(this, type, listener), do: _add_listener(this, type, listener, false)

  # upstream: eventEmitter.ts:106
  def on(this, type, listener), do: _add_listener(this, type, listener, false)

  # upstream: eventEmitter.ts:110
  defp _add_listener(this, type, listener, prepend) do
    {id, fun} = if is_tuple(listener), do: listener, else: {listener, listener}
    entry = %{id: id, fun: fun}

    Baton.with_baton(this.conn, fn ->
      map_set(
        this,
        :_events,
        type,
        if(prepend, do: [entry], else: []) ++ (map_get(this, :_events, type) || []) ++ if(prepend, do: [], else: [entry])
      )
    end)

    this
  end

  # upstream: eventEmitter.ts:169
  def prepend_listener(this, type, listener), do: _add_listener(this, type, listener, true)

  # upstream: eventEmitter.ts:173
  # Upstream calls `this.on(...)` (virtual dispatch); here: dispatch via the struct module.
  def once(this, type, listener) do
    {id, fun} = if is_tuple(listener), do: listener, else: {listener, listener}
    this.__struct__.on(this, type, {id, fn arg -> this.__struct__.remove_listener(this, type, id) && fun.(arg) end})
    this
  end

  # upstream: eventEmitter.ts:185
  def remove_listener(this, type, listener) do
    Baton.with_baton(this.conn, fn ->
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

  # upstream: eventEmitter.ts:235
  def off(this, type, listener), do: remove_listener(this, type, listener)

  # upstream: eventEmitter.ts (listenerCount)
  def listener_count(this, type), do: length(map_get(this, :_events, type) || [])
end
