# Playwright usage rules

`Playwright` is a 1:1 Elixir port of the Playwright client; `Playwright.Test` brings Playwright
Test's per-test machinery to ExUnit. The API is generated from upstream's docs, so playwright.dev
applies, the Python docs reading closest. Look up a module's details with
`mix usage_rules.docs Playwright.Page` (or `Playwright.Test`, `Playwright.Expect`, ...); the
guides are at hexdocs.pm/playwright_ex.

## Traps

- The Hex package is `playwright_ex`; the app and modules are `Playwright`, so the dep needs
  `hex: :playwright_ex` (see the README for the current version). The Hex package `playwright`
  (hexdocs.pm/playwright) is another library with another API: ignore its docs and examples.
- Don't alias a module of your own named `Playwright` (`alias MyApp.Playwright`): `Playwright.Page`
  then silently resolves to `MyApp.Playwright.Page`. Call yours in full or alias it
  `as: MyPlaywright`; below `alias MyApp.Playwright` in a sorted list, write
  `alias Elixir.Playwright.Page`.
- `timeout: 0` means no timeout, as in Playwright JS, not "don't wait" as `receive ... after 0`:
  write `timeout: :infinity` for none, and never use `0` for an immediate check.
- A Chromium `--enable-features=`/`--disable-features=` in `launch_options: [args: ...]` replaces
  the list Playwright passes (Chromium keeps the last flag): repeat Playwright's features, from
  `chromiumSwitches.ts` at the tag of the package's `DRIVER_VERSION` (for 1.65.1,
  github.com/microsoft/playwright/blob/v1.65.1/packages/playwright-core/src/server/chromium/chromiumSwitches.ts),
  or leave the flag out.
- There is no npm, `package.json`, `playwright.config.ts` or `@playwright/test`:
  `mix playwright.install` installs the driver and browsers, and Elixir config replaces the rest.
  `config :playwright, :test` mirrors `playwright.config.ts` in snake_case: `use` options and the
  top-level keys flat, `expect: [...]` its expect block; `config :playwright, :driver` is the
  driver install, in `config/config.exs`, not `test.exs` or `runtime.exs`: `mix playwright.install`
  usually runs in `:dev` and doesn't read `runtime.exs`.
  Unknown keys raise, and no option reads an environment variable (`PLAYWRIGHT_TEST_BASE_URL`
  neither): read yours in config. The keys are in `Playwright.Test` and `Playwright.Driver`;
  outside a test, read the `:test` config with its defaults through `Playwright.Test.config/0`,
  not `Application.fetch_env!/2`.

## API shape

- Use the facade (`Playwright.Page`, `Locator`, `BrowserContext`, `Expect`, ...).
  `Playwright.Client.*` and `Playwright.Runtime.*` are internal.
- A JS method is a function taking the object first, in snake_case; properties are functions too
  (`Page.keyboard(page)`). Predicates keep Python's names: `Locator.is_visible!/2`, not `visible?`.
- A call JS awaits has two forms: `name` returns `{:ok, value}`, `:ok` or `{:error, exception}`,
  and `name!` returns the value or raises. Use bang forms in scripts and tests, tuple forms where
  failure is an expected outcome. A call JS doesn't await (`Page.url/1`, `Page.locator/3`,
  `Locator.filter/2`) returns a plain value and has no bang form.
- Options come last, with snake_case keys. Nested option values and object arguments are maps with
  the JS keys: `viewport: %{width: 1280, height: 720}`, a cookie's `httpOnly: true`. Unknown keys
  raise.
- `nil` is JS `undefined` and `:null` JS `null`, so an absent value from `evaluate` may be either
  (`obj.missing` is `nil`, `querySelector` with no match `:null`): match both
  (`x in [nil, :null]`), not `x || default`. String enums are atoms (`:no_preference`). Strings
  are literal text or URL globs; use `~r//` for a pattern.

## Locators and assertions

- Follow Playwright's locator priority: `Page.get_by_role/3` with `name:`, then `get_by_label`,
  `get_by_placeholder`, `get_by_text`, `get_by_alt_text` or `get_by_title`, `get_by_test_id`;
  `Page.locator/3` with CSS or XPath last, never by CSS classes or DOM structure. Narrow by
  chaining and `Locator.filter/2`. Locators are strict: an action on several matches fails.
- Assert with `Playwright.Expect`'s web-first matchers, which retry until their timeout:
  `Expect.to_be_visible!(locator)`. `assert Locator.is_visible!(locator)` reads once and races the
  page. An `Expect.poll!` callback that raises fails at once instead of retrying.
- Outside `Playwright.Test`, actions and navigations wait 30 seconds: lower that per
  context (`BrowserContext.set_default_timeout/2`) rather than with a `timeout:` on every call.

## Events and concurrency

- Start a wait before the action that triggers it: `Page.expect_popup!(page, fn -> ... end)`
  (`expect_download!`, `expect_request!`, ...), or `promise = Page.wait_for_event(page, :popup)`,
  act, then `Playwright.Promise.await!(promise)`. `Page.wait_for_event!/3` awaits at once and
  misses what the code before it triggered.
- For JS's call without `await` (`const p = locator.evaluate(...)`), use `Playwright.Promise.async/1`,
  not a `Task`: it returns once its calls are sent, so they come before your next action.
- Otherwise prefer plain Elixir to `Playwright.Promise` (the Concurrency guide lists where it is
  needed): a JS `Promise.all` of independent reads or assertions is sequential calls; reads may
  run in `Task`s awaited with `:infinity`.
- A listener (`on/3`, `once/3`) runs in its own process, and the connection waits for it before
  the next message: keep it short and `send` work elsewhere. A `:dialog` listener must accept or
  dismiss the dialog before asserting.
- `add_init_script` with a function's source and no argument only defines it: wrap it as
  `"(#{fun})()"`.
- Outside `Playwright.Test`, close what you open: a browser or context doesn't close when the
  process that created it exits.

## Testing with Playwright.Test

- `use Playwright.Case, async: true` gives each test a fresh `context` and `page` from a pooled
  browser. Don't start a `Playwright.Supervisor` for the tests' browsers.
- Set options per module, describe or test with `Test.use/1` (`use Playwright.Case` aliases
  `Test`, `Page`, `Locator`, `Expect`, ...): `@tag Test.use(trace: :on)`. A plain
  `@tag trace: :on` sets nothing, silently. Worker options (`browser_name`, launch and connect
  options, a device) go in the module's `use`, a project or the config, not a `@describetag` or
  `@tag`: see `Playwright.Test`'s table of where each option can be set.
- Use `Playwright.device("iPhone 13")` (raises for an unknown name), not
  `Playwright.devices()["iPhone 13"]` (`nil` falls back silently).
- Don't add a `timeout:` per call: in a test, only ExUnit's test timeout bounds actions and
  navigations. Set `action_timeout` in config to fail sooner. Matchers still wait 5 seconds.
- `Playwright.Test.step "log in" do ... end` is `test.step`. `assert` and `refute` are steps too:
  `use Playwright.Test` imports `Playwright.Test.Assertions` in place of ExUnit's. Don't
  `import ExUnit.Assertions` after it; a helper module needs `import Playwright.Test.Assertions`
  (and `import ExUnit.Assertions, except: [assert: 1, assert: 2, refute: 1, refute: 2]` if it
  imports ExUnit's too), or its passed asserts leave no step.
- A check in `on_exit` (Playwright Test's `afterEach`) fails the test for its artifacts and
  `info/1` only through the `on_exit/1,2` `use Playwright.Test` imports, registered after the
  `use` (a later `setup`, or the test), under a name not used before it. Not
  `ExUnit.Callbacks.on_exit/2` called qualified: that failure counts as passed, and its trace is
  dropped. Don't `import ExUnit.Callbacks` after the `use`: a bare `on_exit` call is then
  ambiguous and fails to compile.
- Tracing slows every test it records, most in its DOM snapshots. On CI use
  `trace: :on_first_retry` (records nothing on the first run, only the `mix test --failed`
  rerun: see Retries in the "Artifacts, retries and workers" guide) or `:retain_on_failure`
  (still takes the DOM snapshots in every test; on a pass skips only the merge and the save of
  contexts still open at its end), not `:on`. `trace: [mode: ..., snapshots: false]` drops the
  snapshots' cost, but the kept traces then have no DOM snapshots to inspect.
- A failed test writes `test-results/<test>/error-context.md` (errors, source, an aria snapshot):
  read it first. Open traces with `mix playwright.cli show-trace <path>`.
- To map tests to their trace, screenshots and videos, read the `attachments` of
  `Playwright.Test.JSONFormatter`'s report (or `Playwright.Test.info(test_pid)` in `on_exit`);
  don't rebuild the paths from test names.
