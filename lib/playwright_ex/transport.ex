defmodule PlaywrightEx.Transport do
  @moduledoc """
  Behaviour for Playwright transport implementations.

  A transport is responsible for:
  - Establishing a connection to the Playwright server (local or remote)
  - Sending JSON-RPC style messages
  - Forwarding received messages to the Connection process

  Two implementations are provided:
  - `PlaywrightEx.PortTransport` - Local Node.js driver via Erlang Port
  - `PlaywrightEx.WebSocketTransport` - Remote server via WebSocket
  """

  @doc """
  Send a message to the Playwright server.
  The message will be JSON-encoded with camelCase keys.
  """
  @callback post(name :: GenServer.name(), msg :: map()) :: :ok
end
