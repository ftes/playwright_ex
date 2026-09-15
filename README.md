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

2. Ensure Playwright 1.63 or newer is installed (executable in `$PATH` or installed via `npm`)

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

## Remote server via WebSocket
By default, PlaywrightEx launches a local playwright driver.
This is typically installed via `npm` or `bun`.

Alternatively, PlaywrightEx can connect to a remote playwright server:

      # mix.exs
      {:websockex, "~> 0.4"}

  ```
  docker run -p 3000:3000 --rm --init -it \\
    mcr.microsoft.com/playwright:v1.63.0-noble \\
    npx -y playwright@1.63.0 run-server --port 3000 --host 0.0.0.0
  ```

      {:ok, _} = PlaywrightEx.Supervisor.start_link(
        timeout: 1000,
        ws_endpoint: "ws://localhost:3000?browser=chromium"
      )

## API Layers
Most channel functions are thin protocol wrappers.
In ExDoc, composed helpers are grouped under `Client-Composed Functions`.

## Timeouts

Pass a `:timeout` for each operation: a positive number of milliseconds,
`0` for no waiting, or `:infinity` to disable the timeout.

With `0`, browser commands time out without being sent. Frame URL/load-state
waits check the current recorded state once.

## Downloads

Arm the listener, trigger the download, then await its event. Use `after` to
release the listener if the action fails:

```elixir
alias PlaywrightEx.{Download, EventWaiter, Frame, Page}

{:ok, pending} = Page.expect_download(page.guid, timeout: 1_000)

try do
  {:ok, _} = Frame.click(frame.guid, selector: "a#export", timeout: 1_000)
  {:ok, download} = Page.await_download(pending)

  download.suggested_filename # e.g. "report.csv"
  download.url
  :ok = Download.save_as(download, "downloads/report.csv", timeout: 5_000)
after
  EventWaiter.cancel(pending)
end
```

The event means the download has **started**. `Download.save_as/3` waits for
completion, works locally and over WebSocket, and preserves the source artifact.
It creates parent directories and preserves an existing destination if saving fails.
You own saved files. The browser deletes its source artifacts when the context
closes; use `Download.delete/2` to delete a source earlier.

Event capture, the triggering action, and saving each have their own timeout.
The event timeout starts when arming begins and is not restarted by awaiting
later or skipping events. The save timeout covers the whole transfer.

Use an optional predicate when an action produces several downloads, or to
select a filename or URL among unrelated downloads:

```elixir
{:ok, pending} = Page.expect_download(page.guid,
  timeout: 1_000,
  predicate: &(&1.suggested_filename == "report.csv")
)
```

The predicate receives a `Download`. Keep it quick and nonblocking; exceptions
propagate to the calling process.

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
