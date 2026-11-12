defmodule PlaywrightEx.TestBrowser do
  @moduledoc "The browser under test: `BROWSER` env (`chromium`, `firefox` or `webkit`), default `chromium`."
  alias PlaywrightEx.Driver
  alias PlaywrightEx.Playwright

  def name, do: System.get_env("BROWSER", "chromium")

  @doc """
  The executable `name` of the driver's own registry
  (`registry.findExecutable(name).executablePath()`), or `nil` when it isn't installed.
  """
  def registry_executable(name) do
    with {node, [cli]} <- Driver.executable(),
         core_bundle = Path.join([Path.dirname(cli), "lib", "coreBundle.js"]),
         true <- File.regular?(node) and File.regular?(core_bundle),
         script =
           "process.stdout.write(require(process.argv[1]).registry.registry.findExecutable(process.argv[2])?.executablePath() || '')",
         {path, 0} <- System.cmd(node, ["-e", script, core_bundle, name]),
         true <- path != "" and File.regular?(path) do
      path
    else
      _ -> nil
    end
  end

  @doc """
  Playwright Test's `headless` option (upstream runs headed with `--headed`): `HEADED=1` runs the
  browsers headed (Linux needs a display, e.g. `xvfb-run`), default headless.
  """
  def headless, do: System.get_env("HEADED", "") in ["", "0", "false"]

  def browser_type(playwright), do: browser_type(playwright, name())

  defp browser_type(playwright, "chromium"), do: Playwright.chromium(playwright)
  defp browser_type(playwright, "firefox"), do: Playwright.firefox(playwright)
  defp browser_type(playwright, "webkit"), do: Playwright.webkit(playwright)
end
