# Upgrading from 0.x

1.x does not evolve 0.16's API: it is a port of Playwright's JS client, so
[playwright.dev](https://playwright.dev/docs/api/class-playwright) applies (the
[changelog](../CHANGELOG.md)'s introduction has the model). Port each 0.x call by what it does:
find the JS method for it, then its Elixir name with
[From playwright.dev to Elixir](introduction/api-conventions.md).

## Dependency and names

```elixir
{:playwright, "~> 1.65.0-rc.5", hex: :playwright_ex}
```

The app is `:playwright` and the modules are `Playwright.*`: `PlaywrightEx.Page` is
`Playwright.Page`. A module of your own named `Playwright` (`alias MyApp.Playwright`) shadows
them: call yours in full or alias it `as: MyPlaywright`; below `alias MyApp.Playwright` in a
sorted alias list, write `alias Elixir.Playwright.Page`.

## What replaces what

Unknown options raise everywhere in 1.x, where 0.16 passed them on.

- **npm**: `mix playwright.install` installs the pinned driver and its browsers, no npm
  `playwright` package ([Getting started](introduction/getting-started.md#installation)). An npm
  CLI you keep with `executable:` must be `Playwright.Driver.version/0`'s version: nothing
  checks it.
- **`PlaywrightEx.Supervisor`**: `Playwright.Supervisor` takes `:name`, `:executable`, `:node`,
  `:cache_dir` and `:env`: no `timeout:` or `js_logger:`, and `ws_endpoint:` moves to
  `Playwright.BrowserType.connect/3`. The driver options default to
  `config :playwright, :driver` (`Playwright.Driver`).
- **`PlaywrightEx.launch_browser/2`**: `Playwright.instance() |> Playwright.chromium()` and
  `Playwright.BrowserType.launch!/2`; `Playwright.firefox/1` and `Playwright.webkit/1` replace
  the browser type argument.
- **guids and `connection:`**: calls take the handles calls return (`Browser`, `BrowserContext`,
  `Page`, `Frame`, `Locator`). `Playwright.BrowserContext.new_page/1` returns the page: use its
  functions and locators rather than its `Playwright.Page.main_frame/1`.
- **`timeout:` on every call**: optional now, with defaults per context
  ([Timeouts](introduction/getting-started.md#timeouts)).
- **`Selector`**: a selector string, or better a locator such as `Playwright.Page.get_by_role/3`.
- **`EventWaiter`**: start the wait before the action, with `Playwright.Page.expect_download!/3`
  and the other `expect_*` functions, or `Playwright.Page.wait_for_event/3` and
  `Playwright.Promise.await!/1`
  ([Events and waiting](events-and-waiting.md#one-event-start-the-wait-then-act)).
- **`Route`, `Download`, `Artifact`, `FilePayload`**: `Playwright.Route` and
  `Playwright.Download` are the JS classes ([Network](network.md#mocking-with-routes),
  [Downloads](events-and-waiting.md#downloads)); a download's artifact is internal, and a file
  payload is a map ([File choosers](events-and-waiting.md#file-choosers)).
- **`evaluate`**: `Playwright.Page.evaluate/4` takes the JS source and its argument, and no
  `timeout:`
  ([`evaluate` takes JS source](introduction/api-conventions.md#evaluate-takes-js-source),
  [`nil` and `:null`](introduction/api-conventions.md#enums-nil-and-null)).
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
