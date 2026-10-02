defmodule PlaywrightEx.Routing do
  @moduledoc false
  use GenServer

  alias PlaywrightEx.Channel
  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection
  alias PlaywrightEx.Route

  def register(guid, glob, callback, opts) when is_binary(glob) and is_function(callback, 2) do
    opts =
      NimbleOptions.validate!(opts,
        connection: Channel.connection_opt(),
        timeout: Channel.timeout_opt(),
        on_error: [type: {:in, [:raise, :message]}, default: :raise]
      )

    config = Map.merge(Map.new(opts), %{guid: guid, glob: glob, callback: callback, owner: self()})
    with {:ok, handler} <- Connection.start_route_handler(opts[:connection], guid, config), do: call(handler, :install)
  end

  def unregister(guid, matcher, callback, opts) do
    opts = NimbleOptions.validate!(opts, connection: Channel.connection_opt(), timeout: Channel.timeout_opt())

    case Connection.fetch_route_handler(opts[:connection], guid) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, handler} -> call(handler, {:unregister, matcher, callback, opts[:timeout]})
      error -> error
    end
  end

  defp call(handler, message) do
    GenServer.call(handler, message, :infinity)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> {:error, %{reason: :routing_closed}}
  end

  def start(config), do: GenServer.start(__MODULE__, config)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    if config.on_error == :raise, do: Process.link(config.owner)
    Process.monitor(config.owner)
    Process.monitor(config.connection)
    {:ok, Map.merge(config, %{installed: false, workers: %{}, subscriptions: MapSet.new()})}
  end

  @impl true
  def handle_call(:install, _from, state) do
    with :ok <- Connection.subscribe_sync(state.connection, self(), state.guid),
         {:ok, _} <-
           send_command(state, state.guid, :set_network_interception_patterns, %{patterns: [%{glob: state.glob}]}) do
      {:reply, {:ok, %{}}, %{state | installed: true, subscriptions: MapSet.new([state.guid])}}
    else
      error -> {:stop, :normal, error, %{state | subscriptions: MapSet.new([state.guid])}}
    end
  end

  def handle_call({:unregister, matcher, callback, timeout}, _from, state) do
    cond do
      timeout == 0 -> {:reply, {:error, %{reason: :timeout}}, state}
      matcher not in [:all, state.glob] || callback not in [nil, state.callback] -> {:reply, {:ok, %{}}, state}
      true -> unregister_handler(state, timeout)
    end
  end

  defp unregister_handler(state, timeout) do
    case send_command(%{state | timeout: timeout}, state.guid, :set_network_interception_patterns, %{patterns: []}) do
      {:ok, _} = result -> {:stop, :normal, result, %{state | installed: false}}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(
        {:playwright_msg, %{guid: scope, method: :route, params: %{route: %{guid: guid}}}},
        %{guid: scope} = state
      ) do
    request_id = Connection.initializer!(state.connection, guid).request
    request = Map.merge(Connection.initializer!(state.connection, request_id.guid), request_id)
    scopes = if request[:frame], do: Connection.route_ancestors(state.connection, request.frame.guid), else: [state.guid]
    scopes = [guid | scopes] ++ if(request[:frame], do: [request.frame.guid], else: [])
    state = Enum.reduce(scopes, state, &subscribe/2)
    config = Map.take(state, [:connection, :timeout, :callback])
    pid = spawn_link(fn -> run_callback(config, guid, request) end)
    {:noreply, put_in(state.workers[pid], %{guid: guid, scopes: scopes})}
  rescue
    ArgumentError -> {:noreply, state}
  catch
    :exit, {reason, {:gen_statem, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
      {:stop, :normal, state}
  end

  def handle_info({:playwright_msg, %{method: :frame_detached, params: %{frame: %{guid: guid}}}}, state) do
    handle_info({:playwright_msg, %{guid: guid, method: :__dispose__}}, state)
  end

  def handle_info({:playwright_msg, %{guid: guid, method: method}}, state)
      when method in [:close, :crash, :__dispose__] do
    if guid == state.guid do
      {:stop, :normal, state}
    else
      {closed, active} = Enum.split_with(state.workers, fn {_, worker} -> guid in worker.scopes end)
      Enum.each(closed, &cancel_worker(state, &1))
      Connection.unsubscribe_sync(state.connection, self(), guid)

      {:noreply,
       release_unused_subscriptions(%{
         state
         | workers: Map.new(active),
           subscriptions: MapSet.delete(state.subscriptions, guid)
       })}
    end
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, owner, _}, %{owner: owner} = state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, reason}, state) do
    {worker, workers} = Map.pop(state.workers, pid)
    state = release_unused_subscriptions(%{state | workers: workers})

    if worker && reason != :normal do
      send_command(state, worker.guid, :abort, %{error_code: "failed"})
      handle_callback_failure(state, reason)
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.installed, do: send_command(state, state.guid, :set_network_interception_patterns, %{patterns: []})
    Enum.each(state.subscriptions, &Connection.unsubscribe_sync(state.connection, self(), &1))
    Enum.each(state.workers, &cancel_worker(state, &1))
    abort_queued_routes(state)
  end

  # Synchronous unsubscribe is a barrier: previously delivered route events are
  # now in this mailbox, and the connection will not deliver any more.
  defp abort_queued_routes(state) do
    receive do
      {:playwright_msg, %{guid: guid, method: :route, params: %{route: %{guid: route_guid}}}}
      when guid == state.guid ->
        send_command(state, route_guid, :abort, %{error_code: "aborted"})
        abort_queued_routes(state)
    after
      0 -> :ok
    end
  end

  defp run_callback(state, guid, request) do
    route = %Route{guid: guid, owner: self(), connection: state.connection, timeout: state.timeout}
    Process.put({Route, guid}, false)
    request = if Map.has_key?(request, :post_data), do: Map.update!(request, :post_data, &Base.decode64!/1), else: request
    state.callback.(route, request)

    if !Process.get({Route, guid}),
      do: raise("route callback returned without fulfilling, aborting, or continuing the request")
  catch
    kind, reason -> exit({:playwright_route_error, kind, reason, __STACKTRACE__})
  end

  defp handle_callback_failure(%{on_error: :raise} = state, reason), do: {:stop, reason, state}

  defp handle_callback_failure(state, reason) do
    send(state.owner, {:playwright_route_error, %{guid: state.guid, matcher: state.glob, reason: reason}})
    {:noreply, state}
  end

  defp cancel_worker(state, {pid, worker}) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    send_command(state, worker.guid, :abort, %{error_code: "aborted"})
  end

  defp subscribe(guid, state) do
    if MapSet.member?(state.subscriptions, guid) do
      state
    else
      Connection.subscribe_sync(state.connection, self(), guid)
      %{state | subscriptions: MapSet.put(state.subscriptions, guid)}
    end
  end

  defp release_unused_subscriptions(state) do
    needed = MapSet.new([state.guid | Enum.flat_map(state.workers, fn {_, worker} -> worker.scopes end)])

    state.subscriptions
    |> MapSet.difference(needed)
    |> Enum.each(&Connection.unsubscribe_sync(state.connection, self(), &1))

    %{state | subscriptions: MapSet.intersection(state.subscriptions, needed)}
  end

  defp send_command(state, guid, method, params) do
    state.connection
    |> Connection.send(%{guid: guid, method: method, params: params}, state.timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
