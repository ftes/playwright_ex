defmodule Pyee.EventEmitter do
  @moduledoc """
  pyee.EventEmitter (runtime shim, NOT ported). Listeners are heap dict rows
  keyed `{event, monotonic}` so `on` from the user process and
  `remove_listener` from the dispatcher never race. `emit` runs listeners
  synchronously in the emitting process (the dispatcher), like pyee on the loop.
  `use Pyee.EventEmitter` = `class X(EventEmitter)`; "virtual" methods are
  dispatched through `obj.__struct__` so subclasses can override them.
  """
  use Py

  def new, do: Py.new(__MODULE__)

  def on(self, event, f) do
    self.__struct__._add_event_handler(self, event, f, {:erlang.unique_integer([:monotonic]), f})
    f
  end

  def once(self, event, f) do
    key = :erlang.unique_integer([:monotonic])

    g = fn args ->
      Py.dict_delete(self, :_events, {event, key})
      f.(args)
    end

    self.__struct__._add_event_handler(self, event, f, {key, g})
    f
  end

  def _add_event_handler(self, event, k, {key, v}) do
    Py.dict_put(self, :_events, {event, key}, {k, v})
  end

  def emit(self, event, args \\ nil) do
    handlers = for {{^event, _}, {_k, v}} <- rows(self), do: v
    for v <- handlers, do: v.(args)
    handlers != []
  end

  def remove_listener(self, event, f) do
    case Enum.find(rows(self), fn {{e, _}, {k, _}} -> e == event and k == f end) do
      {key, _} -> Py.dict_delete(self, :_events, key)
      nil -> :ok
    end
  end

  def listeners(self, event), do: for({{^event, _}, {k, _}} <- rows(self), do: k)

  defp rows(%{__id__: id}) do
    :ets.match_object(Py.heap(), {{id, :_events, :_}, :_})
    |> Enum.map(fn {{_, _, key}, v} -> {key, v} end)
    |> Enum.sort_by(fn {{_, n}, _} -> n end)
  end

  defmacro __using__(_) do
    quote do
      use Py
      defdelegate on(self, event, f), to: Pyee.EventEmitter
      defdelegate once(self, event, f), to: Pyee.EventEmitter
      defdelegate emit(self, event, args \\ nil), to: Pyee.EventEmitter
      defdelegate listeners(self, event), to: Pyee.EventEmitter
      defdelegate _add_event_handler(self, event, k, v), to: Pyee.EventEmitter
      defdelegate remove_listener(self, event, f), to: Pyee.EventEmitter
      defoverridable _add_event_handler: 4, remove_listener: 3
    end
  end
end
