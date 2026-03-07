defmodule PlaywrightEx.Resource.Page do
  @moduledoc false
  @behaviour PlaywrightEx.Resource.Behaviour

  use GenServer

  alias PlaywrightEx.Connection

  @waiter_grace_ms 100
  @max_recent_events 50
  @page_closed_error "Navigation failed because page was closed!"
  @page_crashed_error "Navigation failed because page crashed!"

  defstruct connection: nil,
            pg_scope: nil,
            resource_id: nil,
            main_frame_id: nil,
            status: :open,
            recent_events: [],
            child_resources: %{},
            event_waiters: %{}

  @typep event_matcher :: (map() -> boolean())

  @spec ensure_started(atom(), PlaywrightEx.guid(), map() | nil) :: {:ok, pid()} | {:error, map()}
  def ensure_started(connection, page_id, initializer \\ nil) do
    PlaywrightEx.Resource.ensure_started(__MODULE__, connection, page_id, initializer)
  end

  @spec maybe_stop(atom(), PlaywrightEx.guid()) :: :ok
  def maybe_stop(connection, page_id) do
    PlaywrightEx.Resource.maybe_stop(__MODULE__, connection, page_id)
  end

  @spec info(atom(), PlaywrightEx.guid()) :: map()
  def info(connection, page_id) do
    PlaywrightEx.Resource.info(__MODULE__, connection, page_id)
  end

  @spec events(atom(), PlaywrightEx.guid(), pos_integer()) :: [map()]
  def events(connection, page_id, limit \\ 50) do
    PlaywrightEx.Resource.events(__MODULE__, connection, page_id, limit)
  end

  @spec child_resources(atom(), PlaywrightEx.guid(), atom() | :all) :: map() | [map()]
  def child_resources(connection, page_id, type \\ :all) do
    PlaywrightEx.Resource.child_resources(__MODULE__, connection, page_id, type)
  end

  @spec registry_name(atom()) :: atom()
  def registry_name(connection), do: PlaywrightEx.Resource.registry_name(__MODULE__, connection)

  @spec supervisor_name(atom()) :: atom()
  def supervisor_name(connection), do: PlaywrightEx.Resource.supervisor_name(__MODULE__, connection)

  def child_spec(%{connection: connection, resource_id: resource_id} = opts) do
    %{
      id: {__MODULE__, {connection, resource_id}},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc false
  def start_link(%{connection: connection, resource_id: resource_id} = opts) do
    GenServer.start_link(__MODULE__, opts, name: via(connection, resource_id))
  end

  @spec await_event(atom(), PlaywrightEx.guid(), event_matcher(), timeout()) ::
          {:ok, map()} | {:error, map()}
  def await_event(connection, page_id, matcher, timeout) do
    PlaywrightEx.Resource.await(__MODULE__, connection, page_id, {:await_event, matcher, timeout}, timeout)
  end

  @spec await_child_resource(atom(), PlaywrightEx.guid(), atom(), timeout()) ::
          {:ok, map()} | {:error, map()}
  def await_child_resource(connection, page_id, type, timeout) when is_atom(type) do
    matcher = fn event ->
      match?(%{method: :__create__, params: %{guid: _, type: ^type}}, normalize_create_type(event))
    end

    with {:ok, event} <- await_event(connection, page_id, matcher, timeout) do
      {:ok, child_resource_from_event(event)}
    end
  end

  @spec maybe_start(map(), map()) :: :ok
  @impl true
  def maybe_start(_connection_context, _msg), do: :ok

  @doc false
  @impl true
  def call_resource(pid, request, timeout) do
    GenServer.call(pid, request, timeout + @waiter_grace_ms)
  catch
    :exit, {:timeout, _} ->
      {:error, %{message: "Timeout #{timeout}ms exceeded."}}

    :exit, reason ->
      classify_call_exit(reason)
  end

  @impl true
  def init(%{connection: connection, resource_id: page_id} = opts) do
    page_initializer = Map.get(opts, :initializer) || Connection.initializer!(connection, page_id)
    main_frame_id = extract_main_frame_id(page_initializer)
    pg_scope = Map.get(opts, :pg_scope) || Connection.pg_scope(connection)

    :ok = :pg.join(pg_scope, {:guid, page_id}, self())

    state =
      record_event(
        %__MODULE__{
          connection: connection,
          pg_scope: pg_scope,
          resource_id: page_id,
          main_frame_id: main_frame_id,
          child_resources: put_child_resource(%{}, :frame, %{guid: main_frame_id, initializer: %{}})
        },
        %{method: :__create__, params: %{guid: page_id, initializer: page_initializer}}
      )

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = :pg.leave(state.pg_scope, {:guid, state.resource_id}, self())
    :ok
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, public_info(state), state}
  end

  def handle_call({:events, limit}, _from, state) do
    {:reply, state.recent_events |> Enum.take(limit) |> Enum.reverse(), state}
  end

  def handle_call({:child_resources, :all}, _from, state) do
    {:reply, public_child_resources(state.child_resources), state}
  end

  def handle_call({:child_resources, type}, _from, state) when is_atom(type) do
    {:reply, public_child_resources(state.child_resources, type), state}
  end

  def handle_call({:await_event, matcher, timeout}, from, state) do
    case Enum.find(Enum.reverse(state.recent_events), &safe_match?(matcher, &1)) do
      nil ->
        waiter_ref = make_ref()
        timer_ref = Process.send_after(self(), {:event_waiter_timeout, waiter_ref, timeout}, timeout)
        waiter = %{matcher: matcher, from: from, timer_ref: timer_ref}
        {:noreply, put_in(state.event_waiters[waiter_ref], waiter)}

      event ->
        {:reply, {:ok, event}, state}
    end
  end

  @impl true
  def handle_info({:playwright_msg, %{guid: page_id} = event}, %{resource_id: page_id} = state) do
    event = normalize_create_type(event)

    state =
      state
      |> update_status(event)
      |> maybe_track_child_resource(event)
      |> record_event(event)
      |> process_event_waiters(event)

    case state.status do
      :closed ->
        state = fail_event_waiters(state, {:error, %{message: @page_closed_error}})
        {:stop, {:shutdown, :page_closed}, state}

      :crashed ->
        state = fail_event_waiters(state, {:error, %{message: @page_crashed_error}})
        {:stop, {:shutdown, :page_crashed}, state}

      :disposed ->
        state = fail_event_waiters(state, {:error, %{message: @page_closed_error}})
        {:stop, {:shutdown, :page_closed}, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:event_waiter_timeout, waiter_ref, timeout}, state) do
    case Map.pop(state.event_waiters, waiter_ref) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        GenServer.reply(waiter.from, {:error, %{message: "Timeout #{timeout}ms exceeded."}})
        {:noreply, %{state | event_waiters: waiters}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp classify_call_exit({:shutdown, :page_closed}), do: {:error, %{message: @page_closed_error, reason: :page_closed}}

  defp classify_call_exit({{:shutdown, :page_closed}, _}),
    do: {:error, %{message: @page_closed_error, reason: :page_closed}}

  defp classify_call_exit({:shutdown, :page_crashed}),
    do: {:error, %{message: @page_crashed_error, reason: :page_crashed}}

  defp classify_call_exit({{:shutdown, :page_crashed}, _}),
    do: {:error, %{message: @page_crashed_error, reason: :page_crashed}}

  defp classify_call_exit(:normal), do: {:error, %{message: @page_closed_error, reason: :page_closed}}
  defp classify_call_exit({:shutdown, :normal}), do: {:error, %{message: @page_closed_error, reason: :page_closed}}
  defp classify_call_exit({{:shutdown, :normal}, _}), do: {:error, %{message: @page_closed_error, reason: :page_closed}}
  defp classify_call_exit({:noproc, _}), do: {:error, %{message: @page_closed_error, reason: :page_closed}}
  defp classify_call_exit(reason), do: {:error, %{message: Exception.format_exit(reason)}}

  defp public_info(state) do
    %{
      id: state.resource_id,
      status: state.status,
      main_frame_id: state.main_frame_id,
      child_resources: public_child_resources(state.child_resources),
      recent_events_count: length(state.recent_events)
    }
  end

  defp public_child_resources(child_resources) do
    Map.new(child_resources, fn {type, resources} -> {type, Enum.reverse(resources)} end)
  end

  defp public_child_resources(child_resources, type) do
    child_resources |> Map.get(type, []) |> Enum.reverse()
  end

  defp normalize_create_type(%{method: :__create__, params: %{type: type}} = event) when is_binary(type) do
    put_in(event, [:params, :type], type |> Macro.underscore() |> String.to_atom())
  end

  defp normalize_create_type(event), do: event

  defp update_status(state, %{method: :close}), do: %{state | status: :closed}
  defp update_status(state, %{method: :crash}), do: %{state | status: :crashed}
  defp update_status(state, %{method: :__dispose__}), do: %{state | status: :disposed}
  defp update_status(state, _event), do: state

  defp maybe_track_child_resource(state, %{method: :__create__, params: %{guid: guid, type: type} = params})
       when is_atom(type) and is_binary(guid) do
    child = %{guid: guid, initializer: Map.get(params, :initializer, %{})}
    %{state | child_resources: put_child_resource(state.child_resources, type, child)}
  end

  defp maybe_track_child_resource(state, _event), do: state

  defp record_event(state, event) do
    %{state | recent_events: [event | Enum.take(state.recent_events, @max_recent_events - 1)]}
  end

  defp put_child_resource(child_resources, _type, %{guid: nil}), do: child_resources

  defp put_child_resource(child_resources, type, child) do
    Map.update(child_resources, type, [child], fn children ->
      if Enum.any?(children, &(&1.guid == child.guid)) do
        children
      else
        [child | children]
      end
    end)
  end

  defp process_event_waiters(state, event) do
    {waiters, replies} =
      Enum.reduce(state.event_waiters, {%{}, []}, fn {waiter_ref, waiter}, {acc_waiters, acc_replies} ->
        if safe_match?(waiter.matcher, event) do
          {acc_waiters, [{waiter, {:ok, event}} | acc_replies]}
        else
          {Map.put(acc_waiters, waiter_ref, waiter), acc_replies}
        end
      end)

    Enum.each(replies, fn {waiter, reply} ->
      cancel_timer(waiter.timer_ref)
      GenServer.reply(waiter.from, reply)
    end)

    %{state | event_waiters: waiters}
  end

  defp fail_event_waiters(state, reply) do
    Enum.each(state.event_waiters, fn {_ref, waiter} ->
      cancel_timer(waiter.timer_ref)
      GenServer.reply(waiter.from, reply)
    end)

    %{state | event_waiters: %{}}
  end

  defp safe_match?(matcher, event) do
    matcher.(event)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp child_resource_from_event(%{params: %{guid: guid, type: type} = params}) do
    %{guid: guid, type: type, initializer: Map.get(params, :initializer, %{})}
  end

  defp extract_main_frame_id(%{main_frame: %{guid: guid}}) when is_binary(guid), do: guid
  defp extract_main_frame_id(%{main_frame: guid}) when is_binary(guid), do: guid
  defp extract_main_frame_id(_initializer), do: nil

  defp cancel_timer(timer_ref), do: _ = Process.cancel_timer(timer_ref, async: true, info: false)

  defp via(connection, resource_id) do
    {:via, Registry, {registry_name(connection), resource_id}}
  end
end
