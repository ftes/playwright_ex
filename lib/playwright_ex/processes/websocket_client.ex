defmodule PlaywrightEx.WebSocketClient do
  @moduledoc """
  WebSocket-based transport for connecting to a remote Playwright server.

  Unlike `PlaywrightEx.PortServer` which spawns a local Node.js process via Erlang Port,
  this module connects to an existing Playwright server via WebSocket.

  This is useful for:
  - Alpine Linux containers (glibc issues with local Playwright driver)
  - Containerized CI environments with a separate Playwright server
  - Connecting to remote/shared Playwright instances

  Message format: JSON (no binary framing - WebSocket handles framing)
  """
  @behaviour PlaywrightEx.Transport

  use WebSockex

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Serialization

  require Logger

  @name __MODULE__

  defstruct [:ws_endpoint]

  @doc """
  Start the WebSocket client and connect to the Playwright server.

  ## Options

  - `:ws_endpoint` - Required. The WebSocket URL to connect to (e.g., "ws://localhost:3000/ws")
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:ws_endpoint])
    ws_endpoint = Keyword.fetch!(opts, :ws_endpoint)

    WebSockex.start_link(ws_endpoint, __MODULE__, %__MODULE__{ws_endpoint: ws_endpoint}, name: @name)
  end

  @doc """
  Post a message to the Playwright server via WebSocket.
  """
  @impl PlaywrightEx.Transport
  def post(msg) do
    frame = to_json(msg)
    WebSockex.send_frame(@name, {:text, frame})
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.debug("PlaywrightEx.WebSocketClient connected to #{state.ws_endpoint}")
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, frame}, state) do
    frame
    |> from_json()
    |> Connection.handle_playwright_msg()

    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:binary, _data}, state) do
    # Playwright server sends text frames, not binary
    Logger.warning("PlaywrightEx.WebSocketClient received unexpected binary frame")
    {:ok, state}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.error("PlaywrightEx.WebSocketClient disconnected: #{inspect(reason)}")
    {:reconnect, state}
  end

  @impl WebSockex
  def terminate(reason, _state) do
    Logger.debug("PlaywrightEx.WebSocketClient terminating: #{inspect(reason)}")
    :ok
  end

  # JSON Serialization (same as PortServer)

  defp to_json(msg) do
    msg
    |> Map.update(:method, nil, &Serialization.camelize/1)
    |> Serialization.deep_key_camelize()
    |> JSON.encode!()
  end

  defp from_json(frame) do
    frame
    |> JSON.decode!()
    |> Serialization.deep_key_underscore()
    |> Map.update(:method, nil, &Serialization.underscore/1)
  end
end
