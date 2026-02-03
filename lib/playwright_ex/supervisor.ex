defmodule PlaywrightEx.Supervisor do
  @moduledoc """
  Playwright connection supervision tree.

  Supports two transport modes:
  - Local Port (default): Spawns Node.js playwright driver
  - WebSocket: Connects to remote Playwright server

  ## Options

  - `:ws_endpoint` - WebSocket URL (e.g., "ws://localhost:3000/ws").
    If provided, uses WebSocket transport. Otherwise uses local Port.
  - `:executable` - Path to playwright CLI (only for Port transport)
  - `:timeout` - Connection timeout
  - `:js_logger` - Module for logging JS console messages
  """

  use Supervisor

  alias PlaywrightEx.Connection
  alias PlaywrightEx.PortServer
  alias PlaywrightEx.WebSocketClient

  def start_link(opts \\ []) do
    opts =
      opts
      |> Keyword.drop(~w(tests)a)
      |> Keyword.validate!([:timeout, :ws_endpoint, :fail_on_unknown_opts, executable: "playwright", js_logger: nil])
      |> maybe_validate_executable!()

    Supervisor.start_link(__MODULE__, Map.new(opts), name: __MODULE__)
  end

  @impl true
  def init(config) do
    {transport_child, transport_module} = transport_child_spec(config)

    children = [
      transport_child,
      {Connection, [[timeout: config.timeout, js_logger: config.js_logger, transport: transport_module]]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp transport_child_spec(%{ws_endpoint: ws_endpoint}) when is_binary(ws_endpoint) do
    unless Code.ensure_loaded?(WebSockex) do
      raise """
      WebSocket transport requires the :websockex dependency.

      Add it to your mix.exs:

          {:websockex, "~> 0.4"}
      """
    end

    # WebSocket transport
    {{WebSocketClient, ws_endpoint: ws_endpoint}, WebSocketClient}
  end

  defp transport_child_spec(%{executable: executable}) do
    # Local Port transport (default)
    {{PortServer, executable: executable}, PortServer}
  end

  defp maybe_validate_executable!(opts) do
    if Keyword.has_key?(opts, :ws_endpoint) do
      # WebSocket mode - no executable needed
      opts
    else
      # Port mode - validate executable
      validate_executable!(opts)
    end
  end

  defp validate_executable!(opts) do
    error_msg = """
    Playwright executable not found.
    Ensure `playwright` executable is on `$PATH` or pass `executable` option
    'assets/node_modules/playwright/cli.js' or similar.
    """

    Keyword.update!(
      opts,
      :executable,
      &cond do
        path = System.find_executable(&1) -> path
        File.exists?(&1) -> &1
        true -> raise error_msg
      end
    )
  end
end
