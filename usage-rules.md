# Playwright usage rules

This library (`Playwright`, Hex package `playwright_ex`) is a 1:1 Elixir port of the Playwright client. Its API is generated from upstream's
docs, so playwright.dev applies; the Python docs are the closest read.

**For no timeout, pass `timeout: :infinity`.** Unlike Elixir's convention, where `0` means don't wait (`receive ... after 0`), `timeout: 0` here means no timeout, as in Playwright JS: never use it for an immediate check.

Code written for 0.16 or earlier (guids, `Frame.click(frame.guid, selector: ...)`, `Selector`, `EventWaiter`, `launch_browser/2`) uses the removed API: port it with the [upgrading guide](https://hexdocs.pm/playwright_ex/upgrading.html).

## Setup

- Depend on `{:playwright, "~> 1.65.0-rc.1", hex: :playwright_ex}` (the README has the current version). `hex: :playwright_ex` is required. Versions are Playwright's major.minor with our own patch, so `~> 1.65.0` takes our fixes for Playwright 1.65. If only tests use it, prefer `only: [:dev, :test]` to `only: :test`, so its mix tasks work in `:dev`.
- The app is `:playwright`, the modules `Playwright.*`. Until this library takes over the `playwright` name on Hex, the Hex package `playwright` (hexdocs.pm/playwright) is another Elixir library, playwright-elixir, with another API: don't use its docs or examples (`Playwright.launch(:chromium)`, `Playwright.Page.click(page, selector)`). This library's docs are at hexdocs.pm/playwright_ex.
- `mix playwright.install` installs the pinned driver (Node.js and `playwright-core`) and browsers. Do not add npm `playwright`.
- `mix playwright.install -- chromium --with-deps` installs one browser and its system packages on Linux CI. `--no-browsers` installs only the driver, for a browser launched with `:executable_path` or `:channel`. Run the task again after upgrading the dependency.
- Tests use `Playwright.Test` (see "Testing with Playwright.Test"). It starts its drivers on the first test and stops them after the suite, so `test_helper.exs` needs only `ExUnit.start()`. Don't start a `Playwright.Supervisor` for those tests.
- Apps, scripts and hand-rolled test setups start one driver: `{Playwright.Supervisor, name: MyApp.PlaywrightDriver}` in a supervision tree, read with `Playwright.instance(MyApp.PlaywrightDriver)`. Without `:name` it registers as `Playwright`, read with `Playwright.instance()`; in a script or `test_helper.exs`, `{:ok, _} = Playwright.Supervisor.start_link()`, and `Supervisor.stop(Playwright)` at the end (`ExUnit.after_suite/1` in tests).
- Don't alias a module of your own named `Playwright` (`alias MyApp.Playwright`) where you use this library: `Playwright.Page` and `Playwright.instance()` then silently resolve to `MyApp.Playwright.Page` and `MyApp.Playwright.instance()`. Call yours in full or `import` it, or alias it `as: MyPlaywright`. In a sorted alias list, `alias MyApp.Playwright` comes before `alias Playwright.Page`, which then expands to `MyApp.Playwright.Page`: write `alias Elixir.Playwright.Page` there.
- Outside `Playwright.Test`, share one browser, give each user its own context, and close what you open, for example `on_exit(fn -> BrowserContext.close(context) end)`. A browser or context does not close when the process that created it exits.

```elixir
# A script, after Playwright.Supervisor.start_link()
alias Playwright.{Browser, BrowserContext, BrowserType, Expect, Locator, Page}

browser = Playwright.instance() |> Playwright.chromium() |> BrowserType.launch!()
context = Browser.new_context!(browser, base_url: "http://localhost:4000")
page = BrowserContext.new_page!(context)

Page.goto!(page, "/sign-up")
Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome")
```

## API shape

- Use the generated facade: `Playwright.Page`, `Locator`, `BrowserContext`, `Expect` and so on. `Playwright.Client.*` and `Playwright.Runtime.*` are internal.
- A JS method is a function taking the object first, in snake_case. Properties are functions too (`Page.keyboard(page)`). Predicates keep Python's names: `Locator.is_visible!/2`, not `visible?`.
- A call JS awaits has two forms. `name` returns `{:ok, value}`, `:ok` for a void call, or `{:error, exception}`. `name!` returns the value, `:ok` for a void call, or raises.
- Use bang forms in scripts and tests, tuple forms where failure is an expected outcome.
- A call JS does not await returns a plain value and has no bang form: `Page.url/1`, `Page.locator/3`, `Page.get_by_role/3`, `Locator.filter/2`.
- Options come last, as a keyword list or map with snake_case keys: `Page.screenshot!(page, path: "a.png", full_page: true)`. Unknown keys raise `ArgumentError` from both forms.
- Nested option values are maps with the JS keys: `viewport: %{width: 1280, height: 720}`, `%{sameSite: "Lax"}`.
- String enums are atoms (`:no_preference`). `nil` is JS `undefined`, `:null` is JS `null`, also in `evaluate` results.
- Strings are literal text or URL globs; use `~r//` for a pattern.

## Locators and assertions

- Follow Playwright's locator priority: `Page.get_by_role/3` with `name:`, then `get_by_label`, `get_by_placeholder`, `get_by_text` (non-interactive elements), `get_by_alt_text` or `get_by_title`, `get_by_test_id`; `Page.locator/3` with CSS or XPath last, never by CSS classes or DOM structure. If no user-facing locator fits, consider fixing the markup (a field without a `<label>`, a button without an accessible name).
- Narrow by chaining and filtering: `Locator` has the same `get_by_*` functions, and `Locator.filter/2` takes `has_text:`, `has:`, `has_not_text:` and `has_not:`: `Page.get_by_role(page, :listitem) |> Locator.filter(has_text: "Product 2") |> Locator.get_by_role(:button, name: "Add to cart")`.
- Locators are lazy and strict: an action on a locator matching several elements fails. Use `Locator.first/1`, `last/1` or `nth/2` only when order is what tells identical elements apart.
- Assert with `Playwright.Expect`, which retries until the timeout: `Expect.to_be_visible!(Page.get_by_text(page, "Welcome"))`, `Expect.to_have_url!(page, ~r"/dashboard$")`. `assert Locator.is_visible!(l)` or `assert Locator.text_content!(l) == "x"` reads once and races the page.
- Negate with `Expect.not_to_be_visible!(l)` or `l |> Expect.not_() |> Expect.to_be_visible!()`.
- Matchers return `:ok` or `{:error, %Playwright.ExpectError{}}`; the bang forms raise the error, which fails an ExUnit test.

## Timeouts and `Expect` configuration

Actions and navigations wait 30 seconds, except in a `Playwright.Test` test, where only the test's timeout bounds them (see below). Lower that per context with `BrowserContext.set_default_timeout/2` and `set_default_navigation_timeout/2` rather than a `timeout:` on every call. Matchers wait 5 seconds, also in tests, and are configured separately:

```elixir
# config/test.exs
config :playwright, :expect, timeout: 10_000, update_snapshots: :missing
```

- Keys are `:timeout`, `:update_snapshots` (`:all`, `:changed`, `:missing`, `:none`, `:default`), `:ignore_snapshots`, `:to_have_screenshot` and `:to_match_aria_snapshot`. Other keys raise `ArgumentError`.
- A matcher's own `timeout:` wins.
- An inline aria snapshot cannot be written into test source. Where a rebaseline applies, the matcher fails with the new snapshot in its message.

## Testing with Playwright.Test

ExUnit is the runner. `Playwright.Test` adds Playwright Test's per-test machinery: browsers from a pool, context defaults, traces, screenshots, videos, steps and snapshot paths. There is no `@playwright/test` and no fixture injection.

```elixir
# config/test.exs
config :playwright, :test,
  context_options: [base_url: "http://localhost:4000"],
  trace: :retain_on_failure,
  screenshot: :only_on_failure

defmodule MyApp.SignUpTest do
  use Playwright.Case, async: true

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Expect.to_have_title!(page, "Sign up")
  end
end
```

- `use Playwright.Case` gives the module a `browser` (`setup_all`) and each test a fresh `context` and `page`, and aliases `Browser`, `BrowserContext`, `Expect`, `Locator`, `Page`, `Test` and `Test.BrowserPool`. In a case template, `use Playwright.Case` inside `using` and add your `setup` after it.
- Upstream's fixtures are functions: `browser` is `BrowserPool.browser/1`, `testInfo` is `Playwright.Test.info/0`, `test.use({...})` is `use Playwright.Test, trace: :on` or a tag, `projects` are `parameterize:` over `browser_name`.
- `BrowserPool` is upstream's worker model: at most `workers` drivers+browsers at once, each held by one module and replaced after a failure. A module's tests run in sequence, so prefer many small `async: true` modules. Register selectors per driver with `on_start: &MyApp.Selectors.register/1`.
- Actions and navigations have no timeout of their own; ExUnit's test timeout (60 s, `@tag timeout:`) bounds them and fails a stuck call with its call log. Set `action_timeout`/`navigation_timeout` in config to fail sooner.
- `trace`, `screenshot` and `video` take upstream's modes as atoms (`:retain_on_failure`, `:only_on_failure`, `:on_first_retry`, ...), set in config, `use Playwright.Test` options or `@tag`/`@moduletag`. ExUnit has no retries: `mix test --failed` is the retry.
- Each test writes to `test-results/<test>/`. A failed test gets `error-context.md` (errors, source, an aria snapshot of the page): read it first. Open traces with `mix playwright.cli show-trace <path>`.
- `Playwright.Test.step "log in" do ... end` is `test.step`; pass `box: true` in helpers.
- Snapshots live in `<test file>-snapshots/`, named by `name:` or after the test; a missing one is written and fails the test: commit it. `Expect.soft/1` and errors in route handlers or listeners also fail the test at the end of its body.
- Details, case templates without `Playwright.Case`, and what isn't supported: the [testing guide](https://hexdocs.pm/playwright_ex/testing-with-exunit.html).

## Configuration

- There is no `playwright.config.ts`, `package.json` or npm `playwright`/`@playwright/test`. Configure in Elixir config: the runner under `config :playwright, :test`, the matchers under `config :playwright, :expect`, the driver under `config :playwright, :driver`. Other `config :playwright` keys (but a module's own, such as `Playwright.Test.GitHubFormatter`) raise at startup, as do unknown keys and bad values in these.
- `config :playwright, :test` keys: `browser_name` (`:chromium`), `launch_options`, `connect_options` (`[ws_endpoint: _, ...]`), `driver`, `on_start`, `workers` (half the schedulers), `context_options`, `action_timeout`, `navigation_timeout`, `trace`, `screenshot`, `video`, `output_dir` (`"test-results"`), `preserve_output` (`:always`, `:failures_only`, `:never`), `snapshot_dir`, `snapshot_path_template`, `test_id_attribute` (`"data-testid"`). The test id attribute is global to the VM: set it here, not per module.
- Neither Playwright Test's environment variables (`PLAYWRIGHT_TEST_BASE_URL`, `PW_TEST_CONNECT_WS_ENDPOINT`) nor any of the library's own are read. Read the ones you want in config: `context_options: [base_url: System.get_env("BASE_URL", "http://localhost:4000")]`. The driver and its CLI still read theirs (`PWDEBUG=1`, `DEBUG=pw:api`, `PLAYWRIGHT_BROWSERS_PATH`).
- Driver settings are `config :playwright, :driver` with `cache_dir:`, `executable:` (an npm-managed `playwright` CLI) and `node:` (a Node.js binary). Put them in `config/config.exs`, not `config/test.exs` or `config/runtime.exs`: `mix playwright.install` runs in `:dev` and doesn't compile the project, so it sees only `config/config.exs` and what it imports. Take an env var there: `if dir = System.get_env("PLAYWRIGHT_CACHE_DIR"), do: config(:playwright, :driver, cache_dir: dir)`. The `:test` config's `driver:` reaches only the pooled drivers, not `mix playwright.install`.

## Events and concurrency

- Start a wait before the action that triggers it. Use `Page.expect_download!(page, fn -> ... end)`, or `expect_popup!`, `expect_request!`, `expect_response!`, `expect_console_message!`, `expect_event!`.
- Or start `promise = Page.wait_for_event(page, :download)`, act, then `Playwright.Promise.await!(promise)`. `Page.wait_for_event!/3` awaits at once and misses what the code before it triggered.
- Your own check-then-wait can miss an event. Start the wait, read the state, then await the wait or call `Playwright.Promise.free/1`. The client's own waits and matchers already do this.
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
- Debug with traces (`BrowserContext.tracing/1`, `Tracing.start!/2`, `Tracing.stop!/2`), viewed by `mix playwright.cli show-trace trace.zip`. In tests, use the `trace` mode instead.
- A wrapper passing options on can document and check them with `__options__/1` on the facade modules.
