defmodule Playwright.Runtime.ConnStallTest do
  # Not mirrored from upstream: a step that holds the dispatch barrier past the threshold logs one
  # warning, and the barrier still waits for it. On a connection of its own, with a low threshold.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Playwright.Client.EventEmitter
  alias Playwright.Runtime.Conn
  alias Playwright.Runtime.Promise

  setup do
    {:ok, conn} = Conn.start_link(transport: fn _ -> :ok end, stall_warning: 300)
    Process.unlink(conn)
    on_exit(fn -> Process.exit(conn, :kill) end)
    %{conn: conn, connection: Conn.connection(conn)}
  end

  test "a listener that blocks logs one warning, and dispatch still waits for it", %{conn: conn, connection: connection} do
    test = self()

    EventEmitter.on(connection, "x", fn _ ->
      Process.sleep(1_000)
      send(test, :listened)
    end)

    log = capture_log(fn -> Conn.run(conn, fn -> EventEmitter.emit(connection, "x") end) end)

    assert_received :listened
    assert [_] = Regex.scan(~r/stalls every page/, log)
    assert log =~ ~s(a "x" listener of connection)
    assert log =~ ~r"lib/process.ex:\d+: Process.sleep/1"
  end

  test "a route handler's stacktrace is its own, not the route listener's", %{conn: conn, connection: connection} do
    # The shape of `RouteHandler`: the route listener awaits the handler, started as an async function.
    EventEmitter.on(connection, "route", fn _ ->
      Promise.await(
        Promise.async(fn ->
          receive do
          after
            1_000 -> :ok
          end
        end)
      )
    end)

    log = capture_log(fn -> Conn.run(conn, fn -> EventEmitter.emit(connection, "route") end) end)

    assert [_] = Regex.scan(~r/stalls every page/, log)
    assert log =~ "a route handler of connection"
    assert log =~ ~r"It waits at:\n.*anonymous fn/0 in #{inspect(__MODULE__)}"
  end

  test "a step that blocks while an earlier step's timer runs is warned on time", %{conn: conn, connection: connection} do
    EventEmitter.on(connection, "x", fn _ -> Process.sleep(20) end)
    EventEmitter.on(connection, "x", fn _ -> Process.sleep(1_000) end)

    log = capture_log(fn -> Conn.run(conn, fn -> EventEmitter.emit(connection, "x") end) end)

    # The first listener's timer, re-armed for the rest of the second's threshold (not a whole one).
    assert [[_, waited]] = Regex.scan(~r/waited (\d+) ms/, log)
    assert String.to_integer(waited) in 300..449
  end
end
