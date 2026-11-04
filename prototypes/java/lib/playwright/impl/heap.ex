defmodule Playwright.Impl.Heap do
  @moduledoc """
  OTP mapping for Java's mutable object fields (no upstream counterpart).

  Java objects are mutable and shared by reference; Elixir values are immutable. Every Java object that
  has mutable state is represented by an immutable *handle* struct (carrying only final fields such as
  `guid`/`initializer`) and its mutable fields live here, in a public ETS table keyed by `{object_id, field}`:

      this.isClosed = true;          ->  put(this, :is_closed, true)
      return isClosed;               ->  get(this, :is_closed)
      browserContext.pages.remove(p) ->  update(get(this, :browser_context), :pages, &List.delete(&1, p))

  Writers are the Connection process (dispatching events, like Java's message pump) and client processes
  (API calls). Like the Java client, there is no locking: one logical owner per object graph.
  """
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, nil}
  end

  def key(%{guid: guid, connection: %{id: connection_id}}), do: {connection_id, guid}
  def key(%{id: id}), do: id

  def get(object, field, default \\ nil), do: get_raw({key(object), field}, default)

  def put(object, field, value), do: put_raw({key(object), field}, value)

  def update(object, field, default, fun), do: put(object, field, fun.(get(object, field, default)))

  def delete_all(object), do: :ets.match_delete(@table, {{key(object), :_}, :_})

  def get_raw(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{_, value}] -> value
      [] -> default
    end
  end

  def put_raw(key, value) do
    :ets.insert(@table, {key, value})
    value
  end

  def delete_raw(key), do: :ets.delete(@table, key)

  def counter(key), do: :ets.update_counter(@table, key, 1, {key, 0})
end
