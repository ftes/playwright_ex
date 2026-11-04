defmodule PlaywrightEx.OutOfProcess do
  @upstream "packages/playwright-core/src/outofprocess.ts"
  @moduledoc """
  Port of `#{@upstream}`: `PlaywrightClient` as a process, started by `PlaywrightEx.Supervisor`.

  `init/1` starts the driver over `PlaywrightEx.Transport.Pipe`, wires it to a
  `PlaywrightEx.Client.Connection` and initializes the root `Playwright` object, so it is
  ready once the supervisor has started.

  Deviation: when the driver exits unexpectedly the connection is closed (pending and later
  calls fail with `TargetClosedError`, as in the Python client) and this process stops, so
  the supervisor can restart it. Upstream only resolves its close promise.
  """
  use GenServer

  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Driver
  alias PlaywrightEx.Runtime.Baton
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Transport.Pipe

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "The root `PlaywrightEx.Client.Playwright` object."
  def playwright(server), do: GenServer.call(server, :playwright)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    baton = Baton.get(Keyword.fetch!(opts, :baton))
    executable = Driver.ensure_installed(Keyword.take(opts, [:executable, :node, :cache_dir]))
    connection = Connection.new(baton)
    parent = self()

    {:ok, transport} =
      Pipe.start_link(
        executable: executable,
        env: Driver.driver_env() ++ Enum.to_list(Keyword.get(opts, :env, [])),
        # transport.onmessage = message => connection.dispatch(JSON.parse(message));
        on_message: fn message -> Baton.post(connection.baton, fn -> Connection.dispatch(connection, message) end) end,
        # transport.onclose = () => this._closePromise.resolve();
        on_close: fn -> send(parent, :transport_closed) end
      )

    # connection.onmessage = message => transport.send(JSON.stringify(message));
    Heap.put(connection, :onmessage, fn message -> Pipe.send_message(transport, message) end)

    playwright = Baton.with_baton(connection.baton, fn -> Connection.initialize_playwright(connection) end)
    Heap.put(playwright, :driverProcess, transport)
    {:ok, %{connection: connection, transport: transport, playwright: playwright}}
  end

  @impl true
  def handle_call(:playwright, _from, state), do: {:reply, state.playwright, state}

  @impl true
  def handle_info(:transport_closed, state) do
    close_connection(state)
    {:stop, {:shutdown, :driver_closed}, state}
  end

  def handle_info({:EXIT, transport, reason}, %{transport: transport} = state) do
    close_connection(state)
    {:stop, {:shutdown, {:transport_exit, reason}}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # stop(): closing the pipe makes the driver exit.
  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.transport), do: Pipe.close(state.transport)
    close_connection(state)
  catch
    :exit, _ -> close_connection(state)
  end

  defp close_connection(state) do
    Baton.post(state.connection.baton, fn -> Connection.close(state.connection, "Playwright driver closed") end)
  end
end
