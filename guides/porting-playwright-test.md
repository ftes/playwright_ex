# Porting Playwright Test specs

Most of a spec ports call for call. This guide lists what ExUnit can't host, what isn't ported
yet, and what differs in the rest. Snippets alias `Playwright.{Page, Locator, Expect, ...}`.

## Not supported

Playwright Test features ExUnit can't host, or that ExUnit and Elixir already cover
([#210](https://github.com/ftes/playwright_ex/issues/210)):

| Playwright Test | why | instead |
|---|---|---|
| runtime `test.skip(condition)` | ExUnit can't skip a running test, and its filters don't see `parameterize:` values | a tag known before the run (`@tag skip: ...`, `--exclude`), or an `if` around the body (reported as passed) |
| `test.fixme`, `test.slow` | ExUnit has tags for both | `@tag :skip`, `@tag timeout: ...` |
| `retries` | ExUnit has no retries in a run | rerun the failures: a `mix test --failed` after a run whose tests failed (exit status 2), see [Retries](test-artifacts.md#retries); the retry modes (`trace: :on_first_retry`, ...) go by it |
| nested or duplicate-name `describe` | ExUnit's `describe` doesn't nest, and its names are unique in a module | a module per outer `describe` (its `beforeEach` a module `setup`, its `beforeAll` the module's `setup_all`, which a `describe` can't have); a `describe` repeated in a loop becomes one `describe` with the loop inside |
| `fullyParallel` | ExUnit runs a module's tests one after another | a module per `describe`; for `fullyParallel: false` on shared state, a `group:` |
| `describe.serial`, `mode: 'serial'` | ExUnit runs a module's tests in random order | one test, with a `Test.step` per test; modules sharing state in the app in one `group:` (see [Setup](testing-with-exunit.md#setup)) |
| `globalSetup`, project `dependencies` | ExUnit has no projects | `test_helper.exs` (see [Logging in once](testing-with-exunit.md#logging-in-once)) |
| asymmetric and value matchers (`expect.objectContaining`, `expect.any(String)`, `toMatchObject`, `toBeCloseTo`, ...) | the jest matchers aren't ported | patterns: `assert %{"id" => id} = hd(list)`, then `assert is_binary(id)`; `assert_in_delta/3` |
| `expect.configure({ timeout, soft })` | the options are the receiver's, not a configured `expect` | the matchers' `timeout:`, `Expect.soft/1` |
| `json`, `junit` reporters | ExUnit formatters cover them | an ExUnit formatter, such as the `junit_formatter` Hex package |
| `list`, `line`, `dot` reporters | ExUnit's output covers them | ExUnit's CLI formatter |
| reporter plugins (monocart coverage, ...) | there are no reporters to plug into | none: `Playwright.Coverage` collects, your code reports |
| `webServer` | `test_helper.exs` starts what a run needs | start the endpoint in `test_helper.exs`, or `server: true` in the test config (see [The app under test](testing-with-exunit.md#the-app-under-test)) |

Not ported yet, the items a spec runs into most ([What's ported](introduction/whats-ported.md) has
the full list; [open an issue](https://github.com/ftes/playwright_ex/issues) if you need one):

- the HTML reporter, with `blob` and `merge-reports` for partitioned runs;
- rebaselining inline aria snapshots into the test source (`--update-source-method`);
- `_defaultLaunchOptions`: a `BrowserType.launch` inside a test doesn't inherit the browser's
  `launch_options`;
- recording `setup_all` contexts per test, and a fresh worker after a failed test: a
  `setup_all` context gets the defaults but no test records it, and its state carries on after
  a failure ([Contexts of `setup_all`](Playwright.Test.html#module-contexts-of-setup_all)).
  Create the context per test, as `Playwright.Case` does;
- function-valued `use` options (Playwright Test's option fixtures, `test.use({ locale: async
  ({}, use) => ... })`): the options are values;
- `test.fail` and annotations (`test.info().annotations`, a trace's `annotations` are `[]`):
  they would be tags of the same kind as `Test.use/1`'s, `@tag Test.fail()` and
  `@tag Test.annotate(...)`
  ([#286](https://github.com/ftes/playwright_ex/issues/286));
- a project's own `outputDir`, `snapshotDir` and `snapshotPathTemplate`: `output_dir`,
  `snapshot_dir` and `snapshot_path_template` are config only
  ([#286](https://github.com/ftes/playwright_ex/issues/286));
- the video's step overlay keeps the title of a process killed inside `step/2,3`, and shows an
  IPv6 host with a zone id as `fe80`.

## What differs

- JS `null` is `:null` (`undefined` is `nil`), and objects from `evaluate` are maps with string
  keys (`result["entry"]["foo"]`). A call that returns `X | null` returns `nil`
  (`Locator.get_attribute!/2` of a missing attribute).
- A JS regex literal PCRE rejects (`/\patched/`: `\p` is `p` in JS without `u`) needs
  `Playwright.RegExp.new/1`, which sends the JS source as it is.
- `elementHandle.evaluate(...)` is `JSHandle.evaluate!(element_handle, ...)`: an `ElementHandle`
  takes the `JSHandle` functions.
- Module-level `let` state reset in `beforeEach` becomes per-test state, returned from `setup` or
  kept in an `Agent` (unlinked when an `on_exit` reads it, see
  [A check after the test](testing-with-exunit.md#a-check-after-the-test)).
- `expect(fn).toPass()` is `Expect.to_pass!/2`, which returns the passing attempt's value: a
  callback that assigns an outer `let` returns it instead (`box = Expect.to_pass!(fn -> ...; box
  end)`). `expect.poll(fn).toBe(x)` is `Expect.poll!(fn, &assert(&1 == x))`, and a call started
  now and awaited later (`const p = locator.evaluate(...)`) is `Playwright.Promise.async/1`.
  `Promise.all([...])` is `Playwright.Promise.all/1` only where a wait or call must start before
  the action; of independent reads or assertions, it is sequential calls or `Task`s (see
  [Plain Elixir first](concurrency.md#plain-elixir-first)).
- The `browserName` fixture is `browser_name` in `Playwright.Case`'s context (`setup_all`'s
  and the test's): `test "...", %{page: page, browser_name: name}`, `:chromium`, `:firefox` or
  `:webkit`.
- The `baseURL` fixture is `Playwright.Test.info().use[:base_url]`. The `request`
  fixture is a request context of its own, `APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))`,
  which in a test gets the test's context options and is disposed of at its end; it is not
  `Page.request/1` (upstream's `page.request`, which shares the page's cookies).
- `addInitScript(fn)` calls the function, but a string is sent as is, so `"() => ..."` only
  defines one: pass `"(#{fun})()"`, or the function's body.
- `expect(locator, 'should be logged in')` is `locator |> Expect.message("should be logged in")
  |> Expect.to_be_visible!()`.
- `reporter: 'github'` is the `Playwright.Test.GitHubFormatter` formatter, which prints only
  annotations: list it next to `ExUnit.CLIFormatter` (see [CI](debugging-and-ci.md#annotations)).
- `test('...', { tag: '@slow' })` and `--grep @slow` are an ExUnit tag (`@tag :slow`, or
  `@moduletag :slow` for the file) and `mix test --only slow`.
- ExUnit runs the modules in a random (seeded) order, so a spec that relies on state another
  file left behind (a user it created) fails now and then: set up the state per test, in `setup`.
- A selector with parentheses can't go in `~s(...)`: use `~s[...]` or a string.
- `test.use({ locale: 'de-DE' })` at a file's top is `use Playwright.Case, locale: "de-DE"`, in a
  `test.describe` it is `@describetag Test.use(locale: "de-DE")` (`@tag` for one test);
  `projects` are `parameterize:` with a `Test.parameters/1` map each
  ([Options, devices and projects](test-options.md)). When the module's context can't be configured enough (values only
  the module's own `setup` computes, as ExUnit runs the case template's `setup` first, or options
  that differ per test), create the context in the test or its `setup`:
  `Browser.new_context!(browser, storage_state: state)`. It still gets the defaults and the
  options of every level, and is recorded.
- A spec that shares one page from `beforeAll` would still pay for `Playwright.Case`'s context
  and page in each test: write the few lines instead, as `Playwright.Case`'s docs show. No test
  records that `setup_all` context (see "Not ported yet" above).

## Coming from Wallaby

Wallaby's queries become locators, and its assertions matchers that wait for the page, so the
`:timer.sleep` calls and retry loops go:

```elixir
# assert_has(session, css(".alert", text: "Saved"))
Page.locator(page, ".alert") |> Locator.filter(has_text: "Saved") |> Expect.to_be_visible!()
# refute_has(session, css(".error"))
Page.locator(page, ".error") |> Expect.not_to_be_visible!()
# Enum.any?(all(session, css("li")), &(Element.text(&1) =~ "Apple"))
Page.get_by_role(page, :listitem) |> Locator.filter(has_text: "Apple") |> Expect.to_be_visible!()
```

Locators are strict, as `assert_has`'s default count of 1 is: a matcher of one element
(`to_be_visible`, `to_have_text` with a string) fails on a locator that matches several, and
`assert_has`'s `count:` is `Expect.to_have_count!/2`. `Element.text` is the rendered text, so a text with CSS `text-transform` needs
`Expect.to_have_text!(locator, "RED", use_inner_text: true)`; `to_have_text!` reads
`textContent`. `fill_in` types key by key, `Locator.fill!/2` sets the value with one `input`
event: for handlers of key events, `Locator.press_sequentially!/3`. For the SQL sandbox, see
[The app under test](testing-with-exunit.md#the-app-under-test).
