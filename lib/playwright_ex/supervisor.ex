defmodule PlaywrightEx.Supervisor do
  @moduledoc """
  Playwright connection supervision tree.
  """

  use Supervisor

  def connection_name(supervisor_name \\ __MODULE__) do
    Module.concat(supervisor_name, "Connection")
  end

  def port_server_name(supervisor_name \\ __MODULE__) do
    Module.concat(supervisor_name, "PortServer")
  end

  def start_link(opts \\ []) do
    opts =
      opts
      |> Keyword.validate!([
        :timeout,
        :fail_on_unknown_opts,
        executable: "playwright",
        js_logger: nil,
        name: __MODULE__
      ])
      |> validate_executable!()

    Supervisor.start_link(__MODULE__, Map.new(opts), name: opts[:name])
  end

  @impl true
  def init(%{timeout: timeout, executable: executable, js_logger: js_logger, name: name}) do
    connection_name = connection_name(name)
    port_server_name = port_server_name(name)

    children = [
      {PlaywrightEx.PortServer, executable: executable, name: port_server_name, connection_name: connection_name},
      {PlaywrightEx.Connection,
       [
         [
           name: connection_name,
           timeout: timeout,
           js_logger: js_logger,
           port_server_name: port_server_name
         ]
       ]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
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
