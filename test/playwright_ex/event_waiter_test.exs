defmodule PlaywrightEx.EventWaiterTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Connection
  alias PlaywrightEx.EventWaiter
  alias PlaywrightEx.Page

  defmodule DummyTransport do
    @moduledoc false
    @behaviour PlaywrightEx.Transport

    @impl true
    def post(_name, _message), do: :ok
  end

  setup do
    name = String.to_atom("event_connection_#{System.unique_integer([:positive])}")
    scope = Module.concat(name, Scope)
    start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})

    pid =
      start_supervised!({Connection, [[name: name, timeout: 1000, transport: {DummyTransport, nil}, pg_scope: scope]]})

    {:pending, data} = :sys.get_state(pid)
    Connection.handle_playwright_msg(name, %{id: data.initialization.id, result: %{}})
    create(name, "Playwright", "Playwright")
    create(name, "page", "Page")
    _ = Connection.initializer!(name, "page")
    %{connection: name, connection_pid: pid, scope: scope}
  end

  test "subscription is ready when arm returns", %{connection: connection, scope: scope} do
    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 1000)
    assert [_pid] = :pg.get_members(scope, {:guid, "page"})
    event = download("first")
    task = Task.async(fn -> Connection.handle_playwright_msg(connection, event) end)
    Task.await(task)
    assert {:ok, ^event} = EventWaiter.await(pending)
    assert :ok = EventWaiter.cancel(pending)
  end

  test "only the first matching event is captured", %{connection: connection, scope: scope} do
    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 1000)
    [pid] = :pg.get_members(scope, {:guid, "page"})
    monitor = Process.monitor(pid)
    Connection.handle_playwright_msg(connection, %{guid: "page", method: :console, params: %{}})
    Connection.handle_playwright_msg(connection, download("first"))
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}
    assert reason in [:normal, :noproc]
    await_unsubscribed(connection, scope)
    Connection.handle_playwright_msg(connection, download("second"))
    Connection.handle_playwright_msg(connection, %{guid: "page", method: :close, params: %{}})
    assert {:ok, %{params: %{suggested_filename: "first.txt"}}} = EventWaiter.await(pending)
  end

  test "late events cannot replace a timeout", %{connection: connection, scope: scope} do
    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 10)
    await_unsubscribed(connection, scope)
    Connection.handle_playwright_msg(connection, download("late"))
    assert {:error, %{reason: :timeout}} = EventWaiter.await(pending)
  end

  test "infinite waiters drain unrelated events without affecting other subscribers", %{
    connection: connection,
    scope: scope
  } do
    parent = self()

    predicate = fn event ->
      if event.params.suggested_filename == "barrier.txt" do
        send(parent, Process.info(self(), :message_queue_len))
        false
      else
        true
      end
    end

    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: :infinity, predicate: predicate)
    [pid] = :pg.get_members(scope, {:guid, "page"})
    {:ok, console} = EventWaiter.arm("page", :console, connection: connection, timeout: :infinity)

    for index <- 1..100 do
      Connection.handle_playwright_msg(connection, %{guid: "page", method: :console, params: %{index: index}})
    end

    # The connection sends the barrier after every console event to the same task.
    Connection.handle_playwright_msg(connection, download("barrier"))
    assert_receive {:message_queue_len, 0}, 1000
    assert Process.alive?(pid)
    assert {:ok, %{method: :console, params: %{index: 1}}} = EventWaiter.await(console)

    Connection.handle_playwright_msg(connection, download("wanted"))
    assert {:ok, %{params: %{suggested_filename: "wanted.txt"}}} = EventWaiter.await(pending)
  end

  test "queued unrelated events cannot postpone an expired deadline", %{connection: connection, scope: scope} do
    parent = self()

    predicate = fn _event ->
      send(parent, :evaluating)

      receive do
        :continue -> false
      end
    end

    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 1000, predicate: predicate)
    [pid] = :pg.get_members(scope, {:guid, "page"})
    Connection.handle_playwright_msg(connection, download("skip"))
    assert_receive :evaluating, 1000

    for index <- 1..100 do
      Connection.handle_playwright_msg(connection, %{guid: "page", method: :console, params: %{index: index}})
    end

    Connection.handle_playwright_msg(connection, %{guid: "page", method: :close, params: %{}})
    _ = :sys.get_state(connection)
    Process.sleep(1050)
    send(pid, :continue)

    assert {:error, %{reason: :timeout}} = EventWaiter.await(pending)
    await_unsubscribed(connection, scope)
  end

  test "a queued event cannot revive an expired deadline", %{connection: connection, scope: scope} do
    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 100)
    [pid] = :pg.get_members(scope, {:guid, "page"})
    :erlang.suspend_process(pid)

    try do
      Process.sleep(150)
      Connection.handle_playwright_msg(connection, download("late"))
      _ = :sys.get_state(connection)
    after
      :erlang.resume_process(pid)
    end

    assert {:error, %{reason: :timeout}} = EventWaiter.await(pending)
  end

  test "infinity disables the timeout and can be canceled", %{connection: connection} do
    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: :infinity)
    Connection.handle_playwright_msg(connection, download("unlimited"))
    assert {:ok, _} = EventWaiter.await(pending)
    assert :ok = EventWaiter.cancel(pending)

    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: :infinity)
    assert :ok = EventWaiter.cancel(pending)
    assert :ok = EventWaiter.cancel(pending)
  end

  test "zero expires immediately and leaves no subscription", %{connection: connection, scope: scope} do
    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 0)
    Connection.handle_playwright_msg(connection, download("late"))
    assert {:error, %{reason: :timeout}} = EventWaiter.await(pending)
    assert :ok = EventWaiter.cancel(pending)
    await_unsubscribed(connection, scope)
  end

  test "timeout stays required and predicates must accept one argument", %{connection: connection} do
    assert_raise NimbleOptions.ValidationError, fn ->
      Page.expect_download("page", connection: connection)
    end

    assert_raise NimbleOptions.ValidationError, fn ->
      Page.expect_download("page", connection: connection, timeout: 1000, predicate: :invalid)
    end
  end

  test "predicates skip false and nil and accept the first truthy raw event", %{connection: connection} do
    predicate = fn event ->
      case event.params.suggested_filename do
        "false.txt" -> false
        "nil.txt" -> nil
        _ -> :accepted
      end
    end

    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 1000, predicate: predicate)
    for name <- ["false", "nil", "first", "second"], do: Connection.handle_playwright_msg(connection, download(name))
    assert {:ok, %{params: %{suggested_filename: "first.txt"}}} = EventWaiter.await(pending)
  end

  test "rejected events do not restart the deadline", %{connection: connection, scope: scope} do
    parent = self()

    predicate = fn event ->
      send(parent, :evaluated)
      event.params.suggested_filename == "late.txt"
    end

    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 100, predicate: predicate)

    [pid] = :pg.get_members(scope, {:guid, "page"})
    Connection.handle_playwright_msg(connection, download("skip"))
    assert_receive :evaluated
    :erlang.suspend_process(pid)

    try do
      Process.sleep(150)
      Connection.handle_playwright_msg(connection, download("late"))
      _ = :sys.get_state(connection)
    after
      :erlang.resume_process(pid)
    end

    assert {:error, %{reason: :timeout}} = EventWaiter.await(pending)
  end

  test "predicates do not filter lifecycle failures", %{connection: connection} do
    {:ok, pending} =
      EventWaiter.arm("page", :download,
        connection: connection,
        timeout: :infinity,
        predicate: fn _ -> false end
      )

    Connection.handle_playwright_msg(connection, download("skip"))
    Connection.handle_playwright_msg(connection, %{guid: "page", method: :close, params: %{}})
    assert {:error, %{reason: :close}} = EventWaiter.await(pending)
  end

  for event <- [:close, :crash, :__dispose__] do
    test "#{event} fails an unresolved waiter", %{connection: connection} do
      {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: 1000)
      Connection.handle_playwright_msg(connection, %{guid: "page", method: unquote(event), params: %{}})
      assert {:error, %{reason: unquote(event)}} = EventWaiter.await(pending)
    end
  end

  test "can capture a lifecycle event itself", %{connection: connection} do
    {:ok, pending} = EventWaiter.arm("page", :close, connection: connection, timeout: 1000)
    Connection.handle_playwright_msg(connection, %{guid: "page", method: :close, params: %{}})
    assert {:ok, %{method: :close}} = EventWaiter.await(pending)
  end

  test "rejects unknown and disposed channels", %{connection: connection} do
    assert {:error, %{reason: :disposed}} = EventWaiter.arm("missing", :download, connection: connection, timeout: 1000)
    Connection.handle_playwright_msg(connection, %{guid: "page", method: :__dispose__, params: %{}})
    assert {:error, %{reason: :disposed}} = EventWaiter.arm("page", :download, connection: connection, timeout: 1000)
  end

  test "connection loss resolves a waiter", %{connection: connection, connection_pid: pid} do
    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: :infinity)
    :gen_statem.stop(pid)
    assert {:error, %{reason: :connection_closed}} = EventWaiter.await(pending)
  end

  test "arming a stopped connection returns an error without leaving a task result", %{
    connection: connection,
    connection_pid: pid
  } do
    assert :ok = stop_supervised(Connection)

    for name <- [connection, pid] do
      assert {:error, %{reason: :connection_closed}} =
               EventWaiter.arm("page", :download, connection: name, timeout: :infinity)
    end

    refute_receive {_, _}
    refute_receive {:DOWN, _, :process, _, _}
  end

  test "normal owner exit cleans up a pending task", %{connection: connection, scope: scope} do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, _pending} = EventWaiter.arm("page", :download, connection: connection, timeout: :infinity)
        send(parent, :armed)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :armed
    [waiter] = :pg.get_members(scope, {:guid, "page"})
    monitor = Process.monitor(waiter)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, :normal}
    await_unsubscribed(connection, scope)
  end

  test "only the owner can await or cancel", %{connection: connection} do
    {:ok, pending} = EventWaiter.arm("page", :download, connection: connection, timeout: :infinity)

    Task.await(
      Task.async(fn ->
        assert_raise ArgumentError, fn -> EventWaiter.await(pending) end
        assert_raise ArgumentError, fn -> EventWaiter.cancel(pending) end
      end)
    )

    assert :ok = EventWaiter.cancel(pending)
  end

  test "refs isolate concurrent results and cancellation flushes only its own messages", %{connection: connection} do
    {:ok, first} = EventWaiter.arm("page", :download, connection: connection, timeout: 1000)
    Connection.handle_playwright_msg(connection, download("first"))
    {:ok, second} = EventWaiter.arm("page", :download, connection: connection, timeout: 1000)
    Connection.handle_playwright_msg(connection, download("second"))
    send(self(), :unrelated)

    assert {:ok, %{params: %{suggested_filename: "second.txt"}}} = EventWaiter.await(second)
    assert :ok = EventWaiter.cancel(first)
    assert :ok = EventWaiter.cancel(second)
    assert_receive :unrelated
    refute_receive {_, _}
    refute_receive {:DOWN, _, :process, _, _}
  end

  test "failed arming leaves no task or result", %{connection: connection, scope: scope} do
    assert {:error, %{reason: :disposed}} =
             EventWaiter.arm("missing", :download, connection: connection, timeout: :infinity)

    assert [] = :pg.get_members(scope, {:guid, "missing"})
    refute_receive {_, _}
    refute_receive {:DOWN, _, :process, _, _}
  end

  test "await_download preserves metadata and the custom connection", %{connection: connection} do
    predicate = fn %PlaywrightEx.Download{} = download ->
      download.connection == connection and download.suggested_filename == "report.txt"
    end

    {:ok, pending} = Page.expect_download("page", connection: connection, timeout: 1000, predicate: predicate)
    Connection.handle_playwright_msg(connection, download("unrelated"))
    Connection.handle_playwright_msg(connection, download("report"))
    assert {:ok, download} = Page.await_download(pending)

    assert download.connection == connection
    assert download.suggested_filename == "report.txt"
    assert download.url == "https://example.test/report"
    assert download.page_id == "page"
    assert download.artifact_guid == "report"
  end

  defp create(connection, guid, type) do
    Connection.handle_playwright_msg(connection, %{
      guid: "",
      method: :__create__,
      params: %{guid: guid, type: type, initializer: %{}}
    })
  end

  defp download(name) do
    %{
      guid: "page",
      method: :download,
      params: %{artifact: %{guid: name}, suggested_filename: name <> ".txt", url: "https://example.test/" <> name}
    }
  end

  defp await_unsubscribed(connection, scope) do
    eventually(fn ->
      _ = :sys.get_state(connection)
      :pg.get_members(scope, {:guid, "page"}) == []
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
