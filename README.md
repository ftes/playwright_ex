[![Hex.pm Version](https://img.shields.io/hexpm/v/playwright_ex)](https://hex.pm/packages/playwright_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/playwright_ex/)
[![License](https://img.shields.io/hexpm/l/playwright_ex.svg)](https://github.com/ftes/playwright_ex/blob/main/LICENSE.md)
[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/ftes/playwright_ex/elixir.yml)](https://github.com/ftes/playwright_ex/actions)

# PlaywrightEx

Elixir client for [Playwright](https://playwright.dev). Automate Chromium, Firefox and WebKit:
end-to-end tests, web scraping, agentic AI.

PlaywrightEx is a 1:1 port of the official JavaScript client. Its API is generated from
Playwright's docs, so the docs at playwright.dev apply. The driver (Node.js and `playwright-core`)
is pinned and installed by Mix, no npm needed. This release drives Playwright 1.65.

## Installation

```elixir
def deps do
  [
    {:playwright_ex, "~> 0.17.0-rc.2"}
  ]
end
```

```sh
mix deps.get
mix playwright_ex.install
```

## Example

```elixir
alias PlaywrightEx.{Browser, BrowserType, Expect, Locator, Page, Playwright}

{:ok, _} = PlaywrightEx.Supervisor.start_link()
browser = BrowserType.launch!(Playwright.chromium(PlaywrightEx.playwright()))
page = Browser.new_page!(browser)
Page.goto!(page, "https://elixir-lang.org/")
Page.get_by_role(page, :link, name: "Install") |> Locator.click!()
Expect.to_have_title!(page, ~r/Install/)
```

## Reading playwright.dev

The [Python docs](https://playwright.dev/python/docs/intro) are the closest read, since the
names match Python's: snake_case, keyword options, `expect_popup`, `eval_on_selector`.
`page.get_by_role("button").click()` is `Page.get_by_role(page, :button) |> Locator.click!()`.

## Guides

- [Getting started](guides/introduction/getting-started.md): install, the driver, a first script.
- [From playwright.dev to Elixir](guides/introduction/api-conventions.md): how a JS call reads in
  Elixir.
- [Cheatsheet](guides/introduction/cheatsheet.cheatmd): frequent calls, JS next to Elixir.
- [Testing with ExUnit](guides/testing-with-exunit.md): a browser case template, assertions, failures.
- [Events and waiting](guides/events-and-waiting.md), [Network](guides/network.md),
  [Debugging and CI](guides/debugging-and-ci.md).
- [Concurrency](guides/concurrency.md): listeners, promises and processes.
- [Migrating from 0.16](guides/migration.md).

Feedback of any shape and size is welcome: [get in touch](https://ftes.de).

## Contributing

1. `mix setup` installs dependencies, the pinned Playwright driver and Chromium.
2. `mix test`, or `mix check` for everything CI runs.
3. Porting rules: [`PORTING.md`](https://github.com/ftes/playwright_ex/blob/main/PORTING.md); the why behind the design:
   [`docs/architecture.md`](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md).
