defmodule PlaywrightEx.Runtime.ProcessOwner do
  @moduledoc """
  Runtime support (not ported from upstream): rows owned by a process rather than a protocol
  object, for latches that outlive no particular object (`Promise.async(fun, shared: true)`, the
  facade's promise handles). One process of the application writes them (as a connection writes
  its table, see `PlaywrightEx.Runtime.Heap`) and deletes a process's rows when it exits.

  `owner(pid)` is the owner handle (`%{guid: pid, conn: _, table: _}`) to create latches on.

  It also owns `zones/0`, the public table of the API calls' zone fields that another process
  assigned (`PlaywrightEx.Client.ChannelOwner._assign/2`), keyed `{pid, _}` by the process whose
  call they are: deleted when it exits (`monitor_zones/1`).
  """
  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The owner handle of `pid`'s rows (monitored: freed when it exits)."
  def owner(pid \\ self()) do
    case Process.get({__MODULE__, pid}) do
      nil ->
        owner = GenServer.call(__MODULE__, {:owner, pid})
        if pid == self(), do: Process.put({__MODULE__, pid}, owner)
        owner

      owner ->
        owner
    end
  end

  @zones PlaywrightEx.Runtime.ProcessOwner.Zones

  @doc "The table of the zone fields (`PlaywrightEx.Client.ChannelOwner._assign/2`)."
  def zones, do: @zones

  @doc "Monitors `pid`, whose `zones/0` rows (`{pid, _}`) go when it exits."
  def monitor_zones(pid), do: GenServer.cast(__MODULE__, {:monitor, pid})

  @impl true
  def init(nil) do
    :ets.new(@zones, [:named_table, :public, :set, write_concurrency: true])

    {:ok, %{table: :ets.new(__MODULE__, [:ordered_set, :protected, read_concurrency: true]), monitored: %{}}}
  end

  @impl true
  def handle_call({:owner, pid}, _from, state),
    do: {:reply, %{guid: pid, conn: self(), table: state.table}, monitor(state, pid)}

  # `PlaywrightEx.Runtime.Conn.run/2`'s protocol: `Heap.atomic/2` on an owner handle.
  def handle_call({:run, fun, _token}, _from, state) do
    reply =
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:raise, kind, reason, __STACKTRACE__}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:monitor, pid}, state), do: {:noreply, monitor(state, pid)}

  defp monitor(state, pid) do
    if Map.has_key?(state.monitored, pid),
      do: state,
      else: put_in(state.monitored[pid], Process.monitor(pid))
  end

  @impl true
  def handle_info({:DOWN, _mref, :process, pid, _reason}, state) do
    # Pending awaiters of its latches would wait forever: reject them.
    for {{^pid, {:latch, _}}, {:pending, waiters}} <- :ets.select(state.table, [{{{pid, :_}, :_}, [], [:"$_"]}]),
        {waiter, wref} <- waiters,
        do:
          send(waiter, {:pw, wref, {:error, PlaywrightEx.TargetClosedError.new("The promise's owner process exited")}})

    :ets.select_delete(state.table, [{{{pid, :_}, :_}, [], [true]}])
    :ets.match_delete(@zones, {{pid, :_}, :_})
    {:noreply, %{state | monitored: Map.delete(state.monitored, pid)}}
  end
end
