# upstream: playwright/_impl/_driver.py
defmodule Playwright.Impl.Driver do
  @cli Path.expand("../../../../node_modules/playwright/cli.js", __DIR__)

  # upstream: _driver.py:25
  def compute_driver_executable do
    cli_path = System.get_env("PLAYWRIGHT_CLI_PATH", @cli)
    {System.get_env("PLAYWRIGHT_NODEJS_PATH", System.find_executable("node")), cli_path}
  end

  # upstream: _driver.py:36
  def get_driver_env do
    env = %{}
    env = Map.put(env, "PW_LANG_NAME", "python")
    env = Map.put(env, "PW_LANG_NAME_VERSION", "elixir-#{System.version()}")
    env
  end
end
