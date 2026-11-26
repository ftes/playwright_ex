defmodule Mix.Tasks.Playwright.Install do
  @shortdoc "Installs the Playwright driver and browsers"
  @moduledoc """
  Usage: `mix playwright.install [ARGS...]` (browsers and flags, in any order)

  Installs the driver, then runs its `playwright install` with the args, as
  `npx playwright install` would (none: its default browsers), e.g.
  `mix playwright.install chromium firefox --with-deps`. Two flags, in any position, are the
  task's own:

    * `--no-browsers` - installs only the driver (nothing with `:executable`), for a browser
      launched with `:executable_path` or `:channel`. It takes no other args but `--force`.
    * `--force` - reinstalls the driver (none with `:executable`), and is forwarded, so it
      reinstalls the browsers too. To reinstall only a browser, run
      `mix playwright.cli install --force <browser>`.

  Every other arg is forwarded in order.

  The task doesn't see the options of `Playwright.Supervisor`; it reads their defaults,
  `config :playwright, :driver` (see `Playwright.Driver`). It doesn't compile the project, so it
  sees `config/config.exs` and the files it imports, not `config/runtime.exs`:

    * `:cache_dir` - where the driver is installed.
    * `:executable` - the CLI that installs the browsers. Nothing is downloaded.
    * `:node` - the Node binary that runs the driver and installs the browsers. Only
      `playwright-core` is downloaded.

  `HTTPS_PROXY` (else `https_proxy`) sets the proxy for the driver download.

  The Playwright CLI reads its own: `PLAYWRIGHT_BROWSERS_PATH` (where browsers go),
  `PLAYWRIGHT_DOWNLOAD_HOST`, `HTTPS_PROXY`, ...
  """
  use Mix.Task

  @impl true
  def run(argv) do
    {browsers?, force?, browser_args} = parse_args(argv)
    # Mix prunes the code paths of OTP apps that no compiled app lists, so before the project is
    # compiled `:public_key` (needed by `:ssl`) can be missing. `Driver.download!` starts them.
    Enum.each([:inets, :ssl], &Mix.ensure_application!/1)

    :ok = Playwright.Driver.install(force: force?)

    case Playwright.Driver.executable() do
      {cli, []} -> Mix.shell().info("No driver to install: config :playwright, :driver sets executable: #{cli}")
      {_node, [_cli_js]} -> Mix.shell().info("Driver installed in #{Playwright.Driver.install_dir()}")
    end

    if browsers? do
      try do
        Playwright.Driver.install_browsers(browser_args)
      rescue
        error in RuntimeError -> Mix.raise(Exception.message(error))
      end
    end
  end

  @own_flags ["--no-browsers", "--force"]

  @doc false
  # Splits argv into the task's flags and the args for `playwright install`:
  # `{browsers?, force?, args}`.
  def parse_args(argv) do
    {own, others} = Enum.split_with(argv, &(&1 in @own_flags))

    cond do
      "--no-browsers" not in own ->
        {true, "--force" in own, argv}

      others == [] ->
        {false, "--force" in own, []}

      true ->
        Mix.raise(
          "mix playwright.install: --no-browsers installs only the driver, so it takes no other args, " <>
            "got: #{Enum.join(others, " ")}"
        )
    end
  end
end
