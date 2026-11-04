defmodule Playwright.Impl.Driver do
  @moduledoc """
  Stand-in for com.microsoft.playwright.impl.driver.Driver (not counted): locates node + the driver cli.js.
  Set PLAYWRIGHT_CLI to override the default `prototypes/node_modules/playwright/cli.js`.
  """
  defstruct [:node, :cli, :env]

  def ensure_driver_installed(env, _install_browsers) do
    cli =
      System.get_env("PLAYWRIGHT_CLI") ||
        Path.expand("../../../../node_modules/playwright/cli.js", __DIR__)

    %__MODULE__{node: System.find_executable("node"), cli: cli, env: env}
  end

  def create_process_builder(%__MODULE__{} = driver), do: [driver.node, driver.cli]
end
