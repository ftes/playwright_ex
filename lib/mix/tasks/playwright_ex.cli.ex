defmodule Mix.Tasks.PlaywrightEx.Cli do
  @shortdoc "Runs the Playwright CLI (show-trace, install --with-deps, codegen, ...)"
  @moduledoc """
  Usage: `mix playwright_ex.cli ARGS...`

  Forwards `ARGS` to the driver's `playwright` CLI, like `python -m playwright ARGS` and Java's
  `CLI`, e.g. `mix playwright_ex.cli show-trace trace.zip` or
  `mix playwright_ex.cli install --with-deps chromium`. Installs the driver first if needed.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Application.ensure_all_started([:inets, :ssl, :crypto])
    {program, prefix} = PlaywrightEx.Driver.ensure_installed()

    case System.cmd(program, prefix ++ argv,
           env: PlaywrightEx.Driver.driver_env(),
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, status} -> exit({:shutdown, status})
    end
  end
end
