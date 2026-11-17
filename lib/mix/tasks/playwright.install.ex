defmodule Mix.Tasks.Playwright.Install do
  @shortdoc "Installs the Playwright driver (Node + playwright-core) and browsers"
  @moduledoc """
  Usage: `mix playwright.install [BROWSER...] [OPTIONS...]`

  Installs the driver, then runs its `playwright install` with the args, as
  `npx playwright install` would (none: its default browsers), e.g.
  `mix playwright.install chromium firefox --with-deps`. Two flags are the task's own, in any
  position:

    * `--no-browsers` - installs only the driver, for a browser launched with `:executable_path`
      or `:channel`. It takes no other args.
    * `--force` - reinstalls the driver, and is forwarded: `playwright install --force` reinstalls
      the browsers.

  Every other arg is forwarded in order. Args after a `--` are forwarded as they are, without
  looking for the task's flags; the first `--` itself is dropped.

  The task doesn't see the options of `Playwright.Supervisor`; it reads their defaults,
  `config :playwright, :driver` (see `Playwright.Driver`). It doesn't compile the project, so it
  sees `config/config.exs` and the files it imports, not `config/runtime.exs`:

    * `:cache_dir` - where the driver is installed.
    * `:executable`, `:node` - the CLI, or the Node binary, that installs the browsers. The pinned
      driver is downloaded all the same.

  `HTTPS_PROXY` and `HTTP_PROXY` set the proxy for the driver download.

  The Playwright CLI reads its own: `PLAYWRIGHT_BROWSERS_PATH` (where browsers go),
  `PLAYWRIGHT_DOWNLOAD_HOST`, `HTTPS_PROXY`, ...
  """
  use Mix.Task

  @impl true
  def run(argv) do
    {opts, browser_args} = parse_args(argv)
    # Mix prunes the code paths of OTP apps that no compiled app lists, so before the project is
    # compiled `:public_key` (needed by `:ssl`) can be missing. `Driver.download!` starts them.
    Enum.each([:inets, :ssl], &Mix.ensure_application!/1)

    :ok = Playwright.Driver.install(force: opts[:force])
    Mix.shell().info("Driver installed in #{Playwright.Driver.install_dir()}")

    if opts[:browsers] do
      case Playwright.Driver.install_browsers(browser_args) do
        :ok -> :ok
        {:error, {:exit_status, status}} -> Mix.raise("playwright install failed with exit status #{status}")
      end
    end
  end

  @doc false
  # Splits argv into the task's flags and the args for `playwright install`.
  def parse_args(argv) do
    {own, verbatim} =
      case Enum.split_while(argv, &(&1 != "--")) do
        {own, ["--" | rest]} -> {own, rest}
        {own, []} -> {own, []}
      end

    browsers? = "--no-browsers" not in own
    others = Enum.reject(own, &(&1 in ["--no-browsers", "--force"])) ++ verbatim

    if not browsers? and others != [] do
      Mix.raise("--no-browsers installs only the driver, so it takes no browser args, got: #{Enum.join(others, " ")}")
    end

    browser_args = Enum.reject(own, &(&1 == "--no-browsers")) ++ verbatim
    {[browsers: browsers?, force: "--force" in own], browser_args}
  end
end
