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
          {:ok, _} = PlaywrightEx.Supervisor.start_link(timeout: 1000)

  4. Use it
          alias PlaywrightEx.{Browser, BrowserContext, Frame}

          {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: 1000)
          {:ok, context} = Browser.new_context(browser.guid, timeout: 1000)

          {:ok, %{main_frame: frame}} = BrowserContext.new_page(context.guid, timeout: 1000)
          {:ok, _} = Frame.goto(frame.guid, "https://elixir-lang.org/", timeout: 1000)
          {:ok, _} = Frame.click(frame.guid, Selector.link("Install"), timeout: 1000)


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

  @type guid :: String.t()
  @type unknown_opt :: {Keyword.key(), Keyword.value()}

  @doc """
  Launches a new browser instance.

  ## Options
  #{NimbleOptions.docs(BrowserType.launch_opts_schema())}
  """
  @spec launch_browser(atom(), [[BrowserType.launch_opt() | unknown_opt()]]) :: {:ok, %{guid: guid()}} | {:error, any()}
  def launch_browser(type, opts) do
    type_id = "Playwright" |> Connection.initializer!() |> Map.fetch!(type) |> Map.fetch!(:guid)
    BrowserType.launch(type_id, opts)
  end

  @doc """
  Subscribe to playwright responses concerning a resource, identified by its `guid`, or its descendants.
  Messages in the format `{:playwright_msg, %{} = msg}` will be sent to `pid`.
  """
  @spec subscribe(pid(), guid()) :: :ok
  defdelegate subscribe(pid \\ self(), guid), to: Connection

  @doc """
  Send message to playwright.

  Don't use this! Prefer `Channels` functions.
  If a function is missing, consider [opening a PR](https://github.com/ftes/playwright_ex/pulls) to add it.
  """
  @spec send(%{guid: guid(), method: atom()}, timeout()) :: %{result: map()} | %{error: map()}
  defdelegate send(msg, timeout), to: Connection
end
