# Playwright

[![Hex.pm Version](https://img.shields.io/hexpm/v/playwright_ex)](https://hex.pm/packages/playwright_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/playwright_ex/)
[![License](https://img.shields.io/hexpm/l/playwright_ex.svg)](https://github.com/ftes/playwright_ex/blob/main/LICENSE)
[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/ftes/playwright_ex/elixir.yml)](https://github.com/ftes/playwright_ex/actions)

Elixir client for [Playwright](https://playwright.dev). Automate Chromium, Firefox and WebKit:
end-to-end tests, web scraping, agentic AI.

It is a 1:1 port of the official JavaScript client. Its API is generated from
Playwright's docs, so the docs at playwright.dev apply. The driver (Node.js and `playwright-core`)
is pinned and installed by Mix, no npm needed. This release drives Playwright 1.65.

## Installation

```elixir
def deps do
  [
    {:playwright, "~> 0.17.0-rc.6", hex: :playwright_ex}
  ]
end
```

The Hex package is `playwright_ex`, the app and modules are `playwright` and `Playwright`.
`hex: :playwright_ex` is required: `playwright` on Hex is another library.

```sh
mix deps.get
mix playwright.install
```

## Example

```elixir
alias Playwright.{Browser, BrowserType, Expect, Locator, Page}

{:ok, _} = Playwright.Supervisor.start_link()
browser = BrowserType.launch!(Playwright.chromium(Playwright.instance()))
page = Browser.new_page!(browser)
Page.goto!(page, "https://elixir-lang.org/")
Page.get_by_role(page, :link, name: "Install") |> Locator.click!()
Expect.to_have_title!(page, ~r/Install/)
# Closes the browser and waits for the driver to exit before the VM halts.
Supervisor.stop(Playwright)
```

**`timeout: 0` means no timeout.** As in Playwright JS, it waits forever instead of failing at
once. `:infinity` is the same and reads better in Elixir.

## Reading playwright.dev

The [Python docs](https://playwright.dev/python/docs/intro) are the closest read, since the
names match Python's: snake_case, keyword options, `expect_popup`, `eval_on_selector`.
`page.get_by_role("button").click()` is `Page.get_by_role(page, :button) |> Locator.click!()`.

## Guides

- [Getting started](guides/introduction/getting-started.md): install, the driver, a first script.
- [From playwright.dev to Elixir](guides/introduction/api-conventions.md): how a JS call reads in
  Elixir.
- [Cheatsheet](guides/introduction/cheatsheet.cheatmd): frequent calls, JS next to Elixir.
- [Testing with ExUnit](guides/testing-with-exunit.md): `Playwright.Test` and its browser pool,
  assertions, traces of failures.
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

### Reviewing

Besides correctness, review a change for simplicity, consistency and scope. This applies to
human and Claude reviews alike.

- Prefer the change that removes or shares code over one that adds a parallel path; logic several
  modules repeat belongs in one place.
- Follow how the codebase already does the same thing. A new pattern needs a reason.
- A PR fixes its issue. Edge cases and gaps that predate it are follow-ups: note them
  instead of adding code for them in the PR.

## License

Apache-2.0 ([`LICENSE`](https://github.com/ftes/playwright_ex/blob/main/LICENSE)), as the client is a
port of Playwright's: see [`NOTICE`](https://github.com/ftes/playwright_ex/blob/main/NOTICE). Each
ported file starts with its upstream file's copyright header. Releases up to 0.16 were MIT.
