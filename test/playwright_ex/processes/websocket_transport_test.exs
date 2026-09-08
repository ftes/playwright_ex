if Code.ensure_loaded?(WebSockex) do
  defmodule PlaywrightEx.WebSocketTransportTest do
    use ExUnit.Case, async: true

    alias PlaywrightEx.WebSocketTransport

    test "disconnect terminates the transport so rest_for_one rebuilds connection state" do
      state = %WebSocketTransport{ws_endpoint: "ws://localhost:3000", connection_name: :connection}

      assert {:ok, ^state} = WebSocketTransport.handle_disconnect(%{}, state)
    end
  end
end
