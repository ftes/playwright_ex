defmodule PlaywrightEx.Connection do
  @moduledoc """
  Stateful, `:gen_statem` based connection to a Playwright node.js server.
  The connection is established via `PlaywrightEx.PortServer`.

  States:
  - `:pending`: Initial state, waiting for Playwright initialization. Post calls are postponed.
  - `:started`: Playwright is ready, all operations are processed normally.
  """
  @behaviour :gen_statem

  import Kernel, except: [send: 2]

  alias PlaywrightEx.PortServer

  @timeout_grace_factor 1.5
  @min_genserver_timeout to_timeout(second: 1)

  defstruct config: %{js_logger: nil, port_server_name: nil},
            initializers: %{},
            guid_subscribers: %{},
            pending_response: %{}

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, opts}}
  end

  @doc false
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:timeout, :name, :port_server_name, js_logger: nil])
    timeout = Keyword.fetch!(opts, :timeout)
    name = Keyword.fetch!(opts, :name)

    :gen_statem.start_link({:local, name}, __MODULE__, Map.new(opts), timeout: timeout)
  end

  @doc """
  Subscribe to messages for a guid and its descendants.
  """
  def subscribe(name, pid \\ self(), guid) do
    :gen_statem.cast(name, {:subscribe, pid, guid})
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

  # Internal

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(config) do
    %{timeout: timeout, port_server_name: port_server_name} = config

    PortServer.post(port_server_name, %{
      guid: "",
      method: :initialize,
      params: %{sdk_language: :javascript, timeout: timeout},
      metadata: %{}
    })

    {:ok, :pending, %__MODULE__{config: config}}
  end

  @doc false
  def pending(:cast, {:playwright_msg, %{method: :__create__, params: %{guid: "Playwright"}} = msg}, data) do
    {:next_state, :started, handle_create(data, msg)}
  end

  def pending(:cast, _msg, _data), do: {:keep_state_and_data, [:postpone]}
  def pending({:call, _from}, _msg, _data), do: {:keep_state_and_data, [:postpone]}

  @doc false
  def started({:call, from}, {:send, msg}, data) do
    PortServer.post(data.config.port_server_name, msg)
    {:keep_state, put_in(data.pending_response[msg.id], from)}
  end

  def started({:call, from}, {:initializer, guid}, data) do
    {:keep_state_and_data, [{:reply, from, Map.fetch!(data.initializers, guid)}]}
  end

  def started(:cast, {:subscribe, recipient, guid}, data) do
    {:keep_state, update_in(data.guid_subscribers[guid], &[recipient | &1 || []])}
  end

  def started(:cast, {:playwright_msg, %{method: :page_error} = msg}, data) do
    if module = data.config.js_logger do
      module.log(:error, msg.params.error, msg)
    end

    :keep_state_and_data
  end

  def started(:cast, {:playwright_msg, %{method: :console} = msg}, data) do
    if module = data.config.js_logger do
      level = log_level_from_js(msg[:params][:type])
      module.log(level, msg.params.text, msg)
    end

    :keep_state_and_data
  end

  def started(:cast, {:playwright_msg, msg}, data) when is_map_key(data.pending_response, msg.id) do
    {from, pending_response} = Map.pop(data.pending_response, msg.id)
    :gen_statem.reply(from, msg)

    {:keep_state, %{data | pending_response: pending_response}}
  end

  def started(:cast, {:playwright_msg, msg}, data) do
    {:keep_state, data |> handle_create(msg) |> handle_dispose(msg) |> notify_subscribers(msg)}
  end

  defp handle_create(data, %{method: :__create__} = msg) do
    put_in(data.initializers[msg.params.guid], msg.params.initializer)
  end

  defp handle_create(data, _msg), do: data

  defp handle_dispose(data, %{method: :__dispose__} = msg) do
    data
    |> Map.update!(:initializers, &Map.delete(&1, msg.guid))
    |> Map.update!(:guid_subscribers, &Map.delete(&1, msg.guid))
  end

  defp handle_dispose(data, _msg), do: data

  defp notify_subscribers(data, msg) when is_map_key(data.guid_subscribers, msg.guid) do
    for pid <- Map.fetch!(data.guid_subscribers, msg.guid), do: Kernel.send(pid, {:playwright_msg, msg})
    data
  end

  defp notify_subscribers(data, _msg), do: data

  defp log_level_from_js("error"), do: :error
  defp log_level_from_js("debug"), do: :debug
  defp log_level_from_js(_), do: :info
end
