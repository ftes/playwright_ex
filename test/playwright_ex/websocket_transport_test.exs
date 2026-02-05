defmodule PlaywrightEx.WebsocketTransportTest do
  @moduledoc """
  Tests that verify WebSocket transport works correctly.

  These tests use a Playwright Docker container started via testcontainers.
  """

  use WebsocketTransportCase, async: false

  alias PlaywrightEx.Frame

  describe "websocket transport" do
    test "can navigate and get page title", %{frame: frame, connection: connection} do
      {:ok, _} = Frame.goto(frame.guid, url: "https://example.com", timeout: @timeout, connection: connection)
      {:ok, title} = Frame.title(frame.guid, timeout: @timeout, connection: connection)

      assert title =~ "Example Domain"
    end

    test "can evaluate javascript", %{frame: frame, connection: connection} do
      {:ok, result} =
        Frame.evaluate(frame.guid,
          expression: "1 + 2",
          timeout: @timeout,
          connection: connection
        )

      assert result == 3
    end
  end
end
