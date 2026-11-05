defmodule Mix.Tasks.PlaywrightEx.Install do
  @shortdoc "Installs the Playwright driver (Node + playwright-core) and browsers"
  @moduledoc """
  Usage: `mix playwright_ex.install [--no-browsers] [--force] [-- BROWSER_ARGS...]`

  Browser args are forwarded to `playwright install` (none: its default browsers, as
  `npx playwright install`), e.g. `mix playwright_ex.install -- chromium firefox --with-deps`.
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
      :ok = PlaywrightEx.Driver.install_browsers(browser_args)
    end
  end
end
