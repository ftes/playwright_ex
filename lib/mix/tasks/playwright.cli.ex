defmodule Mix.Tasks.Playwright.Cli do
  @shortdoc "Runs the Playwright CLI (show-trace, install --with-deps, codegen, ...)"
  @moduledoc """
  Usage: `mix playwright.cli ARGS...`

  Forwards `ARGS` to the driver's `playwright` CLI as they are, like `npx playwright ARGS`,
  `python -m playwright ARGS` and Java's `CLI`, e.g. `mix playwright.cli show-trace trace.zip` or
  `mix playwright.cli install chromium --with-deps`.
  Installs the driver first if needed, as `config :playwright, :driver` sets (see
  `mix playwright.install`).
  """
  use Mix.Task

  @impl true
  def run(argv) do
    # Mix prunes the code paths of OTP apps that no compiled app lists, so before the project is
    # compiled `:public_key` (needed by `:ssl`) can be missing. `Driver.download!` starts them.
    Enum.each([:inets, :ssl], &Mix.ensure_application!/1)
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
