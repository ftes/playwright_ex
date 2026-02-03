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
  alias PlaywrightEx.PortTransport
  alias PlaywrightEx.WebSocketTransport

  def start_link(opts \\ []) do
    opts =
      opts
      |> Keyword.drop(~w(tests)a)
      |> Keyword.validate!([:timeout, :ws_endpoint, :fail_on_unknown_opts, executable: "playwright", js_logger: nil])

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
    {{WebSocketTransport, ws_endpoint: ws_endpoint}, WebSocketTransport}
  end

  defp transport_child_spec(%{executable: executable}) do
    executable = validate_executable!(executable)
    {{PortTransport, executable: executable}, PortTransport}
  end

  defp validate_executable!(executable) do
    cond do
      path = System.find_executable(executable) -> path
      File.exists?(executable) -> executable
      true ->
        raise """
        Playwright executable not found.
        Ensure `playwright` executable is on `$PATH` or pass `executable` option
        'assets/node_modules/playwright/cli.js' or similar.
        """
    end
  end
end
