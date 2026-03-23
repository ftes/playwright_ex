defmodule PlaywrightEx.BrowserContextChannelTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.BrowserContext

  setup do
    {:ok, connection} = start_supervised({__MODULE__.FakeConnection, self()})
    [connection: connection]
  end

  describe "clock_install/2" do
    test "sends clock_install without a time by default", %{connection: connection} do
      assert {:ok, %{}} = BrowserContext.clock_install("context-guid", connection: connection, timeout: 123)

      assert_receive {:send,
                      %{
                        guid: "context-guid",
                        method: :clock_install,
                        metadata: %{},
                        params: %{timeout: 123}
                      }}
    end

    test "sends clock_install with an explicit integer time", %{connection: connection} do
      assert {:ok, %{}} = BrowserContext.clock_install("context-guid", time: 456, connection: connection, timeout: 123)

      assert_receive {:send,
                      %{
                        guid: "context-guid",
                        method: :clock_install,
                        metadata: %{},
                        params: %{time_number: 456, timeout: 123}
                      }}
    end
  end

  describe "clock_fast_forward/2" do
    test "sends clock_fast_forward with integer ticks", %{connection: connection} do
      assert {:ok, %{}} =
               BrowserContext.clock_fast_forward("context-guid", ticks: 60_001, connection: connection, timeout: 123)

      assert_receive {:send,
                      %{
                        guid: "context-guid",
                        method: :clock_fast_forward,
                        metadata: %{},
                        params: %{ticks_number: 60_001, timeout: 123}
                      }}
    end

    test "sends clock_fast_forward with string ticks", %{connection: connection} do
      assert {:ok, %{}} =
               BrowserContext.clock_fast_forward("context-guid", ticks: "01:00", connection: connection, timeout: 123)

      assert_receive {:send,
                      %{
                        guid: "context-guid",
                        method: :clock_fast_forward,
                        metadata: %{},
                        params: %{ticks_string: "01:00", timeout: 123}
                      }}
    end
  end

  defmodule FakeConnection do
    @moduledoc false
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid)
    end

    @impl GenServer
    def init(test_pid), do: {:ok, test_pid}

    @impl GenServer
    def handle_call({:send, msg}, _from, test_pid) do
      send(test_pid, {:send, msg})
      {:reply, %{result: %{}}, test_pid}
    end
  end
end
