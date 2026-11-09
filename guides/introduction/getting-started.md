# Getting started

## Installation

Add the dependency to `mix.exs`:

```elixir
def deps do
  [
    {:playwright_ex, "~> 0.17.0-rc.4"}
  ]
end
```

Then fetch it and install the driver and the browsers:

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

`Browser.new_page!/1` opens a page in a context of its own. A
[context](https://playwright.dev/docs/browser-contexts) is an isolated browser session (cookies,
storage, options such as `base_url`) and is cheap to create, so use one per test or per user:

```elixir
context = Browser.new_context!(browser, base_url: "http://localhost:4000")
page = BrowserContext.new_page!(context)
Page.goto!(page, "/")
BrowserContext.close!(context)
```

`Playwright.firefox/1` and `Playwright.webkit/1` launch the other browsers.

## Headless and headed

Browsers run headless by default. To watch one, launch it headed and slow it down:

```elixir
BrowserType.launch!(chromium, headless: false, slow_mo: 50)
```

## Timeouts

Actions and navigations time out after 30 seconds. Set defaults per context (or page) instead
of a `timeout:` per call:

```elixir
BrowserContext.set_default_timeout(context, 5_000)
BrowserContext.set_default_navigation_timeout(context, 10_000)
```

A call's `timeout:` option wins; `0` means no timeout, as in JS. Assertions (`PlaywrightEx.Expect`)
retry for 5 seconds by default:

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

This release drives Playwright 1.65. To upgrade, bump the dependency and
run `mix playwright_ex.install` again for the new driver and browsers.
Read the [changelog](../../CHANGELOG.md) and Playwright's
[release notes](https://playwright.dev/docs/release-notes).

## Next

- [From playwright.dev to Elixir](api-conventions.md): options, results, events and errors.
- [Cheatsheet](cheatsheet.cheatmd): frequent calls, JS next to Elixir.
- [Testing with ExUnit](../testing-with-exunit.md): a browser case template, assertions, failures.
- [Events and waiting](../events-and-waiting.md), [Network](../network.md),
  [Debugging and CI](../debugging-and-ci.md).
- [Concurrency](../concurrency.md): listeners and promises across processes.
