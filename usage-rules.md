# PlaywrightEx usage rules

PlaywrightEx is a 1:1 Elixir port of the Playwright client. Its API is generated from upstream's
docs, so playwright.dev applies; the Python docs are the closest read. For Phoenix feature tests
with the Ecto sandbox, use [Fluffy](https://hex.pm/packages/fluffy), which is built on this library.

## Setup

- `mix playwright_ex.install` installs the pinned driver (Node.js and `playwright-core`) and browsers. Do not add npm `playwright`.
- `mix playwright_ex.install -- chromium --with-deps` installs one browser and its system packages on Linux CI. `--no-browsers` installs only the driver, for a browser launched with `:executable_path` or `:channel`. Run the task again after upgrading the dependency.
- Start one driver: `{PlaywrightEx.Supervisor, name: MyApp.Playwright}` in a supervision tree, read with `PlaywrightEx.playwright(MyApp.Playwright)`. In tests, call `PlaywrightEx.Supervisor.start_link()` in `test_helper.exs` before `ExUnit.start()`, read with `PlaywrightEx.playwright()`.
- Share one browser and give each test or user its own context. Contexts are cheap and isolated.
- Close what you open, for example `on_exit(fn -> BrowserContext.close(context) end)`. A browser or context does not close when the process that created it exits.

```elixir
alias PlaywrightEx.{Browser, BrowserContext, BrowserType, Expect, Locator, Page, Playwright}

browser = PlaywrightEx.playwright() |> Playwright.chromium() |> BrowserType.launch!()
context = Browser.new_context!(browser, base_url: "http://localhost:4000")
page = BrowserContext.new_page!(context)

Page.goto!(page, "/sign-up")
Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome")
```

## API shape

- Use the generated facade: `PlaywrightEx.Page`, `Locator`, `BrowserContext`, `Expect` and so on. `PlaywrightEx.Client.*` and `PlaywrightEx.Runtime.*` are internal.
- A JS method is a function taking the object first, in snake_case. Properties are functions too (`Page.keyboard(page)`). Predicates keep Python's names: `Locator.is_visible!/2`, not `visible?`.
- A call JS awaits has two forms. `name` returns `{:ok, value}`, `:ok` for a void call, or `{:error, exception}`. `name!` returns the value, `:ok` for a void call, or raises.
- Use bang forms in scripts and tests, tuple forms where failure is an expected outcome.
- A call JS does not await returns a plain value and has no bang form: `Page.url/1`, `Page.locator/3`, `Page.get_by_role/3`, `Locator.filter/2`.
- Options come last, as a keyword list or map with snake_case keys: `Page.screenshot!(page, path: "a.png", full_page: true)`. Unknown keys raise `ArgumentError` from both forms.
- Nested option values are maps with the JS keys: `viewport: %{width: 1280, height: 720}`, `%{sameSite: "Lax"}`.
- String enums are atoms (`:no_preference`). `nil` is JS `undefined`, `:null` is JS `null`, also in `evaluate` results.
- `timeout: :infinity` or `0` disables a timeout. Strings are literal text or URL globs; use `~r//` for a pattern.

## Locators and assertions

- Prefer `get_by_role`, `get_by_label`, `get_by_text` and `get_by_test_id`. Use `Page.locator/3` with CSS when nothing user-facing identifies the element.
- Locators are lazy and strict: an action on a locator matching several elements fails. Narrow it with `Locator.filter/2`, `first/1`, `last/1` or `nth/2`.
- Act directly. Actions wait for their element, so do not check `is_visible` first.
- Assert with `PlaywrightEx.Expect`, which retries until the timeout: `Expect.to_have_url!(page, ~r"/dashboard$")`. `assert Locator.text_content!(l) == "x"` reads once and races the page.
- Negate with `Expect.not_to_be_visible!(l)` or `l |> Expect.not_() |> Expect.to_be_visible!()`.
- After a click that navigates, assert on the new page; the click returns before it loads.
- Avoid `Page.wait_for_timeout/2` (debugging only) and waiting for `:networkidle`. Wait for what the user sees.
- Matchers return `:ok` or `{:error, %PlaywrightEx.ExpectError{}}`; the bang forms raise the error, which fails an ExUnit test.

## Timeouts and `Expect` configuration

Actions and navigations wait 30 seconds. Lower that per context with `BrowserContext.set_default_timeout/2` and `set_default_navigation_timeout/2` rather than a `timeout:` on every call. Matchers wait 5 seconds and are configured separately:

```elixir
# config/test.exs
config :playwright_ex, :expect, timeout: 10_000, update_snapshots: :missing
```

- Keys are `:timeout`, `:update_snapshots` (`:all`, `:changed`, `:missing`, `:none`, `:default`), `:ignore_snapshots`, `:to_have_screenshot` and `:to_match_aria_snapshot`. Other keys raise `ArgumentError`.
- A matcher's own `timeout:` wins.
- An inline aria snapshot cannot be written into test source. Where a rebaseline applies, the matcher fails with the new snapshot in its message.

## Events and concurrency

- Start a wait before the action that triggers it. Use `Page.expect_download!(page, fn -> ... end)`, or `expect_popup!`, `expect_request!`, `expect_response!`, `expect_console_message!`, `expect_event!`.
- Or start `promise = Page.wait_for_event(page, :download)`, act, then `PlaywrightEx.Promise.await!(promise)`. `Page.wait_for_event!/3` awaits at once and misses what the code before it triggered.
- Your own check-then-wait can miss an event. Start the wait, read the state, then await the wait or call `PlaywrightEx.Promise.free/1`. The client's own waits and matchers already do this.
- `on/3`, `once/3` and `off/3` take a listener that runs in its own process. The connection waits for it to return or await a Playwright call before dispatching the next message.
- Keep listeners short. `Process.sleep/1`, `receive`, HTTP or a busy `GenServer.call` in a listener stalls every page on the connection. Send the work elsewhere:

```elixir
owner = self()
Page.on(page, :console, fn msg -> send(owner, {:console, ConsoleMessage.text(msg)}) end)
```

- A listener may call Playwright, as a `:dialog` listener calls `Dialog.accept/1`. Dialogs without a listener are dismissed; with a listener, it must accept or dismiss them.
- Any process can await a promise, while the process that started the wait is alive. Calls from many processes overlap freely.

## Going beyond the facade

- `Page.evaluate!/3` and `Locator.evaluate!/3` take JS source, an expression or a function receiving the optional argument. Use them for what the API does not expose, not to click or read what a locator can.
- Debug with traces (`BrowserContext.tracing/1`, `Tracing.start!/2`, `Tracing.stop!/2`), viewed by `mix playwright_ex.cli show-trace trace.zip`.
- A wrapper passing options on can document and check them with `__options__/1` on the facade modules.
