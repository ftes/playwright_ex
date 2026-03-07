defmodule PlaywrightEx.Resource.Frame do
  @moduledoc false
  @behaviour PlaywrightEx.Resource.Behaviour

  use GenServer

  alias PlaywrightEx.Resource.Frame.Waiter

  @waiter_grace_ms 100
  @max_recent_events 50
  @frame_detached_error "Navigating frame was detached!"
  @page_closed_error "Navigation failed because page was closed!"
  @page_crashed_error "Navigation failed because page crashed!"

  defstruct connection: nil,
            pg_scope: nil,
            resource_id: nil,
            page_id: nil,
            status: :open,
            url: "",
            load_states: MapSet.new(),
            waiters: %{},
            recent_events: [],
            child_resources: %{}

  @typep wait_state :: String.t()
  @typep url_matcher :: (String.t() -> boolean())

  @spec ensure_started(atom(), PlaywrightEx.guid(), map() | nil) :: {:ok, pid()} | {:error, map()}
  def ensure_started(connection, frame_id, initializer \\ nil) do
    PlaywrightEx.Resource.ensure_started(__MODULE__, connection, frame_id, initializer)
  end

  @spec maybe_stop(atom(), PlaywrightEx.guid()) :: :ok
  def maybe_stop(connection, frame_id) do
    PlaywrightEx.Resource.maybe_stop(__MODULE__, connection, frame_id)
  end

  @spec info(atom(), PlaywrightEx.guid()) :: map()
  def info(connection, frame_id) do
    PlaywrightEx.Resource.info(__MODULE__, connection, frame_id)
  end

  @spec events(atom(), PlaywrightEx.guid(), pos_integer()) :: [map()]
  def events(connection, frame_id, limit \\ 50) do
    PlaywrightEx.Resource.events(__MODULE__, connection, frame_id, limit)
  end

  @spec child_resources(atom(), PlaywrightEx.guid(), atom() | :all) :: map() | [map()]
  def child_resources(connection, frame_id, type \\ :all) do
    PlaywrightEx.Resource.child_resources(__MODULE__, connection, frame_id, type)
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

  @spec await_load_state(atom(), PlaywrightEx.guid(), wait_state(), timeout()) ::
          {:ok, nil} | {:error, map()}
  def await_load_state(connection, frame_id, wait_state, timeout) do
    PlaywrightEx.Resource.await(__MODULE__, connection, frame_id, {:await_load_state, wait_state, timeout}, timeout)
  end

  @spec await_url(atom(), PlaywrightEx.guid(), url_matcher(), wait_state(), timeout()) ::
          {:ok, nil} | {:error, map()}
  def await_url(connection, frame_id, url_matcher, wait_state, timeout) do
    PlaywrightEx.Resource.await(__MODULE__, connection, frame_id, {:await_url, url_matcher, wait_state, timeout}, timeout)
  end

  @spec maybe_start(map(), map()) :: :ok
  @impl true
  def maybe_start(%{connection: connection, pg_scope: pg_scope}, %{
        method: :__create__,
        params: %{guid: guid, initializer: %{url: _url, load_states: _load_states} = initializer}
      }) do
    _ = PlaywrightEx.Resource.ensure_started(__MODULE__, connection, guid, initializer, %{pg_scope: pg_scope})
    :ok
  end

  def maybe_start(_connection_context, _msg), do: :ok

  @impl true
  def init(%{connection: connection, resource_id: frame_id} = opts) do
    frame_initializer = Map.get(opts, :initializer) || PlaywrightEx.Connection.initializer!(connection, frame_id)
    page_id = extract_page_id(frame_initializer)
    pg_scope = Map.get(opts, :pg_scope) || PlaywrightEx.Connection.pg_scope(connection)

    :ok = :pg.join(pg_scope, {:guid, frame_id}, self())
    :ok = :pg.join(pg_scope, {:guid, page_id}, self())

    state = %__MODULE__{
      connection: connection,
      pg_scope: pg_scope,
      resource_id: frame_id,
      page_id: page_id,
      url: frame_initializer[:url] || "",
      load_states: Waiter.normalize_load_states(frame_initializer[:load_states]),
      recent_events: [%{method: :__create__, params: %{guid: frame_id, initializer: frame_initializer}}]
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = :pg.leave(state.pg_scope, {:guid, state.resource_id}, self())
    _ = :pg.leave(state.pg_scope, {:guid, state.page_id}, self())
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
    {:reply, %{}, state}
  end

  def handle_call({:child_resources, _type}, _from, state) do
    {:reply, [], state}
  end

  def handle_call({:await_load_state, wait_state, timeout}, from, state) do
    add_waiter(state, from, Waiter.new_load_state_waiter(wait_state), timeout)
  end

  def handle_call({:await_url, url_matcher, wait_state, timeout}, from, state) do
    add_waiter(state, from, Waiter.new_url_waiter(url_matcher, wait_state), timeout)
  end

  @impl true
  def handle_info(
        {:playwright_msg, %{guid: frame_id, method: :loadstate, params: params} = event},
        %{resource_id: frame_id} = state
      ) do
    state =
      state
      |> Map.update!(:load_states, &Waiter.update_load_states(&1, params))
      |> record_event(event)

    {:noreply, process_waiters(state)}
  end

  def handle_info(
        {:playwright_msg, %{guid: frame_id, method: :navigated, params: %{error: error}} = event},
        %{resource_id: frame_id} = state
      )
      when is_binary(error) do
    state = record_event(state, event)
    {:noreply, fail_waiters(state, &url_waiter?/1, {:error, %{message: error}})}
  end

  def handle_info(
        {:playwright_msg, %{guid: frame_id, method: :navigated, params: params} = event},
        %{resource_id: frame_id} = state
      ) do
    load_states =
      if Map.has_key?(params, :new_document) do
        MapSet.new(["commit"])
      else
        state.load_states
      end

    state =
      state
      |> Map.merge(%{url: params.url || state.url, load_states: load_states})
      |> record_event(event)

    {:noreply, process_waiters(state)}
  end

  def handle_info({:playwright_msg, %{guid: frame_id, method: :__dispose__} = event}, %{resource_id: frame_id} = state) do
    state =
      state
      |> Map.put(:status, :disposed)
      |> record_event(event)
      |> fail_waiters(fn _waiter -> true end, {:error, %{message: @frame_detached_error}})

    {:stop, {:shutdown, :frame_detached}, state}
  end

  def handle_info({:playwright_msg, %{guid: page_id, method: :crash}}, %{page_id: page_id} = state) do
    state = fail_waiters(state, fn _waiter -> true end, {:error, %{message: @page_crashed_error}})
    {:stop, {:shutdown, :page_crashed}, state}
  end

  def handle_info({:playwright_msg, %{guid: page_id, method: :close}}, %{page_id: page_id} = state) do
    state = fail_waiters(state, fn _waiter -> true end, {:error, %{message: @page_closed_error}})
    {:stop, {:shutdown, :page_closed}, state}
  end

  def handle_info({:playwright_msg, %{guid: page_id, method: :__dispose__}}, %{page_id: page_id} = state) do
    state = fail_waiters(state, fn _waiter -> true end, {:error, %{message: @page_closed_error}})
    {:stop, {:shutdown, :page_closed}, state}
  end

  def handle_info({:waiter_timeout, waiter_ref, timeout}, state) do
    case Map.pop(state.waiters, waiter_ref) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter_entry, waiters} ->
        GenServer.reply(waiter_entry.from, timeout_error(timeout))
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp call_waiter(pid, request, timeout) do
    GenServer.call(pid, request, timeout + @waiter_grace_ms)
  catch
    :exit, {:timeout, _} ->
      timeout_error(timeout)

    :exit, reason ->
      call_waiter_exit_reason(reason)
  end

  defp call_waiter_exit_reason(reason) do
    case classify_call_waiter_exit_reason(reason) do
      {nil, message} -> {:error, %{message: message}}
      {reason_atom, message} -> {:error, %{message: message, reason: reason_atom}}
    end
  end

  defp classify_call_waiter_exit_reason({:shutdown, :frame_detached}), do: {:frame_detached, @frame_detached_error}
  defp classify_call_waiter_exit_reason({{:shutdown, :frame_detached}, _}), do: {:frame_detached, @frame_detached_error}
  defp classify_call_waiter_exit_reason({:shutdown, :page_closed}), do: {:page_closed, @page_closed_error}
  defp classify_call_waiter_exit_reason({{:shutdown, :page_closed}, _}), do: {:page_closed, @page_closed_error}
  defp classify_call_waiter_exit_reason({:shutdown, :page_crashed}), do: {:page_crashed, @page_crashed_error}
  defp classify_call_waiter_exit_reason({{:shutdown, :page_crashed}, _}), do: {:page_crashed, @page_crashed_error}
  defp classify_call_waiter_exit_reason(:normal), do: {:normal, @frame_detached_error}
  defp classify_call_waiter_exit_reason({:shutdown, :normal}), do: {:normal, @frame_detached_error}
  defp classify_call_waiter_exit_reason({{:shutdown, :normal}, _}), do: {:normal, @frame_detached_error}
  defp classify_call_waiter_exit_reason({:normal, _}), do: {:normal, @frame_detached_error}
  defp classify_call_waiter_exit_reason({{:normal, _}, _}), do: {:normal, @frame_detached_error}
  defp classify_call_waiter_exit_reason({:shutdown, reason}) when is_atom(reason), do: {reason, @page_closed_error}
  defp classify_call_waiter_exit_reason({{:shutdown, reason}, _}) when is_atom(reason), do: {reason, @page_closed_error}
  defp classify_call_waiter_exit_reason({:noproc, _}), do: {:noproc, @page_closed_error}
  defp classify_call_waiter_exit_reason(reason), do: {nil, Exception.format_exit(reason)}

  @doc false
  @impl true
  def call_resource(pid, request, timeout) do
    call_waiter(pid, request, timeout)
  end

  defp add_waiter(state, from, waiter, timeout) do
    case Waiter.evaluate(waiter, %{url: state.url, load_states: state.load_states}) do
      {:done, reply} ->
        {:reply, reply, state}

      {:error, reply} ->
        {:reply, reply, state}

      {:update, waiter} ->
        waiter_ref = make_ref()
        timer_ref = Process.send_after(self(), {:waiter_timeout, waiter_ref, timeout}, timeout)
        waiter_entry = %{waiter: waiter, from: from, timer_ref: timer_ref}
        {:noreply, put_in(state.waiters[waiter_ref], waiter_entry)}
    end
  end

  defp process_waiters(state) do
    frame_state = %{url: state.url, load_states: state.load_states}

    {waiters, replies} =
      Enum.reduce(state.waiters, {%{}, []}, fn {waiter_ref, waiter_entry}, {acc_waiters, acc_replies} ->
        case Waiter.evaluate(waiter_entry.waiter, frame_state) do
          {:done, reply} ->
            {acc_waiters, [{waiter_entry, reply} | acc_replies]}

          {:error, reply} ->
            {acc_waiters, [{waiter_entry, reply} | acc_replies]}

          {:update, waiter} ->
            {Map.put(acc_waiters, waiter_ref, %{waiter_entry | waiter: waiter}), acc_replies}
        end
      end)

    Enum.each(replies, fn {waiter_entry, reply} ->
      cancel_timer(waiter_entry.timer_ref)
      GenServer.reply(waiter_entry.from, reply)
    end)

    %{state | waiters: waiters}
  end

  defp fail_waiters(state, predicate, reply) do
    {failed_waiters, waiters} =
      Enum.split_with(state.waiters, fn {_ref, waiter_entry} -> predicate.(waiter_entry.waiter) end)

    Enum.each(failed_waiters, fn {_ref, waiter_entry} ->
      cancel_timer(waiter_entry.timer_ref)
      GenServer.reply(waiter_entry.from, reply)
    end)

    %{state | waiters: Map.new(waiters)}
  end

  defp extract_page_id(%{page: %{guid: guid}}) when is_binary(guid), do: guid
  defp extract_page_id(%{page: guid}) when is_binary(guid), do: guid
  defp extract_page_id(_initializer), do: nil

  defp url_waiter?({:url, _url_matcher, _wait_state, _phase}), do: true
  defp url_waiter?(_waiter), do: false

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: _ = Process.cancel_timer(timer_ref, async: true, info: false)

  defp timeout_error(timeout), do: {:error, %{message: "Timeout #{timeout}ms exceeded."}}

  defp public_info(state) do
    %{
      id: state.resource_id,
      status: state.status,
      page_id: state.page_id,
      url: state.url,
      load_states: state.load_states |> MapSet.to_list() |> Enum.sort(),
      child_resources: %{},
      recent_events_count: length(state.recent_events)
    }
  end

  defp record_event(state, event) do
    %{state | recent_events: [event | Enum.take(state.recent_events, @max_recent_events - 1)]}
  end

  defp via(connection, resource_id) do
    {:via, Registry, {registry_name(connection), resource_id}}
  end
end
