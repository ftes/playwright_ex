defmodule Playwright do
  @moduledoc """
  upstream: Playwright.cs (entry point). `CreateAsync` wires StdIOTransport <-> Connection; here the
  Connection GenServer owns the transport process, so this only starts it and initializes.
  """
  alias Playwright.Transport.Connection

  # upstream: Playwright.cs:40
  def create_async(opts \\ []) do
    driver_cli = Keyword.get(opts, :driver_cli, Path.expand("../node_modules/playwright/cli.js", File.cwd!()))
    {:ok, pid} = Connection.start_link(driver_cli: driver_cli)
    connection = Connection.handle(pid)
    Connection.initialize_playwright(connection)
  end
end
