# Getting started

Snippets alias `PlaywrightEx.{Browser, BrowserType, Playwright, ...}`.

## Installation

Add the dependency to `mix.exs` as shown in the [Overview](../../README.md#installation), then fetch
it and install the driver and the browsers:

```sh
mix deps.get
mix playwright_ex.install
```

The driver is Node.js plus the `playwright-core` package, both pinned and checksum-verified, so
no Node.js or npm is needed beforehand. It goes to the user cache directory
(`PLAYWRIGHT_EX_CACHE_DIR` overrides it) and installs itself on first start if missing. Browsers
go to Playwright's [browser cache](https://playwright.dev/docs/browsers#managing-browser-binaries).
Arguments after `--` go to `playwright install`:

```sh
mix playwright_ex.install -- chromium              # one browser
mix playwright_ex.install -- chromium --with-deps  # and its system packages (Linux CI)
```

To run a browser you already have, such as a system or Nix Chrome, install only the driver and
launch the browser with `:executable_path` or `:channel`:

```sh
mix playwright_ex.install --no-browsers
```

```elixir
playwright = PlaywrightEx.playwright()
BrowserType.launch!(Playwright.chromium(playwright), executable_path: "/path/to/chrome")
```

PlaywrightEx needs Elixir 1.18 or later. The browsers run where Playwright's do: Windows 11+,
macOS 14+, Debian 12 and 13, Ubuntu 22.04 and 24.04
([system requirements](https://playwright.dev/docs/intro#system-requirements)).

## Starting the driver

`PlaywrightEx.Supervisor` runs one driver and its connection. Add it to your supervision tree:

```elixir
children = [
  {PlaywrightEx.Supervisor, name: MyApp.Playwright}
]
```

and get the root `PlaywrightEx.Playwright` object by that name:

```elixir
playwright = PlaywrightEx.playwright(MyApp.Playwright)
```

Without `:name`, the supervisor registers as `PlaywrightEx`, which `PlaywrightEx.playwright/0`
uses. If only your tests need a browser, start it in `test/test_helper.exs`:

```elixir
{:ok, _} = PlaywrightEx.Supervisor.start_link()
ExUnit.start()
```

To use an npm-managed Playwright instead of the pinned driver, pass
`executable: "assets/node_modules/.bin/playwright"`; `PlaywrightEx.Driver` lists the other
options.

## First script

Navigate to a page, print its title and take a screenshot:

```elixir
alias PlaywrightEx.{Browser, BrowserType, Page, Playwright}

{:ok, _} = PlaywrightEx.Supervisor.start_link()
browser = PlaywrightEx.playwright() |> Playwright.chromium() |> BrowserType.launch!()
page = Browser.new_page!(browser)
Page.goto!(page, "https://playwright.dev/")
IO.puts(Page.title!(page))
Page.screenshot!(page, path: "example.png")
Browser.close!(browser)
```

Save it as `example.exs` and run `mix run example.exs`. If your application already starts the
supervisor, drop the `start_link/1` line and pass its name to `PlaywrightEx.playwright/1`.

[`Browser.new_page!/1`](`PlaywrightEx.Browser.new_page!/1`) opens a page in a context of its own. A
[context](https://playwright.dev/docs/browser-contexts) is an isolated browser session (cookies,
storage, options such as `base_url`) and is cheap to create, so use one per test or per user:

```elixir
context = Browser.new_context!(browser, base_url: "http://localhost:4000")
page = BrowserContext.new_page!(context)
Page.goto!(page, "/")
BrowserContext.close!(context)
```

[`Playwright.firefox/1`](`PlaywrightEx.Playwright.firefox/1`) and
[`Playwright.webkit/1`](`PlaywrightEx.Playwright.webkit/1`) launch the other browsers. Browsers run
headless by default; [Watching it run](../debugging-and-ci.md#watching-it-run) shows how to launch
one headed.

## Finding elements

Find elements the way a user does, with `get_by_role`, `get_by_label`, `get_by_text` and
`get_by_test_id`. Use [`Page.locator/3`](`PlaywrightEx.Page.locator/3`) with CSS when nothing
user-facing identifies the element.

```elixir
Page.get_by_role(page, :button, name: "Save") |> Locator.click!()

Page.get_by_role(page, :listitem)
|> Locator.filter(has_text: "Apple")
|> Locator.get_by_role(:button, name: "Buy")
|> Locator.click!()
```

Locators are lazy and strict: nothing is looked up until an action, and an action on a locator that
matches several elements fails. Narrow it with
[`Locator.filter/2`](`PlaywrightEx.Locator.filter/2`),
[`Locator.first/1`](`PlaywrightEx.Locator.first/1`),
[`Locator.last/1`](`PlaywrightEx.Locator.last/1`) or
[`Locator.nth/2`](`PlaywrightEx.Locator.nth/2`). Act directly, as actions wait for their element, so
don't check `is_visible` first. Avoid
[`Page.wait_for_timeout/2`](`PlaywrightEx.Page.wait_for_timeout/2`), which is for debugging: wait
for what the user sees. More: [locators](https://playwright.dev/python/docs/locators).

## Timeouts

Actions and navigations time out after 30 seconds. Set defaults per context (or page) instead
of a `timeout:` per call:

```elixir
BrowserContext.set_default_timeout(context, 5_000)
BrowserContext.set_default_navigation_timeout(context, 10_000)
```

A call's `timeout:` option wins; `0` (or `:infinity`) means no timeout, as in JS. Assertions
(`PlaywrightEx.Expect`) retry for 5 seconds by default:

```elixir
# config/test.exs
config :playwright_ex, :expect, timeout: 10_000
```

## Logging

Each API call logs at `:debug`, as `DEBUG=pw:api` does in JS. To silence it:

```elixir
Logger.put_application_level(:playwright_ex, :info)
```

## Upgrading

To upgrade, bump the dependency and run `mix playwright_ex.install` again for the new driver and
browsers. Read the [changelog](../../CHANGELOG.md) and Playwright's [release
notes](https://playwright.dev/docs/release-notes).

## Next

[From playwright.dev to Elixir](api-conventions.md) shows how a JS call reads in Elixir, and the
[Cheatsheet](cheatsheet.cheatmd) lists frequent calls.
