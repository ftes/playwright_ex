defmodule Playwright.Transport.ChannelOwner do
  @moduledoc """
  upstream: Transport/ChannelOwner.cs

  OTP mapping of the C# object model:
  * Each ChannelOwner subclass is a module with a struct holding `guid`, `connection` and the
    *immutable* fields (set once in the constructor). The struct is a cheap, copyable handle.
  * *Mutable* C# fields/properties (`_pages`, `IsClosed`, `Url`, ...) live in the connection's ETS
    table as `{{guid, field}, value}` rows: `get/2`, `set/3`, `update/3`. Read-modify-write
    (`update/3`) only happens inside the connection process (Dispatch), so it is race-free.
  * C# `event EventHandler<T> Foo` + `Foo?.Invoke(this, x)` -> `emit(this, "Foo", x)`. Subscribers
    are processes (Registry, duplicate keys) receiving `{:playwright_event, ref, x}`; internal
    handlers added in constructors (`Close += ...`) run inside the connection process.
  """
  alias Playwright.Transport.Connection

  @callback on_message(struct(), String.t(), map()) :: any()

  defmacro __using__(fields) do
    quote do
      @behaviour Playwright.Transport.ChannelOwner
      defstruct [:guid, :connection, __channel_owner__: true] ++ unquote(fields)
      def on_message(_this, _method, _params), do: :ok
      defoverridable on_message: 3

      defimpl Inspect do
        def inspect(owner, _opts), do: "##{inspect(owner.__struct__)}<#{owner.guid}>"
      end
    end
  end

  # upstream: Transport/ChannelOwner.cs:39
  def new(module, parent, guid, fields \\ []), do: new(module, parent, parent.connection, guid, fields)

  # upstream: Transport/ChannelOwner.cs:43
  def new(module, parent, connection, guid, fields) do
    this = struct!(module, [guid: guid, connection: connection] ++ fields)
    set(this, :parent, parent)
    set(this, :objects, %{})

    Connection.put_object(connection, guid, this)
    if parent != nil do
      update(parent, :objects, &Map.put(&1, guid, this))
    end
    this
  end

  # upstream: Transport/ChannelOwner.cs:57
  def objects(this), do: get(this, :objects)

  # upstream: Transport/ChannelOwner.cs:61
  def parent(this), do: get(this, :parent)

  # upstream: Transport/ChannelOwner.cs:63
  def on_message(this, method, server_params), do: this.__struct__.on_message(this, method, server_params)

  # upstream: Transport/ChannelOwner.cs:67
  def adopt(this, child) do
    update(get(child, :parent), :objects, &Map.delete(&1, child.guid))
    update(this, :objects, &Map.put(&1, child.guid, child))
    set(child, :parent, this)
  end

  # upstream: Transport/ChannelOwner.cs:74
  def dispose_owner(this, reason) do
    if parent = get(this, :parent), do: update(parent, :objects, &Map.delete(&1, this.guid))
    Connection.remove_object(this.connection, this.guid)
    set(this, :was_collected, reason == "gc")

    for item <- Map.values(get(this, :objects) || %{}) do
      dispose_owner(item, reason)
    end
    set(this, :objects, %{})
  end

  # upstream: Transport/ChannelOwner.cs:87
  def wrap_api_call(this, action, is_internal \\ false, title \\ nil),
    do: Connection.wrap_api_call(this.connection, action, is_internal, title)

  # upstream: Transport/ChannelOwner.cs:127
  def send_message_to_server(this, method, args \\ nil, opts \\ []),
    do: Connection.send_message_to_server(this.connection, this, method, args, opts)

  # ---- Elixir-only: mutable state (C# fields) -------------------------------------------------

  def get(this, field, default \\ nil), do: Connection.get_field(this.connection, this.guid, field, default)
  def set(this, field, value), do: Connection.set_field(this.connection, this.guid, field, value)
  def update(this, field, fun), do: set(this, field, fun.(get(this, field)))

  # ---- Elixir-only: events (C# `event` + `?.Invoke`) -------------------------------------------

  @doc "C# `owner.Foo += handler` for an external process: returns a ref; events arrive as `{:playwright_event, ref, payload}`."
  def subscribe(this, event) do
    ref = make_ref()
    {:ok, _} = Registry.register(this.connection.registry, {this.guid, event}, ref)
    ref
  end

  def unsubscribe(this, event, ref), do: Registry.unregister_match(this.connection.registry, {this.guid, event}, ref)

  @doc "C# `Foo += handler` inside the client (constructor-time internal handlers). Runs in the connection process."
  def add_handler(this, event, fun), do: update(this, {:handlers, event}, &[fun | &1 || []])

  @doc "C# `Foo?.Invoke(this, payload)`."
  def emit(this, event, payload) do
    for fun <- Enum.reverse(get(this, {:handlers, event}) || []), do: fun.(payload)

    Registry.dispatch(this.connection.registry, {this.guid, event}, fn entries ->
      for {pid, ref} <- entries, do: send(pid, {:playwright_event, ref, payload})
    end)
  end
end
