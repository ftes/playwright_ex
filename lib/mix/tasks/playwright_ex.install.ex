defmodule Mix.Tasks.PlaywrightEx.Install do
  @shortdoc "Installs the Playwright driver (Node + playwright-core) and browsers"
  @moduledoc """
  Usage: `mix playwright_ex.install [--no-browsers] [--force] [-- BROWSER_ARGS...]`

  Browser args are forwarded to `playwright install` (none: its default browsers, as
  `npx playwright install`), e.g. `mix playwright_ex.install -- chromium firefox --with-deps`.
  `--no-browsers` installs only the driver, for a browser launched with `:executable_path` or
  `:channel`.

  The task doesn't see the options of `PlaywrightEx.Supervisor` (`:cache_dir`, `:executable`,
  `:node`); it reads the environment variables instead (see `PlaywrightEx.Driver`):

    * `PLAYWRIGHT_EX_CACHE_DIR` - where the driver is installed.
    * `PLAYWRIGHT_EX_EXECUTABLE`, `PLAYWRIGHT_NODEJS_PATH` - the CLI, or the Node binary, that
      installs the browsers. The pinned driver is downloaded all the same.
    * `HTTPS_PROXY`, `HTTP_PROXY` - the proxy for the driver download.

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

    :ok = PlaywrightEx.Driver.install(force: Keyword.get(opts, :force, false))
    Mix.shell().info("Driver installed in #{PlaywrightEx.Driver.install_dir()}")

    if Keyword.get(opts, :browsers, true) do
      case PlaywrightEx.Driver.install_browsers(browser_args) do
        :ok -> :ok
        {:error, {:exit_status, status}} -> Mix.raise("playwright install failed with exit status #{status}")
      end
    end
  end
end
