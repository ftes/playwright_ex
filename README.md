# Playwright

[![Hex.pm Version](https://img.shields.io/hexpm/v/playwright_ex)](https://hex.pm/packages/playwright_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/playwright_ex/)
[![License](https://img.shields.io/hexpm/l/playwright_ex.svg)](https://github.com/ftes/playwright_ex/blob/main/LICENSE)
[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/ftes/playwright_ex/elixir.yml)](https://github.com/ftes/playwright_ex/actions)

Elixir client for [Playwright](https://playwright.dev). Automate Chromium, Firefox and WebKit:
end-to-end tests, web scraping, agentic AI.

It is a 1:1 port of the official JavaScript client. Its API is generated from
Playwright's docs, so the docs at playwright.dev apply. The driver (Node.js and `playwright-core`)
is pinned and installed by Mix, no npm needed. This release drives Playwright 1.65.1.

For Phoenix feature tests with the Ecto sandbox, use [Fluffy](https://hex.pm/packages/fluffy),
which is built on this library.

## Installation

```elixir
def deps do
  [
    {:playwright, "~> 1.65.0-rc.1", hex: :playwright_ex}
  ]
end
```

The Hex package is `playwright_ex`, the app and modules are `playwright` and `Playwright`.
`hex: :playwright_ex` is required: `playwright` on Hex is another library.

```sh
mix deps.get
mix playwright.install
```

Arguments are `playwright install`'s, with no `--`:
`mix playwright.install chromium --with-deps`.

## Versioning

The major.minor is Playwright's and the patch is ours, as in playwright-python: `1.65.x` drives
Playwright 1.65, and this release pins driver 1.65.1. Our own breaking changes ship only with a
Playwright minor, so depend on `~> 1.65.0`.

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

**For no timeout, pass `timeout: :infinity`;** `0` also means no timeout, unlike Elixir's convention
([details](https://hexdocs.pm/playwright_ex/api-conventions.html#no-timeout)).

## Reading playwright.dev

The [Python docs](https://playwright.dev/python/docs/intro) are the closest read, since the
names match Python's: snake_case, keyword options, `expect_popup`, `eval_on_selector`.
`page.get_by_role("button").click()` is `Page.get_by_role(page, :button) |> Locator.click!()`.

## Guides

- [Getting started](guides/introduction/getting-started.md): install, the driver, a first script, usage rules
  for coding agents.
- [From playwright.dev to Elixir](guides/introduction/api-conventions.md): how a JS call reads in
  Elixir.
- [Cheatsheet](guides/introduction/cheatsheet.cheatmd): frequent calls, JS next to Elixir.
- [Testing with ExUnit](guides/testing-with-exunit.md): `Playwright.Test` and its browser pool,
  assertions, traces of failures.
- [Events and waiting](guides/events-and-waiting.md), [Network](guides/network.md),
  [Debugging and CI](guides/debugging-and-ci.md).
- [Concurrency](guides/concurrency.md): listeners, promises and processes.
- [Upgrading from 0.16](guides/upgrading.md).

Feedback of any shape and size is welcome: [get in touch](https://ftes.de).

## Contributing

1. `mix setup` installs dependencies, the pinned Playwright driver and Chromium.
2. `mix test`, or `mix check` for everything CI runs.
3. Porting rules: [`PORTING.md`](https://github.com/ftes/playwright_ex/blob/main/PORTING.md); the why behind the design:
   [`docs/architecture.md`](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md).

### Reviewing

Besides correctness, review a change for simplicity, consistency and scope. This applies to
human and agent reviews alike.

- Prefer the change that removes or shares code over one that adds a parallel path; logic several
  modules repeat belongs in one place.
- Follow how the codebase already does the same thing. A new pattern needs a reason.
- A PR fixes its issue. Edge cases and gaps that predate it are follow-ups: note them
  instead of adding code for them in the PR.

## License

Apache-2.0 ([`LICENSE`](https://github.com/ftes/playwright_ex/blob/main/LICENSE)), as the client is a
port of Playwright's: see [`NOTICE`](https://github.com/ftes/playwright_ex/blob/main/NOTICE). Each
ported file starts with its upstream file's copyright header. Releases up to 0.16 were MIT.
