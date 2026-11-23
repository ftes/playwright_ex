# Upgrading from 0.x

1.x does not evolve 0.16's API: it is a port of Playwright's JS client, so
[playwright.dev](https://playwright.dev/docs/api/class-playwright) applies (the
[changelog](../CHANGELOG.md)'s introduction has the model). Port each 0.x call by what it does:
find the JS method for it, then its Elixir name with
[From playwright.dev to Elixir](introduction/api-conventions.md).

## Dependency and names

```elixir
{:playwright, "~> 1.65.0-rc.4", hex: :playwright_ex}
```

1.x needs Elixir 1.18 or later. The app is `:playwright` and the modules are `Playwright.*`:
`PlaywrightEx.Page` is `Playwright.Page`. Mind a module of your own named `Playwright`:
after `alias MyApp.Playwright`, `Playwright.Page` is `MyApp.Playwright.Page`. The
[usage rules](https://github.com/ftes/playwright_ex/blob/main/usage-rules.md) list this trap and
the others.

## What replaces what

- **npm**: `mix playwright.install` installs the pinned driver and its browsers, no npm
  `playwright` package ([Getting started](introduction/getting-started.md#installation)). An npm
  CLI you keep with `executable:` must be `Playwright.Driver.version/0`'s version: nothing
  checks it.
- **`PlaywrightEx.Supervisor`**: `Playwright.Supervisor` takes `:name`, `:executable`, `:node`,
  `:cache_dir` and `:env`, and raises for others such as `timeout:` and `js_logger:`. The driver
  options default to `config :playwright, :driver` (`Playwright.Driver`).
- **`PlaywrightEx.launch_browser/2`**:
  `Playwright.instance() |> Playwright.chromium() |> BrowserType.launch!()`. A `ws_endpoint` is
  `Playwright.BrowserType.connect/3`.
- **guids and `connection:`**: calls take the handles calls return (`Browser`, `BrowserContext`,
  `Page`, `Frame`, `Locator`). `Playwright.BrowserContext.new_page/1` returns the page: use its
  functions and locators rather than its `Playwright.Page.main_frame/1`.
- **`timeout:` on every call**: drop it. Outside `Playwright.Test` calls wait 30 seconds;
  `Playwright.BrowserContext.set_default_timeout/2` sets that per context.
- **`Selector`**: a selector string, or better a locator such as `Playwright.Page.get_by_role/3`.
- **`evaluate`**: `Playwright.Page.evaluate/4` takes the JS source and its argument
  (`Page.evaluate!(page, "x => x * 2", 21)`) and, as in JS, no `timeout:`. For a bounded wait,
  `Playwright.Page.wait_for_function/4` takes one; in a test, the test's timeout bounds the
  rest. JS `null` is `:null`, `undefined` is `nil`.
- **Screenshots**: `Playwright.Page.screenshot/2` returns the image's bytes, not base64.
- **JS logger and protocol subscriptions**: listen to events, as in JS:
  `Playwright.BrowserContext.on/3` with `:console` and `:web_error`, `Playwright.Page.on/3` with
  `:request`, `:response` and `:web_socket`, `Playwright.WebSocket.on/3` with `:frame_sent`
  and `:frame_received` ([Events and waiting](events-and-waiting.md#every-event-listeners)).
- **`PlaywrightEx.send/2` and the other raw-protocol functions**: gone, as JS has no public
  equivalent. Call the method JS has, such as `Playwright.Page.set_viewport_size/2` or
  `Playwright.Page.close/2`.
- **Hand-rolled test setup**: `use Playwright.Case` gives each test a `page` from a pooled browser
  and closes it ([Testing with ExUnit](testing-with-exunit.md)). PhoenixTest.Playwright users
  follow its docs instead.
