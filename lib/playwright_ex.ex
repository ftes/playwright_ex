defmodule PlaywrightEx do
  @moduledoc """
  Elixir client for the Playwright node.js server.

  Automate browsers like Chromium, Firefox, Safari and Edge.
  Helpful for web scraping and agentic AI.

  > #### Experimental {: .warning}
  >
  > This is an early stage, experimental, version.
  > The API is subject to change.

  ## Getting started
  1. Add dependency
          # mix.exs
          {:playwright_ex, "~> 0.1"}

  2. Install playwright and browser
          npm --prefix assets i -D playwright
          npm --prefix assets exec -- playwright install chromium --with-deps

  3. Start connection (or add to supervision tree)
          {:ok, _} = PlaywrightEx.Supervisor.start_link(timeout: timeout, runner: "npx", assets_dir: "assets")

  4. Use it
          {:ok, browser_id} = PlaywrightEx.launch_browser(:chromium, timeout: 1000)
          {:ok, context_id} = Browser.new_context(browser_id, timeout: 1000)

          {:ok, page_id} = BrowserContext.new_page(context_id, timeout: 1000)
          frame_id = PlaywrightEx.initializer(page_id).main_frame.guid
          {:ok, _} = Frame.goto(frame_id, "https://elixir-lang.org/", timeout: 1000)
          {:ok, _} = Frame.click(frame_id, Selector.link("Install"), timeout: 1000)


  ## References:
  - Code extracted from [phoenix_test_playwright](https://hexdocs.pm/phoenix_test_playwright).
  - Inspired by [playwright-elixir](https://hexdocs.pm/playwright).
  - Official playwright node.js [client docs](https://playwright.dev/docs/intro).


  ## Comparison to playwright-elixir
  `playwright-elixir` built on the python client and tried to provide a comprehensive client from the start.
  `playwright_ex` instead is a ground-up implementation. It is not intended to be comprehensive. Rather, it is intended to be simple and easy to extend.
  """

  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Connection

  @type browser_type :: atom()
  @type launch_browser_opts :: Keyword.t()
  @type guid :: String.t()
  @type msg :: map()

  @spec launch_browser(browser_type(), launch_browser_opts()) :: {:ok, guid()} | {:error, any()}
  def launch_browser(type, opts) do
    type_id = "Playwright" |> initializer!() |> Map.fetch!(type) |> Map.fetch!(:guid)
    BrowserType.launch(type_id, opts)
  end

  @spec subscribe(guid()) :: :ok
  @spec subscribe(pid(), guid()) :: :ok
  defdelegate subscribe(pid \\ self(), guid), to: Connection

  @spec post(msg(), timeout()) :: msg()
  defdelegate post(msg, timeout), to: Connection

  @spec initializer!(guid()) :: map()
  defdelegate initializer!(guid), to: Connection
end
