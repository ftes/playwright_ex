defmodule PlaywrightEx.ConnectionTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Connection

  defmodule DummyTransport do
    @moduledoc false
    @behaviour PlaywrightEx.Transport

    @impl PlaywrightEx.Transport
    def post(recipient, msg) when is_pid(recipient) do
      send(recipient, {:transport_post, msg})
      :ok
    end

    def post(_name, _msg), do: :ok
  end

  defmodule TestJsLogger do
    @moduledoc false

    def log(level, message, msg) do
      send(msg.params.test_pid, {:js_log, level, message})
    end
  end

  test "waits for both the initialize response and Playwright creation" do
    name = start_uninitialized_connection!(self())
    assert_receive {:transport_post, %{id: initialization_id, method: :initialize}}

    Connection.handle_playwright_msg(name, %{
      guid: "",
      method: :__create__,
      params: %{type: "Playwright", guid: "Playwright", initializer: %{}}
    })

    assert {:pending, _} = :sys.get_state(name)
    Connection.handle_playwright_msg(name, %{id: initialization_id, result: %{playwright: %{guid: "Playwright"}}})

    assert_eventually(fn -> match?({:started, _}, :sys.get_state(name)) end)
  end

  test "sends command timeouts in metadata" do
    name = start_connection!(self())

    assert_receive {:transport_post,
                    %{
                      id: initialization_id,
                      guid: "",
                      method: :initialize,
                      params: %{sdk_language: :javascript},
                      metadata: %{timeout: 1_000}
                    }}

    assert is_integer(initialization_id)

    task =
      Task.async(fn ->
        Connection.send(
          name,
          %{guid: "guid-0", method: :expect, params: %{selector: "#missing", timeout: 50}},
          50
        )
      end)

    assert_receive {:transport_post, %{id: id, params: %{selector: "#missing"}, metadata: %{timeout: 50}}}

    Connection.handle_playwright_msg(name, %{id: id, result: %{}})
    assert %{id: ^id, result: %{}} = Task.await(task)
  end

  test "locator disposal is unlimited and preserves JS error precedence" do
    name = start_connection!(self())
    assert_receive {:transport_post, %{method: :initialize}}
    evaluation_error = %{error: %{name: "Error", message: "evaluation failed"}}
    disposal_error = %{error: %{name: "Error", message: "disposal failed"}}
    closed_error = %{error: %{name: "TargetClosedError", message: "closed"}}

    for {evaluation, disposal, expected} <- [
          {%{result: %{value: %{s: "done"}}}, %{result: %{}}, {:ok, "done"}},
          {%{error: evaluation_error}, %{result: %{}}, {:error, evaluation_error}},
          {%{error: evaluation_error}, %{error: closed_error}, {:error, evaluation_error}},
          {%{result: %{value: %{s: "done"}}}, %{error: closed_error}, {:ok, "done"}},
          {%{result: %{value: %{s: "done"}}}, %{error: disposal_error}, {:error, disposal_error}},
          {%{error: evaluation_error}, %{error: disposal_error}, {:error, disposal_error}}
        ] do
      task =
        Task.async(fn ->
          PlaywrightEx.Locator.evaluate("frame",
            connection: name,
            selector: "button",
            expression: "element => element.tagName",
            is_function: true,
            timeout: 500
          )
        end)

      assert_receive {:transport_post, %{id: resolve_id, method: :wait_for_selector}}
      Connection.handle_playwright_msg(name, %{id: resolve_id, result: %{element: %{guid: "element"}}})
      assert_receive {:transport_post, %{id: evaluate_id, method: :evaluate_expression, metadata: %{timeout: 0}}}
      Connection.handle_playwright_msg(name, Map.put(evaluation, :id, evaluate_id))
      assert_receive {:transport_post, %{id: dispose_id, guid: "element", method: :dispose, metadata: %{timeout: 0}}}
      Connection.handle_playwright_msg(name, Map.put(disposal, :id, dispose_id))
      assert Task.await(task) == expected
    end
  end

  test "locator disposes its handle before reraising a local evaluation exception" do
    name = start_connection!(self())
    assert_receive {:transport_post, %{method: :initialize}}

    task =
      Task.async(fn ->
        assert_raise ArgumentError, ~r/unsupported serialized value shape/, fn ->
          PlaywrightEx.Locator.evaluate("frame",
            connection: name,
            selector: "button",
            expression: "element => element.tagName",
            is_function: true,
            timeout: 500
          )
        end
      end)

    assert_receive {:transport_post, %{id: resolve_id, method: :wait_for_selector}}
    Connection.handle_playwright_msg(name, %{id: resolve_id, result: %{element: %{guid: "element"}}})
    assert_receive {:transport_post, %{id: evaluate_id, method: :evaluate_expression}}
    Connection.handle_playwright_msg(name, %{id: evaluate_id, result: %{value: %{unsupported: true}}})
    assert_receive {:transport_post, %{id: dispose_id, method: :dispose}}
    assert Task.yield(task, 20) == nil
    Connection.handle_playwright_msg(name, %{id: dispose_id, result: %{}})
    assert %ArgumentError{} = Task.await(task)
  end

  test "zero times out without posting a command" do
    name = start_connection!(self())
    assert_receive {:transport_post, %{method: :initialize}}
    assert %{error: %{reason: :timeout}} = Connection.send(name, %{guid: "frame", method: :click}, 0)
    refute_receive {:transport_post, _}
  end

  test "infinity is translated only at the protocol boundary" do
    name = start_connection!(self())
    assert_receive {:transport_post, %{method: :initialize}}
    task = Task.async(fn -> Connection.send(name, %{guid: "frame", method: :click}, :infinity) end)
    assert_receive {:transport_post, %{id: id, metadata: %{timeout: 0}}}
    assert Task.yield(task, 20) == nil
    Connection.handle_playwright_msg(name, %{id: id, result: %{}})
    assert %{result: %{}} = Task.await(task)
  end

  test "keyboard delays preserve zero and infinity and pad finite timeouts" do
    name = start_connection!(self())
    assert_receive {:transport_post, %{method: :initialize}}

    for {method, args, finite_timeout} <- [{:press, [key: "a"], 120}, {:type, [text: "ab"], 140}] do
      opts = [connection: name, selector: "input", delay: 20] ++ args
      assert {:error, %{reason: :timeout}} = apply(PlaywrightEx.Frame, method, ["frame", [timeout: 0] ++ opts])
      refute_receive {:transport_post, _}

      for {timeout, wire_timeout} <- [{:infinity, 0}, {100, finite_timeout}] do
        task = Task.async(fn -> apply(PlaywrightEx.Frame, method, ["frame", [timeout: timeout] ++ opts]) end)
        assert_receive {:transport_post, %{id: id, method: ^method, metadata: %{timeout: ^wire_timeout}}}
        Connection.handle_playwright_msg(name, %{id: id, result: %{}})
        assert {:ok, _} = Task.await(task)
      end
    end
  end

  test "stopping a connection resolves its pending call" do
    name = start_connection!(self())
    assert_receive {:transport_post, %{method: :initialize}}
    task = Task.async(fn -> Connection.send(name, %{guid: "frame", method: :click}, :infinity) end)
    assert_receive {:transport_post, %{method: :click}}
    :ok = :gen_statem.stop(name)
    assert %{error: %{reason: :connection_closed}} = Task.await(task)
  end

  test "supervisor shutdown resolves a pending connection call" do
    name = start_connection!(self())
    assert_receive {:transport_post, %{method: :initialize}}
    task = Task.async(fn -> Connection.send(name, %{guid: "frame", method: :click}, :infinity) end)
    assert_receive {:transport_post, %{method: :click}}
    assert :ok = stop_supervised(name)
    assert %{error: %{reason: :connection_closed}} = Task.await(task)
  end

  test "calls to a stopped connection return errors" do
    name = start_connection!()
    pid = Process.whereis(name)
    assert :ok = stop_supervised(name)
    assert %{error: %{reason: :connection_closed}} = Connection.send(pid, %{guid: "frame", method: :click}, 100)
    assert {:error, %{reason: :connection_closed}} = Connection.fetch_transport(pid)
  end

  test "transport lookup is tagged and the legacy predicate stays boolean" do
    name = start_connection!()
    assert {:ok, DummyTransport} = Connection.fetch_transport(name)
    assert Connection.remote?(name) == true
  end

  test "unexpected process exits propagate" do
    for reason <- [:unexpected_bug, {:shutdown, :unhandled_reason}] do
      pid = spawn(fn -> receive do: ({:"$gen_call", _, _} -> exit(reason)) end)

      assert {^reason, {:gen_statem, :call, _}} =
               catch_exit(Connection.send(pid, %{guid: "frame", method: :click}, 100))
    end
  end

  test "a missing reply returns a timeout error" do
    name = start_connection!(self())
    assert_receive {:transport_post, %{method: :initialize}}
    assert %{error: %{reason: :timeout}} = Connection.send(name, %{guid: "frame", method: :click}, 1)
    assert_receive {:transport_post, %{id: id}}
    Connection.handle_playwright_msg(name, %{id: id, result: %{}})
    _ = :sys.get_state(name)
    refute_receive {_reference, _reply}
  end

  test "initialization uses the same timeout translation" do
    assert {:ok, :pending, _} = Connection.init(%{timeout: :infinity, transport: {DummyTransport, self()}})
    assert_receive {:transport_post, %{method: :initialize, metadata: %{timeout: 0}}}
    assert {:stop, :timeout} = Connection.init(%{timeout: 0})
    refute_receive {:transport_post, _}
  end

  test "deduplicates subscribers per guid" do
    name = start_connection!()

    Connection.subscribe(name, self(), "guid-1")
    Connection.subscribe(name, self(), "guid-1")

    Connection.handle_playwright_msg(name, %{guid: "guid-1", method: :navigated, params: %{url: "about:blank"}})

    assert_receive {:playwright_msg, %{guid: "guid-1"}}
    refute_receive {:playwright_msg, %{guid: "guid-1"}}
  end

  test "unsubscribe stops delivery for guid" do
    name = start_connection!()

    Connection.subscribe(name, self(), "guid-2")
    Connection.unsubscribe(name, self(), "guid-2")

    Connection.handle_playwright_msg(name, %{guid: "guid-2", method: :navigated, params: %{url: "about:blank"}})

    refute_receive {:playwright_msg, %{guid: "guid-2"}}
  end

  test "dead subscriber does not break delivery to live subscriber" do
    name = start_connection!()
    test_pid = self()

    subscriber =
      spawn(fn ->
        receive do
          {:playwright_msg, %{guid: "guid-3"}} -> send(test_pid, :unexpected)
        end
      end)

    Connection.subscribe(name, subscriber, "guid-3")
    Process.exit(subscriber, :kill)
    Connection.subscribe(name, self(), "guid-3")

    Connection.handle_playwright_msg(name, %{guid: "guid-3", method: :navigated, params: %{url: "about:blank"}})

    assert_receive {:playwright_msg, %{guid: "guid-3"}}
    refute_receive :unexpected
  end

  test "dispose clears subscribers for disposed guid" do
    name = start_connection!()
    Connection.subscribe(name, self(), "guid-4")

    Connection.handle_playwright_msg(name, %{method: :__dispose__, guid: "guid-4"})
    assert_receive {:playwright_msg, %{guid: "guid-4", method: :__dispose__}}

    Connection.handle_playwright_msg(name, %{guid: "guid-4", method: :navigated, params: %{url: "about:blank"}})

    refute_receive {:playwright_msg, %{guid: "guid-4"}}
  end

  test "adoption and recursive disposal remove child channels" do
    name = start_connection!()

    Connection.handle_playwright_msg(name, %{
      guid: "Playwright",
      method: :__create__,
      params: %{type: "BrowserContext", guid: "context-1", initializer: %{}}
    })

    Connection.handle_playwright_msg(name, %{
      guid: "context-1",
      method: :__create__,
      params: %{type: "Frame", guid: "frame-1", initializer: %{url: "about:blank", load_states: []}}
    })

    Connection.handle_playwright_msg(name, %{
      guid: "context-1",
      method: :__create__,
      params: %{type: "Page", guid: "page-1", initializer: %{main_frame: %{guid: "frame-1"}}}
    })

    Connection.handle_playwright_msg(name, %{guid: "page-1", method: :__adopt__, params: %{guid: "frame-1"}})
    Connection.subscribe(name, self(), "page-1")
    Connection.subscribe(name, self(), "frame-1")
    Connection.handle_playwright_msg(name, %{guid: "page-1", method: :__dispose__, params: %{}})

    assert_receive {:playwright_msg, %{guid: "page-1", method: :__dispose__}}
    assert_receive {:playwright_msg, %{guid: "frame-1", method: :__dispose__}}
    assert_raise ArgumentError, ~r/unknown or disposed/, fn -> Connection.initializer!(name, "frame-1") end
    assert Process.alive?(Process.whereis(name))
  end

  test "console and page errors are logged and still delivered to subscribers" do
    name = start_connection!(:dummy, TestJsLogger)
    Connection.subscribe(name, self(), "context-1")

    console = %{
      guid: "context-1",
      method: :console,
      params: %{type: "error", text: "console boom", test_pid: self()}
    }

    Connection.handle_playwright_msg(name, console)
    assert_receive {:js_log, :error, "console boom"}
    assert_receive {:playwright_msg, ^console}

    page_error = %{
      guid: "context-1",
      method: :page_error,
      params: %{error: %{error: %{name: "Error", message: "page boom"}}, test_pid: self()}
    }

    Connection.handle_playwright_msg(name, page_error)
    assert_receive {:js_log, :error, "page boom"}
    assert_receive {:playwright_msg, ^page_error}
  end

  defp start_connection!(transport_name \\ :dummy, js_logger \\ nil) do
    name = start_uninitialized_connection!(transport_name, js_logger)
    {:pending, data} = :sys.get_state(name)
    Connection.handle_playwright_msg(name, %{id: data.initialization.id, result: %{}})

    Connection.handle_playwright_msg(name, %{
      guid: "",
      method: :__create__,
      params: %{type: "Playwright", guid: "Playwright", initializer: %{}}
    })

    assert_eventually(fn -> match?({:started, _}, :sys.get_state(name)) end)
    name
  end

  defp start_uninitialized_connection!(transport_name, js_logger \\ nil) do
    name = String.to_atom("connection_test_#{System.unique_integer([:positive])}")
    scope = String.to_atom("connection_test_scope_#{System.unique_integer([:positive])}")
    {:ok, _} = :pg.start_link(scope)

    opts = [
      name: name,
      timeout: 1_000,
      transport: {DummyTransport, transport_name},
      js_logger: js_logger,
      pg_scope: scope
    ]

    start_supervised!(%{id: name, start: {Connection, :start_link, [opts]}, restart: :temporary})

    name
  end

  defp assert_eventually(fun, attempts \\ 20)
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
