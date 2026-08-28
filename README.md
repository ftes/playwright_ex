[![Hex.pm Version](https://img.shields.io/hexpm/v/playwright_ex)](https://hex.pm/packages/playwright_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/playwright_ex/)
[![License](https://img.shields.io/hexpm/l/playwright_ex.svg)](https://github.com/ftes/playwright_ex/blob/main/LICENSE.md)
[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/ftes/playwright_ex/elixir.yml)](https://github.com/ftes/playwright_ex/actions)

# PlaywrightEx

Elixir client for the Playwright node.js server.

Automate browsers like Chromium, Firefox, Safari and Edge.
Helpful for web scraping and agentic AI.

Please [get in touch](https://ftes.de) with feedback of any shape and size.

Enjoy!

Freddy.

## Getting started
1. Add dependency
        # mix.exs
        {:playwright_ex, "~> 0.6"}

2. Ensure `playwright` is installed (executable in `$PATH` or installed via `npm`)

3. Start connection (or add to supervision tree)
        # if installed via npm or similar add `executable: "assets/node_modules/playwright/cli.js"`
        {:ok, _} = PlaywrightEx.Supervisor.start_link(timeout: 1000)

4. Use it
        alias PlaywrightEx.{Browser, BrowserContext, Frame}

        {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: 1000)
        {:ok, context} = Browser.new_context(browser.guid, timeout: 1000)

        {:ok, %{main_frame: frame}} = BrowserContext.new_page(context.guid, timeout: 1000)
        {:ok, _} = Frame.goto(frame.guid, "https://elixir-lang.org/", timeout: 1000)
        {:ok, _} = Frame.click(frame.guid, Selector.link("Install"), timeout: 1000)

## Alternative Launch Methods

Launch with a persistent context:
Instead of a standard browser, you can launch a persistent context which retains cookies and local storage across sessions using a specified user data directory.

        {:ok, context} = PlaywrightEx.launch_persistent_context(:chromium,
          user_data_dir: "/path/to/user/data",
          timeout: 1000
        )

        {:ok, page} = PlaywrightEx.BrowserContext.new_page(context.guid, timeout: 1000)
        {:ok, _} = PlaywrightEx.Frame.goto(page.main_frame.guid, "https://elixir-lang.org/", timeout: 1000)

Connect to an existing browser via CDP:
If you have a browser already running with remote debugging enabled, you can connect to it directly via the Chrome DevTools Protocol (CDP).

        {:ok, browser} = PlaywrightEx.connect_over_cdp(:chromium,
          endpoint_url: "ws://localhost:9222",
          timeout: 1000
        )

## Remove server via Websocket
By default, PlaywrightEx launches a local playwright driver.
This is typically installed via `npm` or `bun`.

Alternatively, PlaywrightEx can connect to a remote playwright server:

      # mix.exs
      {:websockex, "~> 0.4"}

  ```
  docker run -p 3000:3000 --rm --init -it \\
    mcr.microsoft.com/playwright:v1.58.0-noble \\
    npx -y playwright@1.58.0 run-server --port 3000 --host 0.0.0.0
  ```

      {:ok, _} = PlaywrightEx.Supervisor.start_link(
        timeout: 1000,
        ws_endpoint: "ws://localhost:3000?browser=chromium"
      )

## API Layers
Most channel functions are thin protocol wrappers.
In ExDoc, composed helpers are grouped under `Client-Composed Functions`.

## References
- Code extracted from [phoenix_test_playwright](https://hexdocs.pm/phoenix_test_playwright).
- Inspired by [playwright-elixir](https://hexdocs.pm/playwright).
- Official playwright node.js [client docs](https://playwright.dev/docs/intro).

## Comparison to playwright-elixir
`playwright-elixir` built on the python client and tried to provide a comprehensive client from the start.
`playwright_ex` instead is a ground-up implementation. It is not intended to be comprehensive. Rather, it is intended to be simple and easy to extend.

## Contributing

To run the tests locally, you'll need to:

1. Check out the repo
2. Run `mix setup`. This will take care of setting up your dependencies, installing the JavaScript dependencies (including Playwright), and compiling the assets.
3. Run `mix test` or, for a more thorough check that matches what we test in CI, run `mix check`.
4. Run `mix test.websocket` to run all tests against a 'remote' playwright server via websocket. Docker needs to be installed. A container is started via `testcontainers`.
