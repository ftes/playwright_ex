defmodule Mix.Tasks.Playwright.Install do
  @shortdoc "Installs the Playwright driver (Node + playwright-core) and browsers"
  @moduledoc """
  Usage: `mix playwright.install [BROWSER...] [OPTIONS...]`

  Installs the driver, then runs its `playwright install` with the args, as
  `npx playwright install` would (none: its default browsers), e.g.
  `mix playwright.install chromium firefox --with-deps`. Two flags before any `--` are the
  task's own:

    * `--no-browsers` - installs only the driver, for a browser launched with `:executable_path`
      or `:channel`. It takes no other args.
    * `--force` - reinstalls the driver (unless `--dry-run`, `--list` or `--help` asks
      `playwright install` to install nothing), and is forwarded.

  Every other arg is forwarded in order, a `--` included, so upstream's flags after it are
  upstream's alone: `mix playwright.install --force chromium` reinstalls the driver and Chromium,
  `mix playwright.install -- --force chromium` only Chromium.

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

  @own_flags ["--no-browsers", "--force"]
  @install_nothing ["--dry-run", "--list", "--help", "-h"]

  @doc false
  # Splits argv into the task's flags (before any `--`) and the args for `playwright install`.
  def parse_args(argv) do
    {before, rest} = Enum.split_while(argv, &(&1 != "--"))
    {own, others} = Enum.split_with(before, &(&1 in @own_flags))
    force? = "--force" in own and not Enum.any?(others, &(&1 in @install_nothing))

    cond do
      "--no-browsers" not in own ->
        {[browsers: true, force: force?], argv}

      others ++ rest == [] ->
        {[browsers: false, force: force?], []}

      true ->
        Mix.raise(
          "--no-browsers installs only the driver, so it takes no browser args, got: #{Enum.join(others ++ rest, " ")}"
        )
    end
  end
end
