defmodule PlaywrightEx.FrameEventRecorder do
  @moduledoc false
  use GenServer

  alias PlaywrightEx.Connection
  alias PlaywrightEx.FrameWaiter

  @waiter_grace_ms 100
  @frame_detached_error "Navigating frame was detached!"
  @page_closed_error "Navigation failed because page was closed!"
  @page_crashed_error "Navigation failed because page crashed!"

  defstruct connection: nil,
            frame_id: nil,
            page_id: nil,
            url: "",
            load_states: MapSet.new(),
            waiters: %{}

  @typep wait_state :: String.t()
  @typep url_matcher :: (String.t() -> boolean())
  @typep initializer :: map()

  @spec wait_for_load_state(atom(), PlaywrightEx.guid(), wait_state(), timeout()) ::
          {:ok, nil} | {:error, map()}
  def wait_for_load_state(connection, frame_id, wait_state, timeout) do
    with {:ok, pid} <- ensure_started(connection, frame_id) do
      call_waiter(pid, {:wait_for_load_state, wait_state, timeout}, timeout)
    end
  end

  @spec wait_for_url(atom(), PlaywrightEx.guid(), url_matcher(), wait_state(), timeout()) ::
          {:ok, nil} | {:error, map()}
  def wait_for_url(connection, frame_id, url_matcher, wait_state, timeout) do
    with {:ok, pid} <- ensure_started(connection, frame_id) do
      call_waiter(pid, {:wait_for_url, url_matcher, wait_state, timeout}, timeout)
    end
  end

  @spec ensure_started(atom(), PlaywrightEx.guid(), initializer() | nil) :: {:ok, pid()} | {:error, map()}
  def ensure_started(connection, frame_id, initializer \\ nil) do
    case lookup(connection, frame_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        start_recorder(connection, frame_id, initializer)
    end
  end

  @spec attach_page(atom(), PlaywrightEx.guid(), PlaywrightEx.guid()) :: {:ok, pid()} | :not_found
  def attach_page(connection, frame_id, page_id) do
    case lookup(connection, frame_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:attach_page, page_id})
        {:ok, pid}

      :not_found ->
        :not_found
    end
  end

  @spec registry_name(atom()) :: atom()
  def registry_name(connection), do: Module.concat(connection, "FrameEventRecorderRegistry")

  @spec supervisor_name(atom()) :: atom()
  def supervisor_name(connection), do: Module.concat(connection, "FrameEventRecorderSupervisor")

  def child_spec(%{connection: connection, frame_id: frame_id} = opts) do
    %{
      id: {__MODULE__, {connection, frame_id}},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc false
  def start_link(%{connection: connection, frame_id: frame_id} = opts) do
    GenServer.start_link(__MODULE__, opts, name: via(connection, frame_id))
  end

  @impl true
  def init(%{connection: connection, frame_id: frame_id} = opts) do
    frame_initializer = Map.get(opts, :initializer) || Connection.initializer!(connection, frame_id)

    Connection.subscribe(connection, self(), frame_id)

    state = %__MODULE__{
      connection: connection,
      frame_id: frame_id,
      url: frame_initializer[:url] || "",
      load_states: FrameWaiter.normalize_load_states(frame_initializer[:load_states])
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:attach_page, page_id}, %{page_id: page_id} = state), do: {:noreply, state}

  def handle_cast({:attach_page, page_id}, state) do
    {:noreply, %{state | page_id: page_id}}
  end

  def handle_cast(:dispose, state) do
    state = fail_waiters(state, fn _waiter -> true end, {:error, %{message: @frame_detached_error}})
    {:stop, {:shutdown, :frame_detached}, state}
  end

  @impl true
  def handle_call({:wait_for_load_state, wait_state, timeout}, from, state) do
    add_waiter(state, from, FrameWaiter.new_load_state_waiter(wait_state), timeout)
  end

  def handle_call({:wait_for_url, url_matcher, wait_state, timeout}, from, state) do
    add_waiter(state, from, FrameWaiter.new_url_waiter(url_matcher, wait_state), timeout)
  end

  @impl true
  def handle_info({:playwright_msg, %{guid: frame_id, method: :loadstate, params: params}}, %{frame_id: frame_id} = state) do
    state = %{state | load_states: FrameWaiter.update_load_states(state.load_states, params)}
    {:noreply, process_waiters(state)}
  end

  def handle_info(
        {:playwright_msg, %{guid: frame_id, method: :navigated, params: %{error: error}}},
        %{frame_id: frame_id} = state
      )
      when is_binary(error) do
    {:noreply, fail_waiters(state, &url_waiter?/1, {:error, %{message: error}})}
  end

  def handle_info({:playwright_msg, %{guid: frame_id, method: :navigated, params: params}}, %{frame_id: frame_id} = state) do
    load_states =
      if Map.has_key?(params, :new_document) do
        MapSet.new(["commit"])
      else
        state.load_states
      end

    state = %{state | url: params.url || state.url, load_states: load_states}
    {:noreply, process_waiters(state)}
  end

  def handle_info({:playwright_msg, %{guid: frame_id, method: :__dispose__}}, %{frame_id: frame_id} = state) do
    state = fail_waiters(state, fn _waiter -> true end, {:error, %{message: @frame_detached_error}})
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

  defp lookup(connection, frame_id) do
    registry = registry_name(connection)

    case Registry.lookup(registry, frame_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @spec terminate_frame(atom(), PlaywrightEx.guid()) :: :ok
  def terminate_frame(connection, frame_id) do
    case lookup(connection, frame_id) do
      {:ok, pid} -> GenServer.cast(pid, :dispose)
      :not_found -> :ok
    end

    :ok
  end

  defp start_recorder(connection, frame_id, initializer) do
    child_opts = maybe_put_initializer(%{connection: connection, frame_id: frame_id}, initializer)

    child_spec = {__MODULE__, child_opts}

    case DynamicSupervisor.start_child(supervisor_name(connection), child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, %{message: "Failed to start frame event recorder: #{inspect(reason)}"}}
    end
  catch
    :exit, reason ->
      {:error, %{message: "Failed to start frame event recorder: #{Exception.format_exit(reason)}"}}
  end

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

  defp add_waiter(state, from, waiter, timeout) do
    case FrameWaiter.evaluate(waiter, %{url: state.url, load_states: state.load_states}) do
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
        case FrameWaiter.evaluate(waiter_entry.waiter, frame_state) do
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

  defp maybe_put_initializer(opts, initializer) when is_map(initializer), do: Map.put(opts, :initializer, initializer)
  defp maybe_put_initializer(opts, _initializer), do: opts

  defp url_waiter?({:url, _url_matcher, _wait_state, _phase}), do: true
  defp url_waiter?(_waiter), do: false

  defp via(connection, frame_id), do: {:via, Registry, {registry_name(connection), frame_id}}

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: _ = Process.cancel_timer(timer_ref, async: true, info: false)

  defp timeout_error(timeout), do: {:error, %{message: "Timeout #{timeout}ms exceeded."}}
end
