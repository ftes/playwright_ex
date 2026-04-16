defmodule PlaywrightEx.DownloadWaiter do
  @moduledoc false
  use GenServer

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Download

  @page_closed_error "Download failed because page was closed!"
  @page_crashed_error "Download failed because page crashed!"

  defstruct connection: nil,
            page_id: nil,
            timeout: nil,
            waiter_from: nil,
            result: nil,
            timer_ref: nil

  @spec start(atom(), PlaywrightEx.guid(), timeout()) :: {:ok, pid()} | {:error, any()}
  def start(connection, page_id, timeout) do
    GenServer.start(__MODULE__, %{connection: connection, page_id: page_id, timeout: timeout})
  end

  @spec await(pid()) :: {:ok, String.t()} | {:error, map()}
  def await(pid) do
    GenServer.call(pid, :await, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, %{message: "Download waiter is no longer running"}}
    :exit, reason -> {:error, %{message: Exception.format_exit(reason)}}
  end

  @impl true
  def init(%{connection: connection, page_id: page_id, timeout: timeout}) do
    Connection.subscribe(connection, self(), page_id)
    timer_ref = Process.send_after(self(), :waiter_timeout, timeout)

    state = %__MODULE__{
      connection: connection,
      page_id: page_id,
      timeout: timeout,
      timer_ref: timer_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:await, _from, %{result: result} = state) when not is_nil(result) do
    {:stop, :normal, result, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | waiter_from: from}}
  end

  @impl true
  def handle_info({:playwright_msg, %{method: :download, params: params}}, state) do
    artifact_guid = params.artifact.guid

    result =
      if Connection.remote?(state.connection) do
        Download.save_as(artifact_guid, connection: state.connection, timeout: state.timeout)
      else
        Download.path(artifact_guid, connection: state.connection, timeout: state.timeout)
      end

    cancel_timer(state.timer_ref)
    resolve(state, result)
  end

  def handle_info({:playwright_msg, %{guid: page_id, method: :close}}, %{page_id: page_id} = state) do
    cancel_timer(state.timer_ref)
    resolve(state, {:error, %{message: @page_closed_error}})
  end

  def handle_info({:playwright_msg, %{guid: page_id, method: :__dispose__}}, %{page_id: page_id} = state) do
    cancel_timer(state.timer_ref)
    resolve(state, {:error, %{message: @page_closed_error}})
  end

  def handle_info({:playwright_msg, %{guid: page_id, method: :crash}}, %{page_id: page_id} = state) do
    cancel_timer(state.timer_ref)
    resolve(state, {:error, %{message: @page_crashed_error}})
  end

  def handle_info(:waiter_timeout, state) do
    resolve(state, {:error, %{message: "Timeout #{state.timeout}ms exceeded."}})
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp resolve(%{waiter_from: nil} = state, result) do
    {:noreply, %{state | result: result, timer_ref: nil}}
  end

  defp resolve(state, result) do
    GenServer.reply(state.waiter_from, result)
    {:stop, :normal, %{state | result: result, timer_ref: nil}}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: _ = Process.cancel_timer(timer_ref, async: true, info: false)
end
