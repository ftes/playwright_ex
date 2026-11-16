defmodule Mix.Tasks.Playwright.Cli do
  @shortdoc "Runs the Playwright CLI (show-trace, install --with-deps, codegen, ...)"
  @moduledoc """
  Usage: `mix playwright.cli ARGS...`

  Forwards `ARGS` to the driver's `playwright` CLI, like `python -m playwright ARGS` and Java's
  `CLI`, e.g. `mix playwright.cli show-trace trace.zip` or
  `mix playwright.cli install --with-deps chromium`. Installs the driver first if needed, as
  `config :playwright, :driver` sets (see `mix playwright.install`).
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Application.ensure_all_started([:inets, :ssl, :crypto])
    {program, prefix} = Playwright.Driver.ensure_installed()

    case System.cmd(program, prefix ++ argv,
           env: Playwright.Driver.driver_env(),
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, status} -> exit({:shutdown, status})
    end
  end
end
