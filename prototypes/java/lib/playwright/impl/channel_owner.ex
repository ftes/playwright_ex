defmodule Playwright.Impl.ChannelOwner do
  # upstream: ChannelOwner.java:29
  # `class ChannelOwner extends LoggingSupport`; subclasses `use Playwright.Impl.ChannelOwner` (inheritance ->
  # `use` + `defoverridable`). Handles are immutable structs holding the final fields; mutable fields go to Heap.
  import Playwright.Impl.Heap, only: [get: 2, get: 3, put: 3, update: 4]
  alias Playwright.Impl.{Connection, Waitable, WaitForEventLogger}
  alias Playwright.PlaywrightException

  @no_timeout nil

  @callback handle_event(struct(), String.t(), map()) :: any()

  defmacro __using__(_) do
    quote do
      use Playwright.PlaywrightException
      import Playwright.Impl.Heap, only: [get: 2, get: 3, put: 3, update: 4]

      import Playwright.Impl.ChannelOwner,
        only: [
          send_message: 2,
          send_message: 4,
          send_message_async: 3,
          run_until: 3,
          with_title: 3,
          with_wait_logging: 3
        ]

      alias Playwright.Impl.{ChannelOwner, Connection}
      @behaviour Playwright.Impl.ChannelOwner
      @no_timeout nil
      defstruct [:connection, :type, :guid, :initializer]

      @type t :: %__MODULE__{}

      # upstream: ChannelOwner.java:153
      @impl Playwright.Impl.ChannelOwner
      def handle_event(_this, _event, _params), do: nil
      defoverridable handle_event: 3
    end
  end

  # upstream: ChannelOwner.java:41
  def init(module, %{connection: connection} = parent, type, guid, initializer) do
    init(module, connection, parent, type, guid, initializer)
  end

  # upstream: ChannelOwner.java:41
  def init(module, connection, type, guid) do
    init(module, connection, nil, type, guid, %{})
  end

  # upstream: ChannelOwner.java:50
  defp init(module, connection, parent, type, guid, initializer) do
    this = struct!(module, connection: connection, type: type, guid: guid, initializer: initializer)
    put(this, :parent, parent)
    Connection.register_object(connection, guid, this)
    if parent != nil, do: update(parent, :objects, %{}, &Map.put(&1, guid, this))
    this
  end

  # upstream: ChannelOwner.java:63
  def dispose_channel_owner(this, was_garbage_collected) do
    # Clean up from parent and connection.
    parent = get(this, :parent)
    if parent != nil, do: update(parent, :objects, %{}, &Map.delete(&1, this.guid))
    Connection.unregister_object(this.connection, this.guid)
    put(this, :was_collected, was_garbage_collected)
    # Dispose all children.
    for child <- Map.values(get(this, :objects, %{})), do: dispose_channel_owner(child, was_garbage_collected)
    put(this, :objects, %{})
  end

  # upstream: ChannelOwner.java:77
  def adopt(this, child) do
    update(get(child, :parent), :objects, %{}, &Map.delete(&1, child.guid))
    update(this, :objects, %{}, &Map.put(&1, child.guid, child))
    put(child, :parent, this)
  end

  # upstream: ChannelOwner.java:83
  def with_wait_logging(this, api_name, code), do: WaitForEventLogger.get(WaitForEventLogger.new(this, api_name, code))

  # upstream: ChannelOwner.java:95
  def with_title(this, title, code) do
    previous_title = Connection.set_title(this.connection, title)

    try do
      code.()
    after
      Connection.set_title(this.connection, previous_title)
    end
  end

  # upstream: ChannelOwner.java:104
  def send_message_async(this, method, params \\ %{}) do
    check_not_collected(this)
    Connection.send_message_async(this.connection, this.guid, method, params)
  end

  # upstream: ChannelOwner.java:114
  # Fire-and-forget: silently drop if the object was collected.
  def send_message_no_reply(this, method, params) do
    if get(this, :was_collected) do
      nil
    else
      Connection.send_message_no_reply(this.connection, this.guid, method, params)
    end
  end

  # upstream: ChannelOwner.java:121
  def send_message(this, method), do: send_message(this, method, %{}, @no_timeout)

  # upstream: ChannelOwner.java:121
  def send_message(this, method, params, timeout) do
    check_not_collected(this)

    params =
      cond do
        # Timeout is passed in the message metadata, remove potential leftover from serialized options.
        timeout != nil ->
          Map.delete(params, "timeout")

        Map.has_key?(params, "timeout") ->
          raise PlaywrightException, message: "Internal error: timeout must be passed explicitly."

        true ->
          params
      end

    Connection.send_message(this.connection, this.guid, method, params, timeout)
  end

  # upstream: ChannelOwner.java:136
  defp check_not_collected(this) do
    if get(this, :was_collected),
      do: raise(PlaywrightException, message: "The object has been collected to prevent unbounded heap growth.")
  end

  # upstream: ChannelOwner.java:141
  def run_until(this, code, waitable) do
    try do
      code.()
      Connection.while(fn -> !Waitable.is_done(waitable) end, fn -> Connection.process_one_message(this.connection) end)
      Waitable.get(waitable)
    after
      Waitable.dispose(waitable)
    end
  end

  # upstream: ChannelOwner.java:156
  def to_protocol_ref(this), do: %{"guid" => this.guid}
end
