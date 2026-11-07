defmodule PlaywrightEx.Runtime.PromiseConnDownTest do
  # Not mirrored from upstream: a wait whose connection process exits rejects with
  # `TargetClosedError`, as a call does, instead of hanging (a latch or a subscription not tied to
  # a page or context, which no close emulation rejects). Each wait monitors the connection only
  # while armed: no monitor or `:DOWN` is left behind.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.Promise
  alias PlaywrightEx.TargetClosedError

  setup do
    {:ok, conn} = Conn.start_link(transport: fn _ -> :ok end)
    Process.unlink(conn)
    on_exit(fn -> Process.exit(conn, :kill) end)
    %{conn: conn, connection: Conn.connection(conn)}
  end

  test "a pending latch rejects when its connection process exits", %{conn: conn, connection: connection} do
    latch = Promise.new(connection)
    kill_when_armed(conn, connection, latch)

    assert_raise TargetClosedError, "Playwright driver closed", fn -> Promise.await(latch) end
    assert_clean()
  end

  test "a latch in a race and Promise.all rejects when its connection process exits", %{
    conn: conn,
    connection: connection
  } do
    latch = Promise.new(connection)
    other = Promise.new()
    kill_when_armed(conn, connection, latch)

    assert_raise TargetClosedError, fn -> Promise.await(Promise.race([Promise.all([latch]), other])) end
    assert_clean()
  end

  test "a subscription rejects when its connection process exits", %{conn: conn, connection: connection} do
    subscription = EventEmitter.subscribe(connection, "x")
    timer = Promise.timer(60_000)
    spawn(fn -> Process.exit(conn, :kill) end)

    assert_raise TargetClosedError, "Playwright driver closed", fn ->
      Promise.await(Promise.race([subscription, timer]))
    end

    Promise.free(timer)
    assert_clean()
  end

  test "a settled or losing latch leaves no monitor behind when the connection exits later", %{
    conn: conn,
    connection: connection
  } do
    settled = Promise.new(connection)
    Promise.resolve(settled, :value)
    assert Promise.await(settled) == :value

    losing = Promise.new(connection)
    subscription = EventEmitter.subscribe(connection, "x")
    assert Promise.await(Promise.race([losing, subscription, Promise.resolved(:won)])) == :won
    assert {:monitors, []} = Process.info(self(), :monitors)

    ref = Process.monitor(conn)
    Process.exit(conn, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    assert_clean()
  end

  test "a call whose params raise in the connection leaves no monitor behind", %{connection: connection} do
    root = Heap.get(connection, :_rootObject)

    assert_raise RuntimeError, "bad params", fn ->
      Connection.send_message_to_server(connection, root, "initialize", fn -> raise "bad params" end, %{})
    end

    assert Conn.run(connection.conn, fn -> Connection.callbacks(connection) end) == []
    assert_clean()
  end

  test "a call to a connection process killed meanwhile raises TargetClosedError", %{conn: conn} do
    assert_raise TargetClosedError, "Playwright driver closed", fn ->
      Conn.run(conn, fn -> Process.exit(self(), :kill) end)
    end
  end

  # Kills the connection once `latch` has a waiter (the awaiting test process).
  defp kill_when_armed(conn, connection, latch) do
    key = Heap.key(connection, {:latch, latch.ref})

    spawn(fn ->
      wait_until(fn -> match?([{_, {:pending, [_]}}], :ets.lookup(connection.table, key)) end)
      Process.exit(conn, :kill)
    end)
  end

  defp wait_until(fun) do
    if !fun.() do
      Process.sleep(1)
      wait_until(fun)
    end
  end

  defp assert_clean do
    assert {:monitors, []} = Process.info(self(), :monitors)
    Process.sleep(20)
    assert {:messages, []} = Process.info(self(), :messages)
  end
end
