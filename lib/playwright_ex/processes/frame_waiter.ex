defmodule PlaywrightEx.FrameWaiter do
  @moduledoc false

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Timeout

  @waiter_grace_ms 100

  @type url_matcher :: (String.t() -> boolean())
  @type waiter ::
          {:load_state, String.t()}
          | {:url, url_matcher(), String.t(), :waiting_for_url | :waiting_for_load_state}

  @spec wait_for_load_state(atom(), PlaywrightEx.guid(), String.t(), timeout()) :: {:ok, nil} | {:error, map()}
  def wait_for_load_state(connection, frame_id, wait_state, timeout) do
    wait(connection, frame_id, new_load_state_waiter(wait_state), timeout)
  end

  @spec wait_for_url(atom(), PlaywrightEx.guid(), url_matcher(), String.t(), timeout()) :: {:ok, nil} | {:error, map()}
  def wait_for_url(connection, frame_id, url_matcher, wait_state, timeout) do
    wait(connection, frame_id, new_url_waiter(url_matcher, wait_state), timeout)
  end

  defp wait(connection, frame_id, waiter, timeout) do
    deadline = Timeout.deadline(timeout)

    case GenServer.whereis(connection) do
      nil -> connection_closed()
      pid -> run_task(pid, frame_id, waiter, timeout, deadline)
    end
  end

  defp run_task(connection, frame_id, waiter, timeout, deadline) do
    owner = self()

    task =
      Task.async(fn ->
        refs = {frame_id, Process.monitor(connection), Process.monitor(owner)}

        with {:ok, frame_state} <- Connection.subscribe_frame(connection, self(), frame_id) do
          resolve(waiter, frame_state, timeout, deadline, refs)
        end
      end)

    # Bound a stuck predicate as well as event waiting. Allow the zero-timeout
    # snapshot check to finish before enforcing this outer guard.
    case Task.yield(task, call_timeout(Timeout.remaining(deadline))) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        exit(reason)

      nil ->
        Task.shutdown(task, :brutal_kill)
        timeout_error(timeout)
    end
  end

  defp resolve(waiter, frame_state, timeout, deadline, refs) do
    case {evaluate(waiter, frame_state), Timeout.remaining(deadline)} do
      {{:done, reply}, remaining} when timeout == 0 or remaining != 0 -> reply
      {_, 0} -> timeout_error(timeout)
      {{:update, waiter}, _} -> wait_event(waiter, timeout, deadline, refs)
    end
  end

  defp wait_event(waiter, timeout, deadline, {frame_id, connection_ref, owner_ref} = refs) do
    receive do
      {:frame_state, ^frame_id, {:ok, frame_state}} ->
        if Timeout.remaining(deadline) == 0,
          do: timeout_error(timeout),
          else: resolve(waiter, frame_state, timeout, deadline, refs)

      {:frame_navigation_error, ^frame_id, error} when elem(waiter, 0) == :url ->
        {:error, %{message: error}}

      {:frame_navigation_error, ^frame_id, _error} ->
        wait_event(waiter, timeout, deadline, refs)

      {:frame_state, ^frame_id, {:error, _} = error} ->
        error

      {:DOWN, ^connection_ref, :process, _, _} ->
        connection_closed()

      {:DOWN, ^owner_ref, :process, _, _} ->
        exit(:normal)
    after
      Timeout.remaining(deadline) -> timeout_error(timeout)
    end
  end

  defp connection_closed, do: {:error, %{reason: :connection_closed, message: "Playwright connection closed"}}

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout), do: timeout + @waiter_grace_ms
  defp timeout_error(timeout), do: {:error, %{message: "Timeout #{timeout}ms exceeded."}}

  @spec new_load_state_waiter(String.t()) :: waiter()
  def new_load_state_waiter(wait_state), do: {:load_state, wait_state}

  @spec new_url_waiter(url_matcher(), String.t()) :: waiter()
  def new_url_waiter(url_matcher, wait_state) do
    {:url, url_matcher, wait_state, :waiting_for_url}
  end

  @spec evaluate(waiter(), %{url: String.t(), load_states: MapSet.t(String.t())}) ::
          {:done, {:ok, nil}} | {:update, waiter()}
  def evaluate({:load_state, wait_state} = waiter, frame_state) do
    if load_state_reached?(frame_state.load_states, wait_state) do
      {:done, {:ok, nil}}
    else
      {:update, waiter}
    end
  end

  def evaluate({:url, url_matcher, wait_state, :waiting_for_url} = waiter, frame_state) do
    if url_matcher.(frame_state.url) do
      evaluate({:url, url_matcher, wait_state, :waiting_for_load_state}, frame_state)
    else
      {:update, waiter}
    end
  end

  def evaluate({:url, _url_matcher, wait_state, :waiting_for_load_state} = waiter, frame_state) do
    if load_state_reached?(frame_state.load_states, wait_state) do
      {:done, {:ok, nil}}
    else
      {:update, waiter}
    end
  end

  defp load_state_reached?(_load_states, "commit"), do: true
  defp load_state_reached?(load_states, wait_state), do: MapSet.member?(load_states, wait_state)
end
