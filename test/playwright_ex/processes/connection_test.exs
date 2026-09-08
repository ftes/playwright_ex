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

    {:ok, _pid} =
      Connection.start_link(
        name: name,
        timeout: 1_000,
        transport: {DummyTransport, transport_name},
        js_logger: js_logger,
        pg_scope: scope
      )

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
