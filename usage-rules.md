# Playwright usage rules

This library (`Playwright`, Hex package `playwright_ex`) is a 1:1 Elixir port of the Playwright client. Its API is generated from upstream's
docs, so playwright.dev applies; the Python docs are the closest read. For Phoenix feature tests
with the Ecto sandbox, use [Fluffy](https://hex.pm/packages/fluffy), which is built on this library.

**`timeout: 0` (or `:infinity`) means no timeout, not an immediate one.** As in Playwright JS, the call waits forever.

Code written for 0.16 or earlier (guids, `Frame.click(frame.guid, selector: ...)`, `Selector`, `EventWaiter`, `launch_browser/2`) uses the removed API: port it with the [migration guide](https://hexdocs.pm/playwright_ex/migration.html).

## Setup

- Depend on `{:playwright, "~> 0.17.0-rc.6", hex: :playwright_ex}` (the README has the current version). `hex: :playwright_ex` is required. While releases are RCs, keep the `-rc.N`: `~> 0.17` matches no RC. If only tests use it, prefer `only: [:dev, :test]` to `only: :test`, so its mix tasks work in `:dev`.
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

- `use Playwright.Case` gives the module a `browser` (in `setup_all`) and each test a fresh `context` and its `page`. It aliases `Playwright.{Browser, BrowserContext, Expect, Locator, Page, Test}` and `Playwright.Test.BrowserPool`, and takes ExUnit.Case's options and `use Playwright.Test`'s.
- `use Playwright.Test` alone (after `use ExUnit.Case`) registers each test but adds no context keys: take the browser from `Playwright.Test.BrowserPool.browser/1` in `setup_all`, the context and page from `Browser.new_context!/2` and `BrowserContext.new_page!/1` in `setup`. It imports only `test`; call the rest qualified: `Playwright.Test.step/3`, `info/0`, `output_path/1`, `attach/2`, `snapshot_path/2`.
- For setup after the page's, `use Playwright.Case` in your case template's `using` and put the `setup` after it there. A template built from the pieces makes `use Playwright.Test` the first line of its body: a context created before the test is registered raises. A template forwarding its `using opts` pops its own options first: unknown ones raise at compile time.
- Upstream's fixtures: `browser` is `BrowserPool.browser/1`, `playwright` is `BrowserPool.playwright(browser)`, `request` is `APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))`, `testInfo` is `Playwright.Test.info/0` (`info(test_pid)` in `on_exit`), `test.use({ trace: 'on' })` is `use Playwright.Test, trace: :on`, context options are `Browser.new_context!(browser, opts)` or config `context_options`, `projects` are ExUnit's `parameterize:` over `browser_name`.
- `BrowserPool` is upstream's worker model. A worker is one driver and one browser of one set of options (`browser_name`, `launch_options`, `connect_options`, `driver`, `on_start`), held by the module (`setup_all`) or test that calls `browser/1`, reused after a passing scope and replaced after a failing one. At most `workers` run at once; other modules wait inside `browser/1` at no cost, so leave ExUnit's `max_cases` alone. A module's tests run one after another: prefer many small `async: true` modules. Set up each new driver with `on_start: &MyApp.Selectors.register/1` (a capture, not a closure).
- Contexts a test creates on a pooled browser get Playwright Test's defaults (`locale: "en-US"`, a 1280x720 viewport, `color_scheme: :light`, ...), then config `context_options`, then the call's options; they are recorded, and closed after the test if left open. A context created in `setup_all` or on a driver you started yourself gets no defaults and no recording.
- In a test, actions and navigations have no timeout of their own (`action_timeout` and `navigation_timeout` default to `:infinity`): ExUnit's test timeout (60 s; `@tag timeout:`, `mix test --timeout`) bounds them. Just before it, the test's contexts close, so a stuck call fails with "Test timeout of 60000ms exceeded." and its call log. To fail sooner, set `action_timeout` and `navigation_timeout` (ms) in config. For `Page.pause/1` or `PWDEBUG=1`, tag the test `@tag timeout: :infinity` or run `mix test --trace`.
- `trace`, `screenshot` and `video` come from config, then `use Playwright.Test`'s options, then `@moduletag`, `@describetag` and `@tag`, each over the one before. `trace` and `video`: `:off` (default), `:on`, `:retain_on_failure`, `:on_first_retry`, `:on_all_retries`, `:retain_on_first_failure`, `:retain_on_failure_and_retries`; `screenshot`: `:off`, `:on`, `:only_on_failure`, `:on_first_failure`; also `true`, `false`, or options with `:mode` (`trace: [mode: :on, snapshots: false]`). They are reserved tag names; `use Playwright.Test, tags: false` stops tags from setting them.
- Each test writes to its own dir under `test-results/` (`trace.zip`, `test-failed-1.png`, `video.webm`). A failed test also gets `error-context.md` (its errors, source and an aria snapshot of its page): read it first. Open a trace with `mix playwright.cli show-trace <path>`.
- ExUnit has no retries: `mix test --failed` is upstream's retry (`Playwright.Test.info().retry` is 1), so `trace: :on_first_retry` with `mix test || { [ $? -eq 2 ] && mix test --failed; }` traces only the rerun of failures.
- `Playwright.Test.step "log in" do ... end` (`Test.step` under `Playwright.Case`), or `step(title, fun, opts)`, is `test.step` and returns the body's value. In a helper, pass `box: true` so a failure points at the helper's caller. It takes `:box`, `:location`, `:params` and `:subtitle`, not `:timeout`. `step_skip/3` is `test.step.skip`.
- `Expect.to_have_screenshot!/2` and `Expect.to_match_aria_snapshot!/3` resolve `name:` next to the test file: `test/sign_up_test.exs-snapshots/home-<platform>.png` for `name: "home.png"`. Without `name:`, the snapshot is named after the test and its count: `signs-up-1-<platform>.png`, `signs-up-1.aria.yml`. A missing snapshot is written and fails the test at the end of its body: commit it.
- `Expect.soft/1` (`expect.soft`), and errors raised in route handlers and listeners, fail the test at the end of its body. Handlers and listeners run with the test in `$callers`, as a `Task` does.
- Not supported: runtime `test.skip`, `test.fail`, `retries`, `webServer`, the HTML reporter. Use ExUnit tags, `mix test --failed`, and start the app in `test_helper.exs`.

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
