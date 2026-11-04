defmodule PlaywrightEx do
  @moduledoc """
  Elixir client for Playwright, ported 1:1 from the official JavaScript client.

  Start a driver with `PlaywrightEx.Supervisor`, then get the root object:

      {:ok, _} = PlaywrightEx.Supervisor.start_link()
      playwright = PlaywrightEx.playwright()
      {:ok, browser} = PlaywrightEx.BrowserType.launch(PlaywrightEx.Playwright.chromium(playwright))
      :ok = PlaywrightEx.Browser.close(browser)

  The public API (`PlaywrightEx.Playwright`, `PlaywrightEx.BrowserType`, ...) is generated from
  upstream's docs by `mix playwright_ex.gen.api` and grows as `PlaywrightEx.Client.*` is ported.
  """

  @doc "The root `PlaywrightEx.Playwright` object of the driver started as `name`."
  @spec playwright(atom()) :: PlaywrightEx.Playwright.t()
  def playwright(name \\ __MODULE__),
    do: PlaywrightEx.OutOfProcess.playwright(PlaywrightEx.Supervisor.out_of_process(name))
end
