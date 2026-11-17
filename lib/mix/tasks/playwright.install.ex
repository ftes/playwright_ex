defmodule Mix.Tasks.Playwright.Install do
  @shortdoc "Installs the Playwright driver (Node + playwright-core) and browsers"
  @moduledoc """
  Usage: `mix playwright.install [BROWSER...] [OPTIONS...]`

  Installs the driver, then runs its `playwright install` with the args, as
  `npx playwright install` would (none: its default browsers), e.g.
  `mix playwright.install chromium firefox --with-deps`. Two flags, in any position, are the
  task's own:

    * `--no-browsers` - installs only the driver, for a browser launched with `:executable_path`
      or `:channel`. It takes no other args but `--force`.
    * `--force` - reinstalls the driver (unless `--dry-run`, `--list` or `--help` asks
      `playwright install` to install nothing), and is forwarded, so it reinstalls the browsers
      too.

  Every other arg is forwarded in order. A `--` raises: the args need none.

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
    {browsers?, force?, browser_args} = parse_args(argv)
    # Mix prunes the code paths of OTP apps that no compiled app lists, so before the project is
    # compiled `:public_key` (needed by `:ssl`) can be missing. `Driver.download!` starts them.
    Enum.each([:inets, :ssl], &Mix.ensure_application!/1)

    :ok = Playwright.Driver.install(force: force?)
    Mix.shell().info("Driver installed in #{Playwright.Driver.install_dir()}")

    if browsers? do
      case Playwright.Driver.install_browsers(browser_args) do
        :ok -> :ok
        {:error, {:exit_status, status}} -> Mix.raise("playwright install failed with exit status #{status}")
      end
    end
  end

  @own_flags ["--no-browsers", "--force"]
  # The flags with which `playwright install` installs nothing. Mirrors `playwright install --help`
  # at the pinned driver: recheck on each bump (PORTING.md "Bumping the pinned version").
  @install_nothing ["--dry-run", "--list", "--help", "-h"]

  @doc false
  # Splits argv into the task's flags and the args for `playwright install`:
  # `{browsers?, force?, args}`.
  def parse_args(argv) do
    if "--" in argv, do: Mix.raise("`--` is no longer needed: `mix playwright.install chromium --with-deps`")

    {own, others} = Enum.split_with(argv, &(&1 in @own_flags))

    cond do
      "--no-browsers" not in own ->
        {true, "--force" in own and not Enum.any?(others, &(&1 in @install_nothing)), argv}

      others == [] ->
        {false, "--force" in own, []}

      true ->
        Mix.raise("--no-browsers installs only the driver, so it takes no other args, got: #{Enum.join(others, " ")}")
    end
  end
end
