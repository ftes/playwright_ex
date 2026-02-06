defmodule Mix.Tasks.Test.Websocket do
  @shortdoc "Runs tests using a containerized Playwright server via websocket"
  @moduledoc """
  Runs the test suite against a Playwright server running in a Docker container,
  connected via websocket transport.

  All arguments are passed through to `mix test`.

  ## Usage

      mix test.websocket
      mix test.websocket --warnings-as-errors
      mix test.websocket test/specific_test.exs
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Enum.each([:tesla, :hackney, :fs, :logger], fn app ->
      {:ok, _} = Application.ensure_all_started(app)
    end)

    {:ok, _} = Testcontainers.start()

    playwright_version =
      "assets/package-lock.json"
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["packages", "node_modules/playwright", "version"])

    playwright_image = "mcr.microsoft.com/playwright:v#{playwright_version}-noble"

    container_config =
      playwright_image
      |> Testcontainers.Container.new()
      |> Testcontainers.Container.with_exposed_port(3000)
      |> Testcontainers.Container.with_cmd(
        ~w(npx -y playwright@#{playwright_version} run-server --port 3000 --host 0.0.0.0)
      )
      |> Testcontainers.Container.with_waiting_strategy(Testcontainers.PortWaitStrategy.new("localhost", 3000, 30_000))

    {:ok, container} = Testcontainers.start_container(container_config)

    host_port = Testcontainers.Container.mapped_port(container, 3000)
    ws_endpoint = "ws://localhost:#{host_port}?browser=chromium"

    Application.put_env(:playwright_ex, :ws_endpoint, ws_endpoint)

    Mix.Task.run("test", args)
  end
end
