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

  test "sends command timeouts in metadata" do
    name = start_connection!(self())

    assert_receive {:transport_post,
                    %{method: :initialize, params: %{sdk_language: :javascript}, metadata: %{timeout: 1_000}}}

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

  defp start_connection!(transport_name \\ :dummy) do
    name = String.to_atom("connection_test_#{System.unique_integer([:positive])}")
    scope = String.to_atom("connection_test_scope_#{System.unique_integer([:positive])}")
    {:ok, _} = :pg.start_link(scope)

    {:ok, _pid} =
      Connection.start_link(
        name: name,
        timeout: 1_000,
        transport: {DummyTransport, transport_name},
        js_logger: nil,
        pg_scope: scope
      )

    Connection.handle_playwright_msg(name, %{method: :__create__, params: %{guid: "Playwright", initializer: %{}}})

    assert_eventually(fn ->
      match?({:started, _}, :sys.get_state(name))
    end)

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
