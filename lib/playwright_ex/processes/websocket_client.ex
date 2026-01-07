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
  @max_retries 30
  @retry_interval 1_000

  defstruct [:ws_endpoint]

  @doc """
  Start the WebSocket client and connect to the Playwright server.

  Blocks until connected or max retries exhausted. This ensures the supervisor
  doesn't proceed to start dependent services until the connection is ready.

  ## Options

  - `:ws_endpoint` - Required. The WebSocket URL to connect to (e.g., "ws://localhost:3000/ws")
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:ws_endpoint])
    ws_endpoint = Keyword.fetch!(opts, :ws_endpoint)

    Logger.debug("PlaywrightEx.WebSocketClient connecting to: #{ws_endpoint}")
    connect_with_retry(ws_endpoint, 0)
  end

  defp connect_with_retry(ws_endpoint, retries) do
    case WebSockex.start_link(ws_endpoint, __MODULE__, %__MODULE__{ws_endpoint: ws_endpoint}, name: @name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, %WebSockex.ConnError{} = error} when retries < @max_retries ->
        Logger.warning(
          "PlaywrightEx.WebSocketClient connection failed (attempt #{retries + 1}/#{@max_retries}): #{inspect(error)}. Retrying in #{@retry_interval}ms..."
        )

        Process.sleep(@retry_interval)
        connect_with_retry(ws_endpoint, retries + 1)

      {:error, error} ->
        Logger.error(
          "PlaywrightEx.WebSocketClient failed to connect to #{ws_endpoint} after #{retries + 1} attempts: #{inspect(error)}"
        )

        {:error, error}
    end
  end

  @doc """
  Post a message to the Playwright server via WebSocket.
  """
  @impl PlaywrightEx.Transport
  def post(msg) do
    frame = to_json(msg)
    Logger.debug("PlaywrightEx.WebSocketClient sending: #{String.slice(frame, 0, 200)}...")
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
    Logger.debug("PlaywrightEx.WebSocketClient received: #{String.slice(frame, 0, 200)}...")

    msg = from_json(frame)

    Connection.handle_playwright_msg(msg)

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
