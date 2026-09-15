defmodule PlaywrightEx.FrameWaiterIntegrationTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameWaiter

  defmodule DummyTransport do
    @moduledoc false
    @behaviour PlaywrightEx.Transport

    @impl PlaywrightEx.Transport
    def post(_name, _msg), do: :ok
  end

  test "document lookup retains the committed request until a new document commits" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    assert {:ok, nil} = Frame.document_request(frame_id, connection: connection)
    request = %{guid: "committed-request"}

    Connection.handle_playwright_msg(connection, %{
      guid: frame_id,
      method: :navigated,
      params: %{url: "https://example.test/first", new_document: %{request: request}}
    })

    assert {:ok, ^request} = Frame.document_request(frame_id, connection: Process.whereis(connection))

    Connection.handle_playwright_msg(connection, %{
      guid: "context-1",
      method: :request,
      params: %{request: %{guid: "pending-request"}}
    })

    Connection.handle_playwright_msg(connection, %{
      guid: frame_id,
      method: :navigated,
      params: %{
        url: "https://example.test/failed",
        new_document: %{request: %{guid: "pending-request"}},
        error: "aborted"
      }
    })

    assert {:ok, ^request} = Frame.document_request(frame_id, connection: connection)

    Connection.handle_playwright_msg(connection, %{
      guid: frame_id,
      method: :navigated,
      params: %{url: "https://example.test/first#fragment"}
    })

    assert {:ok, ^request} = Frame.document_request(frame_id, connection: connection)

    Connection.handle_playwright_msg(connection, %{
      guid: frame_id,
      method: :navigated,
      params: %{url: "about:blank", new_document: %{}}
    })

    assert {:ok, nil} = Frame.document_request(frame_id, connection: connection)
    assert subscribers(connection, frame_id) == []
  end

  test "document requests remain associated with their frame" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    create_frame(connection, "popup-frame", "context-1")

    for frame <- [frame_id, "popup-frame"] do
      Connection.handle_playwright_msg(connection, %{
        guid: frame,
        method: :navigated,
        params: %{url: "https://example.test/", new_document: %{request: %{guid: "request-#{frame}"}}}
      })
    end

    assert {:ok, %{guid: "request-frame-1"}} = Frame.document_request(frame_id, connection: connection)
    assert {:ok, %{guid: "request-popup-frame"}} = Frame.document_request("popup-frame", connection: connection)
  end

  test "document lookup returns connection errors at the boundary" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    stop_supervised!(Connection)
    assert {:error, %{reason: :connection_closed}} = Frame.document_request(frame_id, connection: connection)
  end

  test "records frame state before any caller waits" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    assert subscribers(connection, frame_id) == []

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :navigated, params: %{url: "about:blank#done"}})

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})
    assert frame_state(connection, frame_id).url == "about:blank#done"
    assert {:ok, nil} = FrameWaiter.wait_for_url(connection, frame_id, &(&1 == "about:blank#done"), "load", 0)
  end

  test "wait_for_url waits for navigated + loadstate events" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()

    task =
      Task.async(fn ->
        FrameWaiter.wait_for_url(
          connection,
          frame_id,
          &(&1 == "about:blank#done"),
          "load",
          500
        )
      end)

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :navigated, params: %{url: "about:blank#done"}})

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})

    assert {:ok, nil} = Task.await(task, 1_000)
  end

  test "infinity waits and cleans up subscriptions after success" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()

    load = Task.async(fn -> FrameWaiter.wait_for_load_state(connection, frame_id, "load", :infinity) end)

    url =
      Task.async(fn ->
        FrameWaiter.wait_for_url(connection, frame_id, &(&1 == "about:blank#done"), "load", :infinity)
      end)

    assert_eventually(fn -> length(subscribers(connection, frame_id)) == 2 end)

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :navigated, params: %{url: "about:blank#done"}})

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})
    assert {:ok, nil} = Task.await(load)
    assert {:ok, nil} = Task.await(url)
    assert_eventually(fn -> subscribers(connection, frame_id) == [] end)
  end

  test "zero checks cached state and leaves no subscription" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    assert {:ok, nil} = FrameWaiter.wait_for_load_state(connection, frame_id, "commit", 0)
    assert {:ok, nil} = FrameWaiter.wait_for_url(connection, frame_id, &(&1 == "about:blank"), "commit", 0)

    assert {:error, %{message: "Timeout 0ms exceeded."}} =
             FrameWaiter.wait_for_load_state(connection, frame_id, "load", 0)

    assert {:error, %{message: "Timeout 0ms exceeded."}} =
             FrameWaiter.wait_for_url(connection, frame_id, &(&1 == "missing"), "commit", 0)

    assert_eventually(fn -> subscribers(connection, frame_id) == [] end)
  end

  @tag capture_log: true
  test "a failing URL predicate only terminates its caller's task" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    parent = self()

    load = Task.async(fn -> FrameWaiter.wait_for_load_state(connection, frame_id, "load", :infinity) end)
    assert_eventually(fn -> length(subscribers(connection, frame_id)) == 1 end)

    {caller, monitor} =
      spawn_monitor(fn ->
        FrameWaiter.wait_for_url(
          connection,
          frame_id,
          fn url ->
            send(parent, {:evaluated, self()})
            if url == "about:blank#done", do: raise("predicate bug"), else: false
          end,
          "commit",
          :infinity
        )
      end)

    assert_receive {:evaluated, waiter}, 1000
    refute waiter == Process.whereis(connection)
    refute waiter == caller

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :navigated, params: %{url: "about:blank#done"}})

    assert_receive {:DOWN, ^monitor, :process, ^caller, {%RuntimeError{message: "predicate bug"}, [_ | _]}}, 1000

    assert Process.alive?(Process.whereis(connection))
    assert_eventually(fn -> length(subscribers(connection, frame_id)) == 1 end)
    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})
    assert {:ok, nil} = Task.await(load)
    assert {:ok, nil} = FrameWaiter.wait_for_url(connection, frame_id, &(&1 == "about:blank#done"), "load", 0)
  end

  test "waiters fail when frame is disposed" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()

    task =
      Task.async(fn ->
        FrameWaiter.wait_for_url(connection, frame_id, &(&1 == "about:blank#never"), "load", 500)
      end)

    assert_eventually(fn ->
      length(subscribers(connection, frame_id)) == 1
    end)

    Connection.handle_playwright_msg(connection, %{method: :__dispose__, guid: frame_id})

    assert {:error, %{message: "Navigating frame was detached!"}} = Task.await(task, 1_000)
  end

  test "waiters fail fast when page crashes" do
    %{connection: connection, frame_id: frame_id, page_id: page_id} = start_connection_with_frame!()

    task =
      Task.async(fn ->
        FrameWaiter.wait_for_url(connection, frame_id, &(&1 == "about:blank#never"), "load", 500)
      end)

    assert_eventually(fn ->
      length(subscribers(connection, frame_id)) == 1
    end)

    Connection.handle_playwright_msg(connection, %{guid: page_id, method: :crash, params: %{}})

    assert {:error, %{message: "Navigation failed because page crashed!"}} = Task.await(task, 1_000)
  end

  test "waiters fail fast when page is closed" do
    %{connection: connection, frame_id: frame_id, page_id: page_id} = start_connection_with_frame!()

    task =
      Task.async(fn ->
        FrameWaiter.wait_for_url(connection, frame_id, &(&1 == "about:blank#never"), "load", 500)
      end)

    assert_eventually(fn ->
      length(subscribers(connection, frame_id)) == 1
    end)

    Connection.handle_playwright_msg(connection, %{method: :__dispose__, guid: page_id})

    assert {:error, %{message: "Navigation failed because page was closed!"}} = Task.await(task, 1_000)
  end

  test "snapshot subscription cannot miss updates while the initial predicate is evaluating" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    parent = self()

    task =
      Task.async(fn ->
        FrameWaiter.wait_for_url(
          connection,
          frame_id,
          fn url ->
            if url == "about:blank" do
              send(parent, {:snapshot, self()})
              receive do: (:continue -> false)
            else
              url == "about:blank#done"
            end
          end,
          "load",
          :infinity
        )
      end)

    assert_receive {:snapshot, waiter}, 1000
    assert frame_state(connection, frame_id).url == "about:blank"

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :navigated, params: %{url: "about:blank#done"}})

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})
    assert_eventually(fn -> MapSet.member?(frame_state(connection, frame_id).load_states, "load") end)
    send(waiter, :continue)
    assert {:ok, nil} = Task.await(task)
  end

  test "new documents clear cached load state, and load-state removals stay recorded" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})
    assert_eventually(fn -> MapSet.member?(frame_state(connection, frame_id).load_states, "load") end)
    assert {:ok, nil} = FrameWaiter.wait_for_load_state(connection, frame_id, "load", 0)

    Connection.handle_playwright_msg(connection, %{
      guid: frame_id,
      method: :navigated,
      params: %{url: "https://example.test/new", new_document: %{}}
    })

    assert_eventually(fn -> frame_state(connection, frame_id).url == "https://example.test/new" end)

    assert {:error, %{message: "Timeout 0ms exceeded."}} =
             FrameWaiter.wait_for_load_state(connection, frame_id, "load", 0)

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})
    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{remove: "load"}})
    _ = :sys.get_state(connection)
    assert_eventually(fn -> frame_state(connection, frame_id).load_states == MapSet.new(["commit"]) end)

    assert {:error, %{message: "Timeout 0ms exceeded."}} =
             FrameWaiter.wait_for_load_state(connection, frame_id, "load", 0)
  end

  test "navigation errors only fail URL waits and raw subscribers still receive events" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    assert :ok = Connection.subscribe_sync(connection, self(), frame_id)
    load = Task.async(fn -> FrameWaiter.wait_for_load_state(connection, frame_id, "load", :infinity) end)
    url = Task.async(fn -> FrameWaiter.wait_for_url(connection, frame_id, fn _ -> false end, "load", :infinity) end)
    assert_eventually(fn -> length(subscribers(connection, frame_id)) == 2 end)

    event = %{guid: frame_id, method: :navigated, params: %{error: "navigation failed"}}
    Connection.handle_playwright_msg(connection, event)
    assert_receive {:playwright_msg, ^event}, 1000
    assert {:error, %{message: "navigation failed"}} = Task.await(url)
    assert_eventually(fn -> length(subscribers(connection, frame_id)) == 1 end)
    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})
    assert_receive {:playwright_msg, %{method: :loadstate}}, 1000
    assert {:ok, nil} = Task.await(load)
  end

  test "owner exit cleans up the task and its subscription" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()

    for reason <- [:kill, :shutdown] do
      caller = spawn(fn -> FrameWaiter.wait_for_load_state(connection, frame_id, "load", :infinity) end)
      assert_eventually(fn -> length(subscribers(connection, frame_id)) == 1 end)
      [waiter] = subscribers(connection, frame_id)
      monitor = Process.monitor(waiter)
      Process.exit(caller, reason)
      assert_receive {:DOWN, ^monitor, :process, ^waiter, _}, 1000
      assert_eventually(fn -> subscribers(connection, frame_id) == [] end)
    end
  end

  test "connection loss resolves waits and discards cached state" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    task = Task.async(fn -> FrameWaiter.wait_for_load_state(connection, frame_id, "load", :infinity) end)
    assert_eventually(fn -> length(subscribers(connection, frame_id)) == 1 end)
    pid = Process.whereis(connection)
    stop_supervised!(Connection)
    assert {:error, %{reason: :connection_closed}} = Task.await(task)
    refute Process.alive?(pid)
    assert {:error, %{reason: :connection_closed}} = FrameWaiter.wait_for_load_state(connection, frame_id, "commit", 0)
  end

  test "the URL and load phases share one deadline and timeouts clean up subscriptions" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    parent = self()

    task =
      Task.async(fn ->
        FrameWaiter.wait_for_url(
          connection,
          frame_id,
          fn url ->
            send(parent, {:evaluated_url, url})
            url == "about:blank#done"
          end,
          "load",
          1000
        )
      end)

    assert_receive {:evaluated_url, "about:blank"}, 1000
    Process.sleep(600)

    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :navigated, params: %{url: "about:blank#done"}})

    assert_receive {:evaluated_url, "about:blank#done"}, 1000
    # A fresh 1000ms timeout after matching the URL would accept this late load.
    Process.sleep(600)
    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :loadstate, params: %{add: "load"}})
    assert {:error, %{message: "Timeout 1000ms exceeded."}} = Task.await(task)
    assert_eventually(fn -> subscribers(connection, frame_id) == [] end)
  end

  test "a stuck predicate times out without blocking the connection" do
    %{connection: connection, frame_id: frame_id} = start_connection_with_frame!()
    parent = self()

    task =
      Task.async(fn ->
        FrameWaiter.wait_for_url(
          connection,
          frame_id,
          fn _ ->
            send(parent, {:predicate, self()})
            receive do: (:continue -> true)
          end,
          "commit",
          1000
        )
      end)

    assert_receive {:predicate, waiter}, 1000
    monitor = Process.monitor(waiter)
    assert {:ok, nil} = FrameWaiter.wait_for_load_state(connection, frame_id, "commit", 0)
    assert {:error, %{message: "Timeout 1000ms exceeded."}} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, :killed}, 1000
    assert_eventually(fn -> subscribers(connection, frame_id) == [] end)
  end

  test "closed and crashed pages reject later waits without reusing their cached load state" do
    %{connection: connection, frame_id: frame_id, page_id: page_id} = start_connection_with_frame!()

    for method <- [:close, :crash] do
      other_frame = "#{frame_id}-#{method}"
      other_page = "#{page_id}-#{method}"
      create_frame(connection, other_frame, "context-1", ["load"])
      create_page(connection, other_page, other_frame)
      Connection.handle_playwright_msg(connection, %{guid: other_page, method: method, params: %{}})
      _ = :sys.get_state(connection)

      expected =
        if method == :crash,
          do: "Navigation failed because page crashed!",
          else: "Navigation failed because page was closed!"

      assert {:error, %{message: ^expected}} = FrameWaiter.wait_for_load_state(connection, other_frame, "load", 0)
      assert subscribers(connection, other_frame) == []
      assert {:error, %{message: ^expected}} = Frame.document_request(other_frame, connection: connection)

      Connection.handle_playwright_msg(connection, %{guid: other_frame, method: :loadstate, params: %{add: "load"}})
      _ = :sys.get_state(connection)
      assert {:error, %{message: ^expected}} = FrameWaiter.wait_for_load_state(connection, other_frame, "load", 0)
    end
  end

  test "page disposal reaches a waiting frame even before protocol adoption" do
    %{connection: connection} = start_connection_with_frame!()
    create_frame(connection, "unadopted-frame", "context-1")
    task = Task.async(fn -> FrameWaiter.wait_for_load_state(connection, "unadopted-frame", "load", :infinity) end)
    assert_eventually(fn -> length(subscribers(connection, "unadopted-frame")) == 1 end)

    create_page(connection, "new-page", "unadopted-frame")
    Connection.handle_playwright_msg(connection, %{guid: "new-page", method: :__dispose__, params: %{}})
    assert {:error, %{message: "Navigation failed because page was closed!"}} = Task.await(task)

    assert {:error, %{message: "Navigation failed because page was closed!"}} =
             FrameWaiter.wait_for_load_state(connection, "unadopted-frame", "commit", 0)
  end

  test "adopted frames follow their current page and recursive disposal clears cached state" do
    %{connection: connection, frame_id: frame_id, page_id: page_id} = start_connection_with_frame!()
    create_frame(connection, "child-frame", frame_id)
    create_frame(connection, "other-main-frame", "context-1")
    create_page(connection, "other-page", "other-main-frame")
    task = Task.async(fn -> FrameWaiter.wait_for_load_state(connection, "child-frame", "load", :infinity) end)
    assert_eventually(fn -> length(subscribers(connection, "child-frame")) == 1 end)

    Connection.handle_playwright_msg(connection, %{guid: "other-page", method: :__adopt__, params: %{guid: frame_id}})
    Connection.handle_playwright_msg(connection, %{guid: page_id, method: :close, params: %{}})
    _ = :sys.get_state(connection)
    assert {:ok, nil} = FrameWaiter.wait_for_load_state(connection, "child-frame", "commit", 0)

    Connection.handle_playwright_msg(connection, %{guid: "other-page", method: :__dispose__, params: %{}})
    assert {:error, %{message: "Navigation failed because page was closed!"}} = Task.await(task)
    assert frame_state(connection, frame_id) == nil
    assert frame_state(connection, "child-frame") == nil

    assert {:error, %{message: "Navigating frame was detached!"}} =
             Frame.document_request("child-frame", connection: connection)

    assert subscribers(connection, "child-frame") == []

    assert {:error, %{message: "Navigating frame was detached!"}} =
             FrameWaiter.wait_for_load_state(connection, "child-frame", "commit", 0)
  end

  test "detaching a parent frame fails descendant waits without closing its page" do
    %{connection: connection, frame_id: frame_id, page_id: page_id} = start_connection_with_frame!()
    create_frame(connection, "child-frame", frame_id)
    task = Task.async(fn -> FrameWaiter.wait_for_load_state(connection, "child-frame", "load", :infinity) end)
    assert_eventually(fn -> length(subscribers(connection, "child-frame")) == 1 end)
    Connection.handle_playwright_msg(connection, %{guid: frame_id, method: :__dispose__, params: %{}})
    assert {:error, %{message: "Navigating frame was detached!"}} = Task.await(task)
    assert frame_state(connection, frame_id) == nil
    assert frame_state(connection, "child-frame") == nil

    assert {:error, %{message: "Navigating frame was detached!"}} =
             Frame.document_request("child-frame", connection: connection)

    assert Connection.initializer!(connection, page_id).main_frame.guid == frame_id
  end

  defp start_connection_with_frame! do
    connection = String.to_atom("frame_connection_#{System.unique_integer([:positive])}")
    scope = String.to_atom("frame_scope_#{System.unique_integer([:positive])}")
    frame_id = "frame-1"
    page_id = "page-1"

    start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})

    start_supervised!(
      {Connection,
       [
         [
           name: connection,
           timeout: 1_000,
           transport: {DummyTransport, :dummy},
           js_logger: nil,
           pg_scope: scope
         ]
       ]}
    )

    {:pending, data} = :sys.get_state(connection)
    Connection.handle_playwright_msg(connection, %{id: data.initialization.id, result: %{}})

    Connection.handle_playwright_msg(connection, %{
      guid: "",
      method: :__create__,
      params: %{type: "Playwright", guid: "Playwright", initializer: %{}}
    })

    assert_eventually(fn ->
      match?({:started, _}, :sys.get_state(connection))
    end)

    Connection.handle_playwright_msg(connection, %{
      guid: "context-1",
      method: :__create__,
      params: %{
        type: "Frame",
        guid: frame_id,
        initializer: %{url: "about:blank", load_states: ["commit"]}
      }
    })

    Connection.handle_playwright_msg(connection, %{
      guid: "context-1",
      method: :__create__,
      params: %{type: "Page", guid: page_id, initializer: %{main_frame: %{guid: frame_id}}}
    })

    Connection.handle_playwright_msg(connection, %{guid: page_id, method: :__adopt__, params: %{guid: frame_id}})

    assert Connection.initializer!(connection, frame_id).url == "about:blank"
    %{connection: connection, frame_id: frame_id, page_id: page_id}
  end

  defp create_frame(connection, frame_id, parent, load_states \\ ["commit"]) do
    Connection.handle_playwright_msg(connection, %{
      guid: parent,
      method: :__create__,
      params: %{type: "Frame", guid: frame_id, initializer: %{url: "about:blank", load_states: load_states}}
    })

    _ = :sys.get_state(connection)
  end

  defp create_page(connection, page_id, frame_id) do
    Connection.handle_playwright_msg(connection, %{
      guid: "context-1",
      method: :__create__,
      params: %{type: "Page", guid: page_id, initializer: %{main_frame: %{guid: frame_id}}}
    })

    _ = :sys.get_state(connection)
  end

  defp frame_state(connection, frame_id) do
    {:started, data} = :sys.get_state(connection)
    data.frame_states[frame_id]
  end

  defp subscribers(connection, frame_id) do
    {:started, data} = :sys.get_state(connection)
    :pg.get_local_members(data.config.pg_scope, {:frame, frame_id})
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, attempts) when attempts <= 0, do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
