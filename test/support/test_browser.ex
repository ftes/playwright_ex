defmodule PlaywrightEx.TestBrowser do
  @moduledoc "The browser under test: `BROWSER` env (`chromium`, `firefox` or `webkit`), default `chromium`."
  alias PlaywrightEx.Playwright

  def name, do: System.get_env("BROWSER", "chromium")

  def browser_type(playwright), do: browser_type(playwright, name())

  defp browser_type(playwright, "chromium"), do: Playwright.chromium(playwright)
  defp browser_type(playwright, "firefox"), do: Playwright.firefox(playwright)
  defp browser_type(playwright, "webkit"), do: Playwright.webkit(playwright)
end
