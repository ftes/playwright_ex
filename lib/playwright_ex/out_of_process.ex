defmodule PlaywrightEx.OutOfProcess do
  @upstream "packages/playwright-core/src/outofprocess.ts"
  @moduledoc """
  Port of `#{@upstream}`: `PlaywrightClient` as a process, started by `PlaywrightEx.Supervisor`.

  `init/1` starts the driver over `PlaywrightEx.Transport.Pipe`, wires it to a connection process
  (`PlaywrightEx.Runtime.Conn`, which holds the `PlaywrightEx.Client.Connection`) and initializes
  the root `Playwright` object, so it is ready once the supervisor has started.

  Deviations: when the driver exits unexpectedly the connection is closed (pending and later
  calls fail with `TargetClosedError`, as in the Python client) and this process stops, so
  the supervisor can restart it. Upstream only resolves its close promise. Closing the
  connection emulates the close of every page, context and browser, as `connectToBrowser`
  (connect.ts) does for a remote connection: pages and contexts emit `close`, then browsers
  `disconnected`, and waits on them reject. This process stops once that is done, as the
  objects and their listeners live in the connection's table. Upstream has no restart, and its
  waits hang on a lost driver; here a lost driver is noticed by `disconnected` and replaced.
  """
  use GenServer

  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.Connect
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Driver
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Transport.Pipe

  @close_emulation_timeout 4_000

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

    # deviation: the close of every browser, context and page is emulated on a lost driver, as
    # connect.ts does upon disconnect (see the moduledoc). OTP restarts the driver, and callers
    # notice by `disconnected`; JS has no restart and its pending waits hang.
    Connection.on(connection, "close", fn _ ->
      Connect.emulate_close(connected_browsers(connection), fn -> send(parent, :close_emulated) end)
    end)

    env = Driver.driver_env() ++ Enum.to_list(Keyword.get(opts, :env, []))
    # Elixir only: `isUnderTest()` of the client follows the driver's env (see Connection._is_under_test/1).
    under_test = Enum.find_value(Enum.reverse(env), fn {k, v} -> if to_string(k) == "PWTEST_UNDER_TEST", do: v end)
    under_test = if under_test == nil, do: System.get_env("PWTEST_UNDER_TEST"), else: under_test
    Connection._set_under_test(connection, under_test not in [nil, false, "", "false", "0"])

    {:ok, transport} =
      Pipe.start_link(
        executable: executable,
        env: env,
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

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state),
    do: {:stop, {:shutdown, {:connection_exit, reason}}, state}

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

  # Returns once the close emulation (see init/1) is done, or the connection was closed before.
  defp close_connection(state) do
    closing =
      Conn.run(state.conn, fn ->
        closing = !Heap.get(state.connection, :_closedError)
        Connection.close(state.connection, "Playwright driver closed")
        closing
      end)

    # Bounded: a listener that never returns or awaits would stall the restart (or a bug in the
    # emulation); within the supervisor's default shutdown time.
    if closing do
      receive do
        :close_emulated -> :ok
      after
        @close_emulation_timeout -> :ok
      end
    end
  rescue
    # The connection process is gone already.
    PlaywrightEx.TargetClosedError -> :ok
  end

  # Elixir only: the connection's browsers not closed yet (launched, persistent and over CDP), in
  # creation order.
  defp connected_browsers(connection) do
    for %PlaywrightEx.Browser{} = browser <- Heap.map_values(connection, :_objects),
        Browser.is_connected(browser),
        do: browser
  end
end
