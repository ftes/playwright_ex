defmodule PlaywrightEx.OutOfProcess do
  @upstream "packages/playwright-core/src/outofprocess.ts"
  @moduledoc """
  Port of `#{@upstream}`: `PlaywrightClient` as a process, started by `PlaywrightEx.Supervisor`.

  `init/1` starts the driver over `PlaywrightEx.Transport.Pipe`, wires it to a connection process
  (`PlaywrightEx.Runtime.Conn`, which holds the `PlaywrightEx.Client.Connection`) and initializes
  the root `Playwright` object, so it is ready once the supervisor has started.

  Deviation: when the driver exits unexpectedly the connection is closed (pending and later
  calls fail with `TargetClosedError`, as in the Python client) and this process stops, so
  the supervisor can restart it. Upstream only resolves its close promise.
  """
  use GenServer

  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Driver
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Transport.Pipe

  # start  -- ported as start_link/1 and init/1
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "The root `PlaywrightEx.Client.Playwright` object."
  def playwright(server), do: GenServer.call(server, :playwright)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    executable = Driver.ensure_installed(Keyword.take(opts, [:executable, :node, :cache_dir]))
    # const connection = new Connection(...): a process (Elixir only).
    {:ok, conn} = Conn.start_link()
    connection = Conn.connection(conn)
    parent = self()

    {:ok, transport} =
      Pipe.start_link(
        executable: executable,
        env: Driver.driver_env() ++ Enum.to_list(Keyword.get(opts, :env, [])),
        # transport.onmessage = message => connection.dispatch(JSON.parse(message));
        on_message: fn message -> send(conn, {:pw_msg, message}) end,
        # transport.onclose = () => this._closePromise.resolve();
        on_close: fn -> send(parent, :transport_closed) end
      )

    # connection.onmessage = message => transport.send(JSON.stringify(message));
    # (Elixir: the connection process writes each turn's messages together.)
    Conn.set_transport(conn, fn messages -> Pipe.send_messages(transport, messages) end)

    playwright = Connection.initialize_playwright(connection)
    Heap.put(playwright, :driverProcess, transport)
    {:ok, %{conn: conn, connection: connection, transport: transport, playwright: playwright}}
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

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state), do: {:stop, {:shutdown, {:connection_exit, reason}}, state}
  def handle_info(_message, state), do: {:noreply, state}

  # stop(): closing the pipe makes the driver exit.
  # stop  -- ported as terminate/2 (GenServer.stop/1)
  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.transport), do: Pipe.close(state.transport)
    close_connection(state)
  catch
    :exit, _ -> close_connection(state)
  end

  defp close_connection(state) do
    Conn.run(state.conn, fn -> Connection.close(state.connection, "Playwright driver closed") end)
  rescue
    # The connection process is gone already.
    PlaywrightEx.TargetClosedError -> :ok
  end
end
