# Getting started

Snippets alias `Playwright.{Browser, BrowserType, ...}`.

## Installation

Add the dependency to `mix.exs` as shown in the [Overview](../../README.md#installation). Its name
is the app's, `:playwright`, and `hex: :playwright_ex` is required: the Hex package is
`playwright_ex`, as `playwright` on Hex is another library. If you only use it in tests, prefer
`only: [:dev, :test]` to `only: :test`: its mix tasks, and `mix usage_rules.sync` for its
[usage rules](#usage-rules-for-coding-agents), then work in `:dev`, where it starts no driver. Fetch it and install the
driver and the browsers:

```sh
mix deps.get
mix playwright.install
```

The driver is Node.js plus the `playwright-core` package, both pinned and checksum-verified, so
no Node.js or npm is needed beforehand. It goes to the user cache directory
(`config :playwright, :driver, cache_dir: ...` overrides it, see `Playwright.Driver`; to take it
from an environment variable, locally or in CI, read that in `config/config.exs`) and installs itself on first
start if missing. Browsers
go to Playwright's [browser cache](https://playwright.dev/docs/browsers#managing-browser-binaries).
Arguments after `--` go to `playwright install`:

```sh
mix playwright.install -- chromium              # one browser
mix playwright.install -- chromium --with-deps  # and its system packages (Linux CI)
```

In CI, run it in the tests' env, as [Debugging and CI](../debugging-and-ci.md#github-actions)
shows.

To run a browser you already have, such as a system or Nix Chrome, install only the driver and
launch the browser with `:executable_path` or `:channel`:

```sh
mix playwright.install --no-browsers
```

```elixir
playwright = Playwright.instance()
BrowserType.launch!(Playwright.chromium(playwright), executable_path: "/path/to/chrome")
```

The library needs Elixir 1.18 or later. The browsers run where Playwright's do: Windows 11+,
macOS 14+, Debian 12 and 13, Ubuntu 22.04, 24.04 and 26.04
([system requirements](https://playwright.dev/docs/intro#system-requirements)).

## Starting the driver

`Playwright.Supervisor` runs one driver and its connection. Add it to your supervision tree:

```elixir
children = [
  {Playwright.Supervisor, name: MyApp.Playwright}
]
```

and get the root `Playwright` object by that name:

```elixir
playwright = Playwright.instance(MyApp.Playwright)
```

Without `:name`, the supervisor registers as `Playwright`, which `Playwright.instance/0`
uses. If only your tests need a browser, start it in `test/test_helper.exs`:

```elixir
{:ok, _} = Playwright.Supervisor.start_link()
ExUnit.after_suite(fn _ -> Supervisor.stop(Playwright) end)
ExUnit.start()
```

`mix test` halts the VM without stopping the supervisor. Stopping it in `after_suite` waits for
the driver to exit, which could otherwise reset the terminal after the run (↑ printing `OA`).

To use an npm-managed Playwright instead of the pinned driver, pass
`executable: "assets/node_modules/.bin/playwright"`; `Playwright.Driver` lists the other
options.

## First script

Navigate to a page, print its title and take a screenshot:

```elixir
alias Playwright.{Browser, BrowserType, Page}

{:ok, _} = Playwright.Supervisor.start_link()
browser = Playwright.instance() |> Playwright.chromium() |> BrowserType.launch!()
page = Browser.new_page!(browser)
Page.goto!(page, "https://playwright.dev/")
IO.puts(Page.title!(page))
Page.screenshot!(page, path: "example.png")
Browser.close!(browser)
Supervisor.stop(Playwright)
```

Save it as `example.exs` and run `mix run example.exs`. `mix run` halts the VM without stopping
the supervisor; `Supervisor.stop/1` waits for the driver to exit, which could otherwise reset the
terminal afterwards. If your application already starts the supervisor, drop the `start_link/1`
and `Supervisor.stop/1` lines, pass its name to `Playwright.instance/1`, and end the script
with `Application.stop(:my_app)` instead (your app restarts a supervisor stopped on its own).

[`Browser.new_page!/1`](`Playwright.Browser.new_page!/1`) opens a page in a context of its own. A
[context](https://playwright.dev/docs/browser-contexts) is an isolated browser session (cookies,
storage, options such as `base_url`) and is cheap to create, so use one per test or per user:

```elixir
context = Browser.new_context!(browser, base_url: "http://localhost:4000")
page = BrowserContext.new_page!(context)
Page.goto!(page, "/")
BrowserContext.close!(context)
```

[`Playwright.firefox/1`](`Playwright.firefox/1`) and
[`Playwright.webkit/1`](`Playwright.webkit/1`) launch the other browsers. Browsers run
headless by default; [Watching it run](../debugging-and-ci.md#watching-it-run) shows how to launch
one headed.

## Finding elements

Find elements the way a user does: `get_by_role` with `name:` for interactive elements,
`get_by_label` for form fields, `get_by_text` for non-interactive text, and `get_by_test_id`
when nothing user-facing identifies the element. Use
[`Page.locator/3`](`Playwright.Page.locator/3`) with CSS or XPath only as a last resort, never
by CSS classes or DOM structure.

```elixir
Page.get_by_role(page, :button, name: "Save") |> Locator.click!()

Page.get_by_role(page, :listitem)
|> Locator.filter(has_text: "Apple")
|> Locator.get_by_role(:button, name: "Buy")
|> Locator.click!()
```

Locators are lazy and strict: nothing is looked up until an action, and an action on a locator that
matches several elements fails. Narrow it with
[`Locator.filter/2`](`Playwright.Locator.filter/2`),
[`Locator.first/1`](`Playwright.Locator.first/1`),
[`Locator.last/1`](`Playwright.Locator.last/1`) or
[`Locator.nth/2`](`Playwright.Locator.nth/2`). Act directly, as actions wait for their element, so
don't check `is_visible` first. Avoid
[`Page.wait_for_timeout/2`](`Playwright.Page.wait_for_timeout/2`), which is for debugging: wait
for what the user sees. More: [locators](https://playwright.dev/python/docs/locators).

## Timeouts

Actions and navigations time out after 30 seconds (in a `Playwright.Test` test, as in
Playwright Test, only the test's timeout bounds them, see
[Testing with ExUnit](../testing-with-exunit.md#setup)). Set defaults per context (or page)
instead of a `timeout:` per call:

```elixir
BrowserContext.set_default_timeout(context, 5_000)
BrowserContext.set_default_navigation_timeout(context, 10_000)
```

For no timeout, pass `timeout: :infinity`; `0` also means no timeout, unlike Elixir's convention ([details](api-conventions.md#no-timeout)).

A call's `timeout:` option wins. Assertions (`Playwright.Expect`) retry for 5 seconds by
default:

```elixir
# config/test.exs
config :playwright, :expect, timeout: 10_000
```

## Logging

Each API call logs at `:debug`, as `DEBUG=pw:api` does in JS. To silence it:

```elixir
Logger.put_application_level(:playwright, :info)
```

## Upgrading

To upgrade, bump the dependency and run `mix playwright.install` again for the new driver and
browsers. Read the [changelog](../../CHANGELOG.md) and Playwright's [release
notes](https://playwright.dev/docs/release-notes). From 0.16, follow the
[upgrading guide](../upgrading.md).

## Usage rules for coding agents

The package ships usage rules for coding agents. Sync them with
[`usage_rules`](https://hexdocs.pm/usage_rules) as a skill:

```elixir
# mix.exs
def project do
  [
    # ...
    usage_rules: [
      skills: [
        build: [
          playwright: [
            description: "Use when writing browser automation or tests with Playwright.",
            usage_rules: [:playwright]
          ]
        ]
      ]
    ]
  ]
end
```

Run `mix usage_rules.sync` after upgrading.

## Next

[From playwright.dev to Elixir](api-conventions.md) shows how a JS call reads in Elixir, and the
[Cheatsheet](cheatsheet.cheatmd) lists frequent calls.
