defmodule Py do
  @moduledoc """
  Minimal Python object-model runtime used by the 1:1 port (NOT ported code).

  Decision: every *mutable* Python object (ChannelOwner subclasses, Connection,
  Channel, Waiter, TimeoutSettings, EventEmitter, Future ...) is an Elixir struct
  holding only an identity (`__id__`). Its attributes live in one public ETS
  table ("the heap"), keyed `{id, attr}`. This lets the ported code keep Python's
  shape: `self._pages` reads as `self[:_pages]`, `self._pages.append(p)` as
  `Py.append(self, :_pages, p)`, from *any* process (user process = awaiting
  coroutine, transport process = event loop/dispatcher) without GenServer
  round-trips or deadlocks. Immutable Python objects (Locator, Download,
  AssertionsBase, ProtocolCallback) are plain structs.
  """

  @heap :py_heap

  def heap, do: @heap

  @doc "Python truthiness (`bool(x)`): None, False, 0, \"\", [], {} are falsy."
  def bool(x) when x in [nil, false, 0, "", [], %{}], do: false
  def bool(_), do: true

  @doc "`with cm as value: body` for context managers exposing __enter__/__exit__."
  def with_(cm, body) do
    value = cm.__struct__.__enter__(cm)

    try do
      body.(value)
    after
      cm.__struct__.__exit__(cm)
    end
  end

  @doc "Allocate a new object of `module` with initial attributes."
  def new(module, attrs \\ []) do
    obj = struct(module, __id__: make_ref())
    for {k, v} <- attrs, do: set(obj, k, v)
    obj
  end

  def get(%{__id__: id}, attr) do
    case :ets.lookup(@heap, {id, attr}) do
      [{_, v}] -> v
      [] -> nil
    end
  end

  def has?(%{__id__: id}, attr), do: :ets.member(@heap, {id, attr})

  def set(%{__id__: id}, attr, value) do
    :ets.insert(@heap, {{id, attr}, value})
    value
  end

  @doc "`self.attr.append(value)` (single-writer attributes only)."
  def append(obj, attr, value), do: set(obj, attr, (get(obj, attr) || []) ++ [value])

  @doc "`self.attr.remove(value)`"
  def remove(obj, attr, value), do: set(obj, attr, List.delete(get(obj, attr) || [], value))

  @doc "`self.attr += 1` atomically (multi-writer counters)."
  def incr(%{__id__: id}, attr), do: :ets.update_counter(@heap, {id, attr}, 1, {{id, attr}, 0})

  # Multi-writer dicts: one ETS row per key, so concurrent writers don't race.
  def dict_put(%{__id__: id}, attr, key, value), do: :ets.insert(@heap, {{id, attr, key}, value})

  def dict_pop(%{__id__: id}, attr, key) do
    case :ets.take(@heap, {id, attr, key}) do
      [{_, v}] -> v
      [] -> raise KeyError, key: key
    end
  end

  def dict_values(%{__id__: id}, attr) do
    :ets.match_object(@heap, {{id, attr, :_}, :_}) |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  def dict_delete(%{__id__: id}, attr, key), do: :ets.delete(@heap, {id, attr, key})

  def dict_clear(%{__id__: id}, attr), do: :ets.match_delete(@heap, {{id, attr, :_}, :_})

  @doc "Struct boilerplate for heap objects: `obj[:attr]` reads from the heap."
  defmacro __using__(_) do
    quote do
      defstruct [:__id__]
      @behaviour Access
      @impl Access
      def fetch(obj, attr), do: {:ok, Py.get(obj, attr)}
      @impl Access
      def get_and_update(_obj, _attr, _fun), do: raise("use Py.set/3")
      @impl Access
      def pop(_obj, _attr), do: raise("use Py.set/3")
      defoverridable fetch: 2

      defimpl Inspect do
        def inspect(obj, _opts), do: "#<#{inspect(obj.__struct__)} #{inspect(obj.__id__)}>"
      end
    end
  end
end

defmodule Py.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [Py.HeapOwner]
    Supervisor.start_link(children, strategy: :one_for_one, name: Py.Supervisor)
  end
end

defmodule Py.HeapOwner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(Py.heap(), [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(:py_future_waiters, [:bag, :public, :named_table, write_concurrency: true])
    {:ok, nil}
  end
end
