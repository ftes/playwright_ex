defmodule Mix.Tasks.Playwright.Install do
  @shortdoc "Installs the Playwright driver (Node + playwright-core) and browsers"
  @moduledoc """
  Usage: `mix playwright.install [--no-browsers] [--force] [-- BROWSER_ARGS...]`

  Browser args are forwarded to `playwright install` (none: its default browsers, as
  `npx playwright install`), e.g. `mix playwright.install -- chromium firefox --with-deps`.
  `--no-browsers` installs only the driver, for a browser launched with `:executable_path` or
  `:channel`.

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
    {own, browser_args} =
      case Enum.split_while(argv, &(&1 != "--")) do
        {own, ["--" | rest]} -> {own, rest}
        {own, []} -> {own, []}
      end

    {opts, _} = OptionParser.parse!(own, strict: [browsers: :boolean, force: :boolean])
    Application.ensure_all_started([:inets, :ssl, :crypto])

    :ok = Playwright.Driver.install(force: Keyword.get(opts, :force, false))
    Mix.shell().info("Driver installed in #{Playwright.Driver.install_dir()}")

    if Keyword.get(opts, :browsers, true) do
      case Playwright.Driver.install_browsers(browser_args) do
        :ok -> :ok
        {:error, {:exit_status, status}} -> Mix.raise("playwright install failed with exit status #{status}")
      end
    end
  end
end
