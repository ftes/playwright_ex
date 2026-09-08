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

  alias PlaywrightEx.FrameEventRecorder
  alias PlaywrightEx.Serialization

  @timeout_grace_factor 1.5
  @min_genserver_timeout to_timeout(second: 1)

  defstruct config: %{js_logger: nil, transport: {nil, nil}},
            initializers: %{},
            types: %{},
            parents: %{},
            children: %{},
            frame_pages: %{},
            initialization: nil,
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

  @doc """
  Unsubscribe from messages for a guid.
  """
  def unsubscribe(name, pid \\ self(), guid) do
    :gen_statem.cast(name, {:unsubscribe, pid, guid})
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
      |> update_in([:params], &Map.delete(&1, :timeout))
      |> put_in([:metadata, :timeout], timeout)
      |> Map.put_new_lazy(:id, fn -> System.unique_integer([:positive, :monotonic]) end)

    call_timeout = max(@min_genserver_timeout, round(timeout * @timeout_grace_factor))

    :gen_statem.call(name, {:send, msg}, call_timeout)
  end

  @doc """
  Get the initializer data for a channel.
  """
  def initializer!(name, guid) do
    case :gen_statem.call(name, {:initializer, guid}) do
      {:ok, initializer} ->
        initializer

      :error ->
        raise ArgumentError, "unknown or disposed Playwright channel #{inspect(guid)}"
    end
  end

  @doc """
  Returns `true` if the connection uses a remote (WebSocket) transport.
  """
  def remote?(name) do
    :gen_statem.call(name, :remote?)
  end

  # Internal

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(config) do
    %{timeout: timeout, transport: transport} = config
    initialization_id = System.unique_integer([:positive, :monotonic])

    post(transport, %{
      id: initialization_id,
      guid: "",
      method: :initialize,
      params: %{sdk_language: :javascript},
      metadata: %{timeout: timeout}
    })

    initialization = %{id: initialization_id, acknowledged?: false, playwright_created?: false}
    {:ok, :pending, %__MODULE__{config: config, initialization: initialization}}
  end

  defp post({transport_module, transport_name}, msg) do
    transport_module.post(transport_name, msg)
  end

  @doc false
  def pending(:cast, {:playwright_msg, %{method: :__create__, params: %{guid: "Playwright"}} = msg}, data) do
    data =
      data
      |> handle_protocol_message(msg)
      |> put_in([Access.key!(:initialization), Access.key!(:playwright_created?)], true)

    maybe_finish_initialization(data)
  end

  def pending(:cast, {:playwright_msg, %{id: id} = msg}, %{initialization: %{id: id}} = data) do
    case msg do
      %{error: error} ->
        {:stop, {:playwright_initialization_failed, error}, data}

      _response ->
        data = put_in(data.initialization.acknowledged?, true)
        maybe_finish_initialization(data)
    end
  end

  def pending(:cast, _msg, _data), do: {:keep_state_and_data, [:postpone]}
  def pending({:call, _from}, _msg, _data), do: {:keep_state_and_data, [:postpone]}

  @doc false
  def started({:call, from}, {:send, msg}, data) do
    post(data.config.transport, msg)
    {:keep_state, put_in(data.pending_response[msg.id], from)}
  end

  def started({:call, from}, {:initializer, guid}, data) do
    {:keep_state_and_data, [{:reply, from, Map.fetch(data.initializers, guid)}]}
  end

  def started({:call, from}, :remote?, data) do
    {transport_module, _} = data.config.transport
    {:keep_state_and_data, [{:reply, from, transport_module != PlaywrightEx.PortTransport}]}
  end

  def started(:cast, {:subscribe, recipient, guid}, data) do
    {:keep_state, subscribe_recipient(data, recipient, guid)}
  end

  def started(:cast, {:unsubscribe, recipient, guid}, data) do
    _ = :pg.leave(data.config.pg_scope, pg_group(guid), recipient)
    :keep_state_and_data
  end

  def started(:cast, {:playwright_msg, msg}, data) when is_map_key(data.pending_response, msg.id) do
    {from, pending_response} = Map.pop(data.pending_response, msg.id)
    :gen_statem.reply(from, msg)

    {:keep_state, %{data | pending_response: pending_response}}
  end

  def started(:cast, {:playwright_msg, msg}, data) do
    maybe_log_protocol_message(data, msg)
    {:keep_state, handle_protocol_message(data, msg)}
  end

  defp handle_create(data, %{method: :__create__} = msg) do
    child_guid = msg.params.guid

    data
    |> put_in([Access.key!(:initializers), child_guid], msg.params.initializer)
    |> put_in([Access.key!(:types), child_guid], msg.params[:type])
    |> put_parent(child_guid, msg[:guid])
  end

  defp handle_create(data, _msg), do: data

  defp handle_adopt(data, %{method: :__adopt__, guid: parent_guid, params: %{guid: child_guid}}) do
    put_parent(data, child_guid, parent_guid)
  end

  defp handle_adopt(data, _msg), do: data

  defp maybe_start_frame_event_recorder(data, %{
         method: :__create__,
         params: %{guid: guid, initializer: %{url: _url, load_states: _load_states} = initializer}
       }) do
    case FrameEventRecorder.ensure_started(data.config.name, guid, initializer) do
      {:ok, pid} -> subscribe_recipient(data, pid, guid)
      {:error, _reason} -> data
    end
  end

  defp maybe_start_frame_event_recorder(data, %{method: :__create__}) do
    data
  end

  defp maybe_start_frame_event_recorder(data, _msg), do: data

  defp maybe_associate_frame_with_page(data, %{method: :__create__, params: %{guid: guid, type: "Page"} = params}) do
    case params.initializer do
      %{main_frame: %{guid: frame_guid}} -> associate_frame_with_page(data, frame_guid, guid)
      _initializer -> data
    end
  end

  defp maybe_associate_frame_with_page(data, %{method: :__create__, params: %{guid: guid, type: "Frame"}}) do
    associate_created_frame(data, guid)
  end

  defp maybe_associate_frame_with_page(data, %{method: :__create__, params: %{guid: guid}}) do
    case data.initializers[guid] do
      %{main_frame: %{guid: frame_guid}} ->
        associate_frame_with_page(data, frame_guid, guid)

      %{url: _url, load_states: _load_states} ->
        associate_created_frame(data, guid)

      _initializer ->
        data
    end
  end

  defp maybe_associate_frame_with_page(data, %{method: :__adopt__, guid: parent_guid, params: %{guid: child_guid}}) do
    associate_frame_from_parent(data, child_guid, parent_guid)
  end

  defp maybe_associate_frame_with_page(data, _msg), do: data

  defp handle_dispose(data, %{method: :__dispose__} = msg) do
    disposed_guids = collect_descendants(data.children, msg.guid)

    Enum.each(tl(disposed_guids), fn guid ->
      notify_guid_subscribers(data, guid, %{guid: guid, method: :__dispose__, params: %{}})
    end)

    Enum.reduce(disposed_guids, data, &dispose_guid(&2, &1))
  end

  defp handle_dispose(data, _msg), do: data

  defp notify_subscribers(data, %{guid: guid} = msg) do
    notify_guid_subscribers(data, guid, msg)
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

  defp stop_disposed_frame_event_recorder(data, guid) do
    _ = FrameEventRecorder.terminate_frame(data.config.name, guid)
    data
  end

  defp maybe_finish_initialization(%{initialization: %{acknowledged?: true, playwright_created?: true}} = data) do
    {:next_state, :started, %{data | initialization: nil}}
  end

  defp maybe_finish_initialization(data), do: {:keep_state, data}

  defp handle_protocol_message(data, msg) do
    data
    |> handle_create(msg)
    |> handle_adopt(msg)
    |> maybe_start_frame_event_recorder(msg)
    |> maybe_associate_frame_with_page(msg)
    |> notify_subscribers(msg)
    |> handle_dispose(msg)
  end

  defp put_parent(data, _child_guid, nil), do: data

  defp put_parent(data, child_guid, parent_guid) do
    old_parent = data.parents[child_guid]

    children =
      data.children
      |> remove_child(old_parent, child_guid)
      |> Map.update(parent_guid, MapSet.new([child_guid]), &MapSet.put(&1, child_guid))

    %{data | parents: Map.put(data.parents, child_guid, parent_guid), children: children}
  end

  defp remove_child(children, nil, _child_guid), do: children

  defp remove_child(children, parent_guid, child_guid) do
    case Map.get(children, parent_guid) do
      nil ->
        children

      siblings ->
        siblings = MapSet.delete(siblings, child_guid)

        if MapSet.size(siblings) == 0,
          do: Map.delete(children, parent_guid),
          else: Map.put(children, parent_guid, siblings)
    end
  end

  defp associate_created_frame(data, frame_guid) do
    case data.frame_pages[frame_guid] do
      nil -> associate_frame_from_parent(data, frame_guid, data.parents[frame_guid])
      page_guid -> associate_frame_with_page(data, frame_guid, page_guid)
    end
  end

  defp associate_frame_from_parent(data, _frame_guid, nil), do: data

  defp associate_frame_from_parent(data, frame_guid, parent_guid) do
    cond do
      data.types[parent_guid] == "Page" -> associate_frame_with_page(data, frame_guid, parent_guid)
      page_guid = data.frame_pages[parent_guid] -> associate_frame_with_page(data, frame_guid, page_guid)
      true -> data
    end
  end

  defp associate_frame_with_page(data, frame_guid, page_guid) do
    old_page_guid = data.frame_pages[frame_guid]

    data =
      case FrameEventRecorder.attach_page(data.config.name, frame_guid, page_guid) do
        {:ok, pid} ->
          maybe_unsubscribe_recipient(data, pid, old_page_guid, page_guid)
          subscribe_recipient(data, pid, page_guid)

        :not_found ->
          data
      end

    data = put_in(data.frame_pages[frame_guid], page_guid)

    data.children
    |> Map.get(frame_guid, MapSet.new())
    |> Enum.filter(&(data.types[&1] == "Frame"))
    |> Enum.reduce(data, &associate_frame_with_page(&2, &1, page_guid))
  end

  defp collect_descendants(children, guid), do: collect_descendants(children, guid, %{})

  defp collect_descendants(children, guid, seen) do
    if Map.has_key?(seen, guid) do
      []
    else
      seen = Map.put(seen, guid, true)

      descendants =
        children
        |> Map.get(guid, MapSet.new())
        |> Enum.flat_map(&collect_descendants(children, &1, seen))

      [guid | descendants]
    end
  end

  defp dispose_guid(data, guid) do
    parent_guid = data.parents[guid]

    data
    |> Map.update!(:initializers, &Map.delete(&1, guid))
    |> Map.update!(:types, &Map.delete(&1, guid))
    |> Map.update!(:parents, &Map.delete(&1, guid))
    |> Map.update!(:children, &(&1 |> remove_child(parent_guid, guid) |> Map.delete(guid)))
    |> Map.update!(:frame_pages, &Map.delete(&1, guid))
    |> stop_disposed_frame_event_recorder(guid)
    |> clear_disposed_guid_subscribers(guid)
  end

  defp notify_guid_subscribers(data, guid, msg) do
    for pid <- :pg.get_members(data.config.pg_scope, pg_group(guid)) do
      Kernel.send(pid, {:playwright_msg, msg})
    end
  end

  defp subscribe_recipient(data, recipient, guid) do
    group = pg_group(guid)

    if recipient not in :pg.get_members(data.config.pg_scope, group) do
      :ok = :pg.join(data.config.pg_scope, group, recipient)
    end

    data
  end

  defp maybe_unsubscribe_recipient(_data, _recipient, nil, _new_guid), do: :ok
  defp maybe_unsubscribe_recipient(_data, _recipient, guid, guid), do: :ok

  defp maybe_unsubscribe_recipient(data, recipient, old_guid, _new_guid) do
    _ = :pg.leave(data.config.pg_scope, pg_group(old_guid), recipient)
    :ok
  end

  defp maybe_log_protocol_message(%{config: %{js_logger: module}}, %{method: :page_error} = msg)
       when not is_nil(module) do
    module.log(:error, Serialization.serialized_error_message(msg.params.error), msg)
  end

  defp maybe_log_protocol_message(%{config: %{js_logger: module}}, %{method: :console} = msg) when not is_nil(module) do
    module.log(log_level_from_js(msg.params[:type]), msg.params[:text], msg)
  end

  defp maybe_log_protocol_message(_data, _msg), do: :ok

  defp log_level_from_js("error"), do: :error
  defp log_level_from_js("debug"), do: :debug
  defp log_level_from_js(_), do: :info
end
