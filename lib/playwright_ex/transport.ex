defmodule PlaywrightEx.Transport do
  @moduledoc """
  Behaviour for Playwright transport implementations.

  A transport is responsible for:
  - Establishing a connection to the Playwright server (local or remote)
  - Sending JSON-RPC style messages
  - Forwarding received messages to the Connection process

  Two implementations are provided:
  - `PlaywrightEx.PortServer` - Local Node.js driver via Erlang Port
  - `PlaywrightEx.WebSocketClient` - Remote server via WebSocket
  """

  @doc """
  Send a message to the Playwright server.
  The message will be JSON-encoded with camelCase keys.
  """
  @callback post(msg :: map()) :: :ok
end
