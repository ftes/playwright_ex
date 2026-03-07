defmodule PlaywrightEx.Connection do
  @moduledoc """
  Stateful, `:gen_statem` based connection to a Playwright node.js server.
  The connection is established via a transport (`PlaywrightEx.PortTransport` or `PlaywrightEx.WebSocketTransport`).

  States:
  - `:pending`: Initial state, waiting for Playwright initialization. Post calls are postponed.
  - `:started`: Playwright is ready, all operations are processed normally.
  """
  @behaviour :gen_statem

  import Kernel, except: [send: 2]

  alias PlaywrightEx.Resource

  @timeout_grace_factor 1.5
  @min_genserver_timeout to_timeout(second: 1)

  defstruct config: %{js_logger: nil, transport: {nil, nil}},
            initializers: %{},
            pending_response: %{}

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, opts}}
  end

  @doc false
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:timeout, :transport, :name, :pg_scope, js_logger: nil])
    timeout = Keyword.fetch!(opts, :timeout)
    name = Keyword.fetch!(opts, :name)

    :gen_statem.start_link({:local, name}, __MODULE__, Map.new(opts), timeout: timeout)
  end

  @doc """
  Subscribe to messages for a guid.
  """
  def subscribe(name, pid \\ self(), guid) do
    :gen_statem.cast(name, {:subscribe, pid, guid})
  end

  @doc false
  def subscribe_sync(name, pid \\ self(), guid) do
    :gen_statem.call(name, {:subscribe, pid, guid})
  end

  @doc """
  Unsubscribe from messages for a guid.
  """
  def unsubscribe(name, pid \\ self(), guid) do
    :gen_statem.cast(name, {:unsubscribe, pid, guid})
  end

  @doc false
  def unsubscribe_sync(name, pid \\ self(), guid) do
    :gen_statem.call(name, {:unsubscribe, pid, guid})
  end

  @doc false
  def handle_playwright_msg(name, msg) do
    :gen_statem.cast(name, {:playwright_msg, msg})
  end

  @doc """
  Post a message and await the response.
  Wait for an additional grace period after the playwright timeout.
  """
  def send(name, %{guid: _, method: _} = msg, timeout) when is_integer(timeout) do
    msg =
      msg
      |> Enum.into(%{params: %{}, metadata: %{}})
      |> put_in([:params, :timeout], timeout)
      |> Map.put_new_lazy(:id, fn -> System.unique_integer([:positive, :monotonic]) end)

    call_timeout = max(@min_genserver_timeout, round(timeout * @timeout_grace_factor))

    :gen_statem.call(name, {:send, msg}, call_timeout)
  end

  @doc """
  Get the initializer data for a channel.
  """
  def initializer!(name, guid) do
    :gen_statem.call(name, {:initializer, guid})
  end

  @doc """
  Returns `true` if the connection uses a remote (WebSocket) transport.
  """
  def remote?(name) do
    :gen_statem.call(name, :remote?)
  end

  @doc false
  def pg_scope(name) do
    :gen_statem.call(name, :pg_scope)
  end

  # Internal

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(config) do
    %{timeout: timeout, transport: transport} = config

    post(transport, %{
      guid: "",
      method: :initialize,
      params: %{sdk_language: :javascript, timeout: timeout},
      metadata: %{}
    })

    {:ok, :pending, %__MODULE__{config: config}}
  end

  defp post({transport_module, transport_name}, msg) do
    transport_module.post(transport_name, msg)
  end

  @doc false
  def pending(:cast, {:playwright_msg, %{method: :__create__, params: %{guid: "Playwright"}} = msg}, data) do
    {:next_state, :started, cache_initializer(data, msg)}
  end

  def pending(:cast, _msg, _data), do: {:keep_state_and_data, [:postpone]}
  def pending({:call, _from}, _msg, _data), do: {:keep_state_and_data, [:postpone]}

  @doc false
  def started({:call, from}, {:send, msg}, data) do
    post(data.config.transport, msg)
    {:keep_state, put_in(data.pending_response[msg.id], from)}
  end

  def started({:call, from}, {:initializer, guid}, data) do
    {:keep_state_and_data, [{:reply, from, Map.fetch!(data.initializers, guid)}]}
  end

  def started({:call, from}, :remote?, data) do
    {transport_module, _} = data.config.transport
    {:keep_state_and_data, [{:reply, from, transport_module != PlaywrightEx.PortTransport}]}
  end

  def started({:call, from}, :pg_scope, data) do
    {:keep_state_and_data, [{:reply, from, data.config.pg_scope}]}
  end

  def started({:call, from}, {:subscribe, recipient, guid}, data) do
    join_subscriber(data, recipient, guid)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def started({:call, from}, {:unsubscribe, recipient, guid}, data) do
    leave_subscriber(data, recipient, guid)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def started(:cast, {:subscribe, recipient, guid}, data) do
    join_subscriber(data, recipient, guid)
    :keep_state_and_data
  end

  def started(:cast, {:unsubscribe, recipient, guid}, data) do
    leave_subscriber(data, recipient, guid)
    :keep_state_and_data
  end

  def started(:cast, {:playwright_msg, %{method: :page_error} = msg}, data) do
    if module = data.config.js_logger do
      module.log(:error, msg.params.error, msg)
    end

    {:keep_state, notify_subscribers(data, msg)}
  end

  def started(:cast, {:playwright_msg, %{method: :console} = msg}, data) do
    if module = data.config.js_logger do
      level = log_level_from_js(msg[:params][:type])
      module.log(level, msg.params.text, msg)
    end

    {:keep_state, notify_subscribers(data, msg)}
  end

  def started(:cast, {:playwright_msg, msg}, data) when is_map_key(data.pending_response, msg.id) do
    {from, pending_response} = Map.pop(data.pending_response, msg.id)
    :gen_statem.reply(from, msg)

    {:keep_state, %{data | pending_response: pending_response}}
  end

  def started(:cast, {:playwright_msg, msg}, data) do
    data = cache_initializer(data, msg)
    resource_context = %{connection: data.config.name, pg_scope: data.config.pg_scope}
    Enum.each(Resource.modules(), & &1.maybe_start(resource_context, msg))
    data = notify_subscribers(data, msg)

    {:keep_state, release_disposed_guid(data, msg)}
  end

  defp cache_initializer(data, %{method: :__create__} = msg) do
    put_in(data.initializers[msg.params.guid], msg.params.initializer)
  end

  defp cache_initializer(data, _msg), do: data

  defp release_disposed_guid(data, %{method: :__dispose__} = msg) do
    Enum.each(Resource.modules(), & &1.maybe_stop(data.config.name, msg.guid))

    data
    |> Map.update!(:initializers, &Map.delete(&1, msg.guid))
    |> clear_disposed_guid_subscribers(msg.guid)
  end

  defp release_disposed_guid(data, _msg), do: data

  defp notify_subscribers(data, %{guid: guid} = msg) do
    for pid <- :pg.get_members(data.config.pg_scope, pg_group(guid)) do
      Kernel.send(pid, {:playwright_msg, msg})
    end

    data
  end

  defp notify_subscribers(data, _msg), do: data

  defp pg_group(guid), do: {:guid, guid}

  defp clear_disposed_guid_subscribers(data, guid) do
    group = pg_group(guid)

    for pid <- :pg.get_local_members(data.config.pg_scope, group) do
      _ = :pg.leave(data.config.pg_scope, group, pid)
    end

    data
  end

  defp join_subscriber(data, recipient, guid) do
    group = pg_group(guid)

    if recipient in :pg.get_members(data.config.pg_scope, group) do
      :ok
    else
      :ok = :pg.join(data.config.pg_scope, group, recipient)
    end
  end

  defp leave_subscriber(data, recipient, guid) do
    _ = :pg.leave(data.config.pg_scope, pg_group(guid), recipient)
  end

  defp log_level_from_js("error"), do: :error
  defp log_level_from_js("debug"), do: :debug
  defp log_level_from_js(_), do: :info
end
