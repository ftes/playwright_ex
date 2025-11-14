defmodule PlaywrightEx do
  @moduledoc """
  Elixir client for the Playwright node.js server.

  Automate browsers like Chromium, Firefox, Safari and Edge.
  Helpful for web scraping and agentic AI.

  > #### Experimental {: .warning}
  >
  > This is an early stage, experimental, version.
  > The API is subject to change.
  > Not ready for production use.

  ## Getting started
  1. Add dependency
          # mix.exs
          {:phoenix_test_playwright, "~> 0.4"}

  2. Install playwright and browser
          npm --prefix assets i -D playwright
          npm --prefix assets exec -- playwright install chromium --with-deps

  3. Start connection (or add to supervision tree)
          {:ok, _} = PlaywrightEx.Connection.start_link()

  4. Use it
          browser_id = PlaywrightEx.launch_browser(:chromium)
          on_exit(fn -> Browser.close(browser_id) end)
          {:ok, context_id} = Browser.new_context(browser_id)

          {:ok, page_id} = BrowserContext.new_page(context_id)
          frame_id = PlaywrightEx.initializer(page_id).main_frame.guid
          {:ok, _} = Frame.goto(frame_id, "https://elixir-lang.org/")
          {:ok, _} = Frame.click(frame_id, Selector.link("Install"))


  ## References:
  - Code extracted from [phoenix_test_playwright](https://hexdocs.pm/phoenix_test_playwright).
  - Inspired by [playwright-elixir](https://hexdocs.pm/playwright).
  - Official playwright node.js [client docs](https://playwright.dev/docs/intro).


  ## Comparison to playwright-elixir
  `playwright-elixir` built on the python client and tried to provide a comprehensive client from the start.
  `playwright_ex` instead is a ground-up implementation. It is not intended to be comprehensive. Rather, it is intended to be simple and easy to extend.
  """
  alias PlaywrightEx.Connection

  @type browser_type :: atom()
  @type launch_browser_opts :: Keyword.t()
  @type guid :: String.t()
  @type msg :: map()

  @spec launch_browser(browser_type()) :: guid()
  @spec launch_browser(browser_type(), launch_browser_opts()) :: guid()
  defdelegate launch_browser(type, opts \\ []), to: Connection

  @spec subscribe(guid()) :: :ok
  @spec subscribe(pid(), guid()) :: :ok
  defdelegate subscribe(pid \\ self(), guid), to: Connection

  @spec post(msg()) :: msg()
  @spec post(msg(), timeout()) :: msg()
  defdelegate post(msg, timeout \\ nil), to: Connection

  @spec initializer(guid()) :: map()
  defdelegate initializer(guid), to: Connection
end
