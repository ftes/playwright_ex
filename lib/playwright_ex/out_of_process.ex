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

  Elixir only: a lost driver is logged (`Logger.error`, once per loss; a normal stop is not),
  and its connection hands its table to a keeper process before it stops
  (`PlaywrightEx.Runtime.Conn.hand_off/2`), so handles of the lost driver keep reading their last
  state, as JS objects stay readable while referenced: until the processes that created or
  closed its browsers and contexts have exited, or the supervisor has.
  """
  use GenServer

  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.Connect
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Driver
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.TargetClosedError
  alias PlaywrightEx.Transport.Pipe

  require Logger

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
        # (Elixir: with the driver's exit status, for the log of a lost driver.)
        on_close: fn status -> send(parent, {:transport_closed, status}) end
      )

    # connection.onmessage = message => transport.send(JSON.stringify(message));
    # (Elixir: the connection process writes each turn's messages together.)
    Conn.set_transport(conn, fn messages -> Pipe.send_messages(transport, messages) end)

    case initialize(conn, connection, transport) do
      {:ok, playwright} ->
        Heap.put(playwright, :driverProcess, transport)
        # Elixir only: the supervisor's name (for the log) and pid (a lost driver's table never
        # outlives it).
        {supervisor, lifeline} = Keyword.get(opts, :supervisor, {nil, self()})

        {:ok,
         %{
           conn: conn,
           connection: connection,
           transport: transport,
           playwright: playwright,
           supervisor: supervisor,
           lifeline: lifeline
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Elixir only: a driver that exits before it answers `initialize` fails the start. This process
  # handles the pipe's close only once started, so a watcher closes the connection meanwhile,
  # which rejects the call (JS: it would hang).
  defp initialize(conn, connection, transport) do
    watcher = spawn(fn -> close_when_down(transport, conn, connection) end)

    try do
      {:ok, Connection.initialize_playwright(connection)}
    rescue
      TargetClosedError ->
        # The pipe sends its close before it exits.
        receive do
          {:transport_closed, status} -> {:error, {:shutdown, {:driver_closed, status}}}
          {:EXIT, ^transport, reason} -> {:error, {:shutdown, {:transport_exit, reason}}}
        after
          @close_emulation_timeout -> {:error, {:shutdown, :driver_closed}}
        end
    after
      Process.exit(watcher, :kill)
    end
  end

  defp close_when_down(transport, conn, connection) do
    ref = Process.monitor(transport)

    receive do
      {:DOWN, ^ref, :process, _, _} ->
        Conn.run(conn, fn -> Connection.close(connection, "Playwright driver closed") end)
    end
  rescue
    TargetClosedError -> :ok
  end

  @impl true
  def handle_call(:playwright, _from, state), do: {:reply, state.playwright, state}

  @impl true
  def handle_info({:transport_closed, status}, state) do
    driver_lost(state, status)
    {:stop, {:shutdown, :driver_closed}, state}
  end

  def handle_info({:EXIT, transport, reason}, %{transport: transport} = state) do
    driver_lost(state, {:exit, reason})
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

  # Elixir only: logs the loss, closes the connection and hands its table off (see the moduledoc).
  # Not on a normal stop: terminate/2 closes the pipe, whose close message is not handled then.
  defp driver_lost(state, cause) do
    {browsers, contexts} = affected(state.connection)

    Logger.error(
      "Playwright driver lost (#{describe(cause)}): driver #{Driver.version()}, " <>
        "supervisor #{inspect(state.supervisor)}, #{count(browsers, "browser")} and " <>
        "#{count(contexts, "context")} closed; starting a new driver"
    )

    close_connection(state)
    Conn.hand_off(state.conn, state.lifeline)
  end

  defp affected(connection) do
    browsers = connected_browsers(connection)
    {length(browsers), browsers |> Enum.map(&length(Browser.contexts(&1))) |> Enum.sum()}
  rescue
    TargetClosedError -> {0, 0}
  end

  # A program killed by a signal exits with 128 + the signal's number.
  defp describe(nil), do: "its pipe was closed"
  defp describe({:exit, reason}), do: "its pipe process exited: #{inspect(reason)}"
  defp describe(137), do: "exit status 137: SIGKILL, often out of memory"
  defp describe(status) when status > 128, do: "exit status #{status}: signal #{status - 128}"
  defp describe(status), do: "exit status #{status}"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

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
    TargetClosedError -> :ok
  end

  # Elixir only: the connection's browsers not closed yet (launched, persistent and over CDP), in
  # creation order.
  defp connected_browsers(connection) do
    for %PlaywrightEx.Browser{} = browser <- Heap.map_values(connection, :_objects),
        Browser.is_connected(browser),
        do: browser
  end
end
