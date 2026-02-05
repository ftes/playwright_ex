defmodule WebsocketTransportCase do
  @moduledoc """
  Test case for tests that use WebSocket transport to connect to a remote Playwright server.

  Uses testcontainers to automatically start a Playwright Docker container.
  Each test module gets its own container and supervisor instance.

  ## Usage

      defmodule MyWebsocketTest do
        use WebsocketTransportCase, async: false

        test "connects via websocket", %{browser: browser, page: page} do
          # Test using the WebSocket-connected browser
        end
      end

  Note: Tests using this case cannot be async since they share a container per module.
  """

  use ExUnit.CaseTemplate

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext

  # Use a longer timeout for websocket tests since container operations are slower
  @timeout 30_000
  @playwright_version "1.58.0"
  @playwright_image "mcr.microsoft.com/playwright:v#{@playwright_version}-noble"

  using(_opts) do
    quote do
      import WebsocketTransportCase

      @moduletag :websocket
      @timeout unquote(@timeout)
    end
  end

  setup_all do
    # Start testcontainers
    {:ok, _} = Testcontainers.start_link()

    # Create and start the Playwright container
    config =
      @playwright_image
      |> Testcontainers.Container.new()
      |> Testcontainers.Container.with_exposed_port(3000)
      |> Testcontainers.Container.with_cmd(
        ~w(npx -y playwright@#{@playwright_version} run-server --port 3000 --host 0.0.0.0)
      )
      |> Testcontainers.Container.with_waiting_strategy(Testcontainers.PortWaitStrategy.new("localhost", 3000, 30_000))

    {:ok, container} = Testcontainers.start_container(config)

    # Get the mapped port
    host_port = Testcontainers.Container.mapped_port(container, 3000)
    ws_endpoint = "ws://localhost:#{host_port}?browser=chromium"

    # Start a separate supervisor for WebSocket transport
    supervisor_name = Module.concat(__MODULE__, PlaywrightEx.Supervisor)

    {:ok, _supervisor} =
      PlaywrightEx.Supervisor.start_link(
        name: supervisor_name,
        ws_endpoint: ws_endpoint,
        timeout: @timeout
      )

    connection_name = PlaywrightEx.Supervisor.connection_name(supervisor_name)

    on_exit(fn ->
      # Stop supervisor if still running (ignore errors if already stopped)
      try do
        Supervisor.stop(supervisor_name)
      catch
        :exit, _ -> :ok
      end

      # Stop container if testcontainers is still running
      try do
        Testcontainers.stop_container(container.container_id)
      catch
        :exit, _ -> :ok
      end
    end)

    [
      container: container,
      ws_endpoint: ws_endpoint,
      supervisor_name: supervisor_name,
      connection: connection_name
    ]
  end

  setup %{connection: connection} do
    {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout, connection: connection)
    {:ok, browser_context} = Browser.new_context(browser.guid, timeout: @timeout, connection: connection)
    {:ok, page} = BrowserContext.new_page(browser_context.guid, timeout: @timeout, connection: connection)

    ExUnit.Callbacks.on_exit(fn ->
      Browser.close(browser.guid, timeout: @timeout, connection: connection)
    end)

    [browser: browser, browser_context: browser_context, page: page, frame: page.main_frame]
  end
end
