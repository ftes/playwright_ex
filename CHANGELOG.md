# Changelog for v1

1.x is a statement-by-statement port of Playwright's JavaScript client. It needs Elixir 1.18 or
later (CI tests down to OTP 27). Its major.minor is Playwright's and the patch is ours: depend on
`~> 1.65.0`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## The JS-client port

The client ports the official JS client at a pinned driver version, and its public API is
generated from Playwright's docs, so [playwright.dev](https://playwright.dev/docs/api/class-playwright)
applies: `page.getByRole(...)` is `Playwright.Page.get_by_role/3`. Calls take the arguments and
options upstream does, with a tuple form (`{:ok, _} | {:error, e}`) and a bang form; waits JS
starts without `await` return a `Playwright.Promise`.

## The rename to `Playwright`

The modules are `Playwright.*` and the app is `:playwright`; the Hex package stays
`playwright_ex`: `{:playwright, "~> 1.65.0", hex: :playwright_ex}`. `hex:` is required,
as `playwright` on Hex is another library.

## `Playwright.Test`

`use Playwright.Test` brings Playwright Test's runner to ExUnit: pooled worker browsers
(`Playwright.Test.BrowserPool`), context defaults, traces, screenshots and videos, steps,
snapshot paths, soft assertions and timeouts. `Playwright.Case` gives each test a `page`. See
[Testing with ExUnit](guides/testing-with-exunit.md).

## Versioning

`1.65.x` drives Playwright 1.65; the patch counts our releases (our fixes and driver patch
bumps), and each release below names its exact driver. Our breaking changes ship only with an
upstream minor, so `~> 1.65.0` is safe.

## Backwards-incompatible changes

1.x is a clean cut from 0.16: the guid-based modules, `Selector`, `EventWaiter` and the other
0.16 APIs are gone.

## [Unreleased]

### Added

- `Playwright.Test.info/0` in `setup_all`: the module's `file`, `timeout` and resolved `use`
  options (config, project, module).
- `Playwright.Test.step/2,3` and `step_skip/2,3` in `setup_all`, as `test.step` in
  `beforeAll`: a step returns its body's value and raises its error (a boxed step's where its
  helper is called), unrecorded.
- `Playwright.Test.parameters/1` takes `name:`, upstream's `project.name`: a failed test prints
  the project as `#Playwright.Test.Project<"Mobile Safari">`, not the whole device, and the
  name is the snapshot templates' `{projectName}`.
- `use Playwright.Test` records each `assert` and `refute` as an `expect` step of the test's
  trace, as upstream's `expect` is: `Expect "assert"`, the expression as its subtitle, the right
  side of a comparison or match as its `expected`, a failed one with its error at the test's
  level. They are ExUnit's otherwise, but a function that ends in a failing assertion keeps its
  frame in the stacktrace. Helper modules `import Playwright.Test.Assertions`. Opt out with
  `use Playwright.Test, assert_steps: false`, or the same key in `config :playwright, :test`.
- `headless` and `channel` are worker options of `Playwright.Test` (config, project, module,
  `BrowserPool.browser/1`), set over `launch_options`', as upstream's fixtures.

### Changed

- `on/3`, `once/3`, `wait_for_event` and the other event functions take any string as an
  event, as JS's emitters do (one that never fires: a wait times out); atoms still raise for an
  unknown event.
- **RC only:** `browser_name` and `preserve_output` also take upstream's strings (`"webkit"`,
  `"failures-only"`); an unknown string raises with upstream's message.
- What's ported answers "can I do X?": a summary, an overview of the features by goal
  (automating a browser, in tests or not; writing, configuring, running and debugging tests),
  then each feature's table of what is ported, partly or not, with the reason or the issue.
- **RC only:** **Breaking:** `use Playwright.Test` replaces ExUnit's `assert` and `refute` with
  `Playwright.Test.Assertions`', so a module that imports `ExUnit.Assertions` again after the
  `use`, or another library's `assert/2`, no longer compiles (an ambiguous `assert`). Opt out
  with `assert_steps: false`, or import `Playwright.Test.Assertions, except: [...]` beside it.
- **RC only:** `Playwright.Test.GitHubFormatter` annotates a `mix test --failed` rerun too, as
  upstream's `github` reporter annotates every attempt: a test passing there counts as flaky in
  the rerun's summary, and one failing again gets its error under `Retry #1`. Pass it to both.
- **RC only:** **Breaking:** `config :playwright, Playwright.Test.GitHubFormatter,
  report_slow_tests: ...` is `config :playwright, :test, report_slow_tests: ...`, as upstream's
  top-level `reportSlowTests`, with `false` for none (`nil` is the default there, as for every
  `:test` key); other module keys of `config :playwright` raise.
- **RC only:** **Breaking:** the `:test` config's and `BrowserPool.browser/1`'s `driver:` take
  only `env:`; `executable:`, `node:` and `cache_dir:` are `config :playwright, :driver`'s.
- **RC only:** **Breaking:** `config :playwright, :expect`'s `:to_have_screenshot`,
  `:to_match_aria_snapshot` and `:to_pass` take the matchers' snake_case keys
  (`max_diff_pixels:`, `timeout:`, `path_template:`, `children: :equal`), not JS keys.
- **RC only:** **Breaking:** `Playwright.Test.parameters/1` returns one private key,
  `:"playwright.project"`, holding a `Playwright.Test.Project` (`name`, `use`), not a key per
  option.
- **RC only:** **Breaking:** `Playwright.Driver.install_browsers/2` raises on a failed install,
  as `install/1` does, instead of returning `{:error, {:exit_status, n}}`.
- **RC only:** **Breaking:** `mix playwright.install --force` reinstalls the driver with every
  flag, `--dry-run`, `--list` and `--help` too.
- **RC only:** **Breaking:** errors of the runner, the pool, the driver and the config read
  `<Module.function/arity or config path>: <problem>, expected ...`, keys and values as the
  facade's errors name them (`config :playwright, :test: unknown key tracing, expected one of
  browser_name, ...`, `invalid value 0 for workers, expected a positive integer`); a call outside its
  scope (`BrowserPool.browser/1` past its test, a context before the registration) raises
  `RuntimeError`, bad input `ArgumentError`.
- **RC only:** the internal `Runtime.Api.call/3` is `Runtime.Facade.call/2`, without
  the unused receiver, as are the facade's `async`, `expect` and `matcher` runners.
- **RC only:** `priv/driver_checksums.exs` no longer repeats the driver and Node versions:
  `DRIVER_VERSION` and `NODE_VERSION` alone hold them.
- **RC only:** `Playwright.Test.in_registered_test?/0` is replaced by `in_registered_scope?/0`,
  true in a test or `setup_all`; `info/0` has `test_pid` only in a test.
- **RC only:** **Breaking:** option values are checked only where upstream's config loader
  checks them (`preserve_output`, `workers`, `output_dir`, `report_slow_tests`, a project's
  `name`, `:expect`'s `update_snapshots`, `ignore_snapshots` and `:to_have_screenshot`'s
  `type`), plus `browser_name`, `on_start` and the keys (an unknown key raises, the object
  forms' too); others pass as given, as upstream's. `trace`, `screenshot` and `video` take no
  `true`/`false`, an unknown mode records nothing, a keyword list without `:mode` is `:off`,
  and `:retry_with_trace`/`:retry_with_video` are `:on_first_retry`. `test_id_attribute: ""`
  sets none, as upstream's `if (testIdAttribute)`.
- **RC only:** **Breaking:** a duplicated key no longer raises: the later wins, as in JS's
  spread, in `use Playwright.Test`, `Test.use/1`, `Test.parameters/1` and the keyword lists
  they take (`trace: [mode: :on, mode: :off]` is off, `connect_options`), in the config's
  (`driver`, `report_slow_tests`, `config :playwright, :expect` and its matchers'), and in the
  options of `Playwright.Supervisor.start_link/1` and `child_spec/1`, `step/3`, `attach/2` and
  `snapshot_path/2`.
- **RC only:** **Breaking:** `@describetag`/`@tag Test.use(...)` with `browser_name`,
  `default_browser_type` (a device's), `launch_options` or `connect_options` raises when the
  module compiles a test of the `test` macro under it, with upstream's "Cannot use({ ... }) in
  a describe group, because it forces a new worker" message ("in a test" for a `@tag`), instead
  of dropping a device's browser. `@moduletag Test.use(...)` takes them, as upstream's top-level
  `test.use`. A test's worker is its module's (its `use`, then its `@moduletag`s, the later per option), so a
  test the check doesn't see (a doctest, a bare `ExUnit.Case.test`) gets the module's too.
- **RC only:** **Breaking:** `info/0`, `output_path/1`, `attach/2` and `snapshot_path/2`
  outside their scope raise upstream's "... can only be called while test is running";
  `output_path/1` takes path segments too and raises upstream's message for a path outside the
  output dir (a `RuntimeError`).
- **RC only:** **Breaking:** `Playwright.Test.info/0`'s `close_deadline` is `deadline`
  (upstream's `testInfo._deadline()`, when the test's contexts close); ExUnit's raw kill time
  is gone.
- **RC only:** **Breaking:** `retry` is 1 under `mix test --failed`, else 0, its dir always
  `-retry1`, no longer counted from earlier `-retryN` dirs.
- **RC only:** `Playwright.Test.GitHubFormatter` labels a test by its project's name only, not
  by every `parameterize:` value, and a slow file's annotation is `[project] › file`, as
  upstream's.
- **RC only:** `__options__/1` is out of HexDocs, as are the selector builders of
  `Isomorphic.LocatorUtils`: both are marked `library_api: true` in their docs metadata,
  internal but stable for libraries that build on them, changed only with a CHANGELOG note.

### Fixed

- **RC only:** `add_cookies`, `storage_state:` and `set_storage_state` check their keys
  against the protocol's: a snake_case `http_only:` raises instead of being dropped. Errors
  name the argument and list index (`cookies[0].http_only`).
- **RC only:** a `multipart` file's keys are checked as other nested objects' are: `mime_type:`
  raises, where the client failed treating the map as a stream.
- **RC only:** option and field errors name keys bare: `unknown option x, expected one of
  y, z` (was `unknown option :x, expected one of :y, :z`), `for opt` (was `for :opt`).
- **RC only:** `mix playwright.install` forwards a `--` to `playwright install` (rc.2 raised on
  it).
- **RC only:** `get_by_role` and `to_have_role` specs and docs take roles as strings too, also
  those Playwright's `AriaRole` lacks (`"mark"`), as JS does; locator descriptions print those
  as strings, not atoms that raise.
- **RC only:** `Route.fulfill`, `abort` and `continue` in a route handler have the handler's
  call site in the trace, which a tail call such as `fn r -> Route.abort!(r) end` doesn't keep
  (BEAM drops its frame).
- **RC only:** a boxed `Playwright.Test.step ... do` is located where its helper is called, as
  the `fn` form and upstream's are, not at its own line in the helper.

## [1.65.0-rc.2] 2026-11-18

Drives [Playwright 1.65.1](https://github.com/microsoft/playwright/releases/tag/v1.65.1), on
Node 26.13.1. No upstream API changes.

### Added

- `Playwright.Promise.all/1`, `race/1` and `any/1`, as JS's `Promise.all`, `Promise.race` and
  `Promise.any` (with `Playwright.AggregateError`).
- A warning when the connection has waited 5 s for one listener or route handler, which stalls
  every page on it: it names the listener, shows where it waits and points to the fix
  ([Concurrency](guides/concurrency.md#no-blocking-work-in-listeners)).
- `use Playwright.Test` (and `use Playwright.Case`) takes the context options as
  options of their own, Playwright Test's `test.use({ locale: 'de-DE' })`: `use Playwright.Case,
  locale: "de-DE"`, over the config's per option, under the call's, for every context of the
  module, its `setup_all`'s included (#257). Any option a layer (config, project, module
  `use`, tags) gives as `nil` resets it to the layer under (the project's, the config's or the
  default), as upstream's `undefined`; a call's own `nil` of a context option or
  `connect_options` is passed as given.
  `context_options:` is upstream's `contextOptions`, for the other options of `new_context`,
  under an option of its own, so flat keys are the upstream-shaped form (`config :playwright,
  :test, locale: "de-DE"`). The config takes both too (`config :playwright, :test, base_url:
  "..."`). `Playwright.Test.config().context_options` holds only the bag, not the options of
  their own: a library that read options from it should read the test's resolved options with
  `Playwright.Test.info().use`.
- `Playwright.Test.use/1` gives a describe block or a test its options, as
  Playwright Test's `test.use` in a `test.describe`: `@describetag Test.use(timezone_id:
  "Europe/Berlin")`, `@tag Test.use(trace: :on)`. They layer per option, over the module's.
- `Playwright.Test.parameters/1` is a project for `parameterize:`, Playwright
  Test's `projects: [{ use }]`: its options are over the config's and under the module's, for
  every context of the module's run.
- `browser_name`, `launch_options` and `connect_options` are options of `use
  Playwright.Test` and of `Test.parameters/1`, and the defaults of the module's
  `BrowserPool.browser/1` calls. Without a `browser_name` (in the config either), a device's
  `default_browser_type` picks the browser, as upstream's `browserName` defaults to
  `defaultBrowserType`.
- `Playwright.Case` puts `browser_name`, Playwright Test's `browserName` fixture, in the context
  of `setup_all` and the tests: the module's browser, `:chromium`, `:firefox` or `:webkit`.
- `action_timeout` and `navigation_timeout` are options of `use Playwright.Test`,
  `Test.use/1` and `Test.parameters/1` too.
- `Playwright.device/1` and `Playwright.devices/0`, Playwright's device
  descriptors as static data (upstream's `import { devices }`), so a device works at compile
  time, spread as upstream's `...devices['iPhone 13']`: `use Playwright.Test,
  Playwright.device("iPhone 13")`, `@moduletag Test.use(Playwright.device("Pixel 7"))`,
  `Test.parameters(Playwright.device("Pixel 7"))`. A device is a keyword list of options, so the
  config takes it as it is: `config :playwright, :test, Playwright.device("Desktop Chrome")`,
  and a later key overrides its option, as upstream's `{ ...devices['iPhone 13'], viewport }`:
  `Playwright.device("iPhone 13") ++ [viewport: ...]`. The driver's `Playwright.devices/1` remains, with maps.

### Changed

- **RC only:** **Breaking:** the tags `trace`, `screenshot` and `video` no longer set the
  recording modes, and `use Playwright.Test, tags: false` is gone (an unknown option now):
  write `@tag Test.use(trace: :on)` for `@tag trace: :on`, likewise for `@describetag` and
  `@moduletag`. Only `Test.use/1`'s keys are read, so tags named as options are yours. A
  leftover plain tag is ignored silently, with no error, no warning and no recording: search for
  them (`rg "@(module|describe)?tag[ (\[][^(]*\b(trace|screenshot|video):"`) and write `@tag
  Playwright.Test.use(trace: :on)`.
- **RC only:** **Breaking:** `mix playwright.install` forwards its args to `playwright install`
  as they are, without `--`: `mix playwright.install chromium --with-deps`. A `--` now raises,
  naming that fix.
- **RC only:** **Breaking:** `mix playwright.install --force` also reinstalls the browsers, as
  it's forwarded to `playwright install`.
- **RC only:** **Breaking:** `mix playwright.install --no-browsers` with other args than `--force`
  raises.
- **RC only:** `Expect.to_pass!/2` returns the callback's value from the attempt that passed,
  which JS assigns to an outer `let`. **Breaking:** `Expect.to_pass/2` returns `{:ok, value}`,
  not `:ok`.
- **RC only:** **Breaking:** a context created in `setup_all` before `use Playwright.Test`
  registered the module (a case template's own `setup_all` with the `use` only in its `using`,
  or a `setup_all` above the module's `use`) makes the module's `setup_all` raise, naming the
  fix, as such a context in `setup` already does. So does a `BrowserPool.browser/1` call there,
  or in `setup` before the test's registration, as it would miss the module's worker options.
- **RC only:** **Breaking:** contexts and request contexts created in a module's `setup_all` (or
  a process with it in `$callers`) get the context defaults and the config's `context_options`
  (`base_url` too), as Playwright Test's `beforeAll` does (#257). A context gets the config's
  `action_timeout` and `navigation_timeout`, a request context `timeout:` the `action_timeout`
  (`0` for `:infinity`) and no navigation timeout: no limit by default, where they had the
  client's 30 s.
- **RC only:** **Breaking:** a module's `setup_all` callbacks fail past ExUnit's timeout of the
  module (`@moduletag timeout:`, else ExUnit's `timeout`), with `"setup_all" hook timeout of
  60000ms exceeded.`, as Playwright Test's `beforeAll` hook times out (#257). A longer
  `setup_all` needs a `@moduletag timeout:`. A failed `setup_all`'s pooled browsers reset at the
  module's end, as a failed test's do.
- **RC only:** **Breaking:** `use Playwright.Case` also aliases `Playwright.Keyboard` and
  `Playwright.Mouse`, so `Keyboard` and `Mouse` in such a module resolve to Playwright's
  modules; alias your own module after the `use` (`alias MyApp.Keyboard`) to keep it.
- **RC only:** **Breaking:** an option of the config's `context_options` given as `nil` falls
  back to Playwright Test's default (`locale: nil` is `en-US`), as upstream's `undefined`, not to
  the client's.
- **RC only:** a handle of the wrong class (a `Locator` passed to `Page.get_by_test_id/2`) fails
  in the facade function, whose clause matches its struct, not in `Playwright.Runtime.Heap.key/2`.
- **RC only:** a string that is not UTF-8 (`Route.fulfill!(route, body: png)`) fails with a hint
  to pass bytes as `{:binary, bytes}`, not only "Message cannot be encoded as JSON".
- **RC only:** a matcher's unknown `message:` option points to `Expect.message/2` (JS
  `expect(x, message)`), for the matcher as called.
- **RC only:** an error a listener or route handler raises in a `Playwright.Test` test fails
  the test and stops it at once, as Playwright Test's worker does, where it failed only at the
  end of the body (a test hung on a dialog its failed `:dialog` listener left open). The test's
  process exits with the error; later such errors are dropped. Unlike Playwright Test, its
  failure screenshots are taken at teardown, after its `on_exit` callbacks, and such an error
  after the body ended is still only logged. A test that traps exits isn't stopped.
- **RC only:** a failed test's "Trace of ..." hint prints after the run, below ExUnit's summary:
  above its own failure it read as the previous failure's.

### Fixed

- **RC only:** `mix playwright.install` and `mix playwright.cli` failed with "module :public_key
  is not available" when run before the project was compiled (e.g. right after `mix deps.get` in
  CI).

## [1.65.0-rc.1] 2026-11-16

Drives [Playwright 1.65.0](https://github.com/microsoft/playwright/releases/tag/v1.65.0).

### Changed
- **Breaking:** rewritten as a port of Playwright's JS client, its API generated from Playwright's
  docs: structs in place of guids, locators in place of `Selector`, `on/3` and `expect_*` in
  place of `subscribe/2` and `EventWaiter`, exceptions named after the JS errors.
- **Breaking:** `PlaywrightEx` is renamed `Playwright` and the app `:playwright`; the Hex package
  stays `playwright_ex`, so the dependency needs `hex: :playwright_ex`. Move every library that
  uses PlaywrightEx in the same bump.
- **Breaking:** the client installs its pinned driver (Node and `playwright-core`) on first start
  or with `mix playwright.install`, in place of the npm `playwright` package. `executable:` takes
  a Playwright 1.65 CLI.
- **Breaking:** behaviour follows upstream: unknown options raise, nested maps use the JS keys
  (`sameSite`), JS `null` is `:null`, tuple forms return `{:error, e}` only for Playwright's
  errors, failed bang matchers raise `Playwright.ExpectError`, dialogs without a listener are
  dismissed.
- **Breaking:** Playwright 1.65's own: actions wait for the element to be not inert, cookie
  matching follows RFC 6265, proxy credentials only answer proxy challenges, and text the browser
  doesn't render leaves accessible names and aria snapshots.
- Versions follow Playwright's: major.minor is Playwright's, the patch ours, so 0.16 is followed
  by 1.65.0.
- Licensed under Apache-2.0 (was MIT), as the port of Playwright's client; 0.16 and earlier stay
  MIT.
- No runtime dependencies: `nimble_options`, `mime` and `websockex` are gone.

### Removed
- **Breaking:** `launch_browser/2`, `subscribe/2`, `send/2`, `EventWaiter`, `Selector`,
  `JsLogger`, the `connection:` option, the supervisor's `timeout:`, `js_logger:`, `ws_endpoint:`
  (use `BrowserType.connect/3`) and `:fail_on_unknown_opts`, and `Tracing`'s `coverage:`.

### Added
- Playwright's whole client API, with a tuple and a bang form per call: `Playwright.Promise` for
  calls JS starts without `await` (`Promise.async/1`), `Playwright.RegExp` for JS regexes,
  `AbortController` signals, API requests, `CDPSession`, `Clock`, `Credentials` and the rest.
- User callbacks (route handlers, listeners, exposed functions, locator handlers) run with the
  registering process's `$callers`, so the Ecto sandbox, Mox and `Req.Test` find the test.
- `Playwright.Test`: Playwright Test's runner for ExUnit, with pooled worker browsers
  (`Playwright.Test.BrowserPool`), context defaults, traces, screenshots and videos, steps,
  snapshot paths, soft assertions, timeouts and `info/0`. `Playwright.Case` gives each test a
  `page`; `Playwright.Test.GitHubFormatter` is the `github` reporter.
- `Expect.to_pass/2`, `Expect.poll/3`, `Expect.soft/1` and `Expect.message/2`, beside upstream's
  matchers.
- `mix playwright.install` (`--no-browsers` for the driver only) and `mix playwright.cli`.
- `__options__/1` on the facade modules, for wrappers (its shape is unstable).
- `usage-rules.md` ships in the package: `usage_rules: [:playwright]`.
- Guides: getting started, from playwright.dev to Elixir, cheatsheet, testing with ExUnit,
  events and waiting, network, debugging and CI, concurrency.

## 0.16 and earlier

## [0.16.0] 2026-11-04

### Added
- `BrowserContext.credentials_install/2`, `credentials_create/3`, `credentials_get/2` and
  `credentials_delete/3` wrap Playwright's virtual WebAuthn authenticator (`context.credentials`).

## [0.15.0] 2026-10-17

### Added
- `Tracing.tracing_start/2` accepts `coverage: true` to collect Istanbul coverage into the trace.
- Virtual WebAuthn credentials round-trip `sign_count` in storage state.

### Changed
- Require Playwright 1.64 or newer. Older local drivers are rejected, and remote
  connections advertise 1.64. The bundled development dependency is 1.64.1.

### Fixed

- Clear request interception after a timed-out installation, including queued requests.
- Skip route callbacks when a required subscription fails and release partial subscriptions.

## [0.14.0] 2026-10-02

### Added

- Page/context request routing with one driver-matched glob handler per target,
  page-first precedence, and linked callback failures.
- `Route.fulfill/2` with binary, JSON, and local-file bodies, plus `abort/2`,
  `continue/2`, and removal that cancels active callbacks. Isolated error messages
  are available with `on_error: :message`.
- Optional `:mime` dependency enables content-type inference for file fulfillment;
  without it, files default to `application/octet-stream`.
- `Browser.new_context/2` accepts `service_workers: "block"` for routing tests.

## [0.13.0] 2026-10-01

### Added

- `Connection.unsubscribe_sync/3` removes channel delivery and managed event
  ownership before returning. Both synchronous and asynchronous removal leave
  other recipients and explicit subscriptions intact.
- Page `:frame_navigated` events cover main and child frames, including frames
  created after registration, through existing subscriptions and `EventWaiter`.

## [0.12.1] 2026-09-21

### Fixed

- Restore `js_logger: false` as an alias for `nil` to disable JavaScript logging.
  Console messages and page errors no longer crash the connection with `false`.

## [0.12.0] 2026-09-16

### Added

- Add `Locator.evaluate/2`, with strict lazy resolution under the locator timeout, unlimited JavaScript evaluation and disposal, and Playwright JS cleanup error precedence.
- Add `ElementHandle.evaluate/2` and `dispose/2`.
- Add `Frame.expect_result/2` to retain assertion diagnostics; `expect/2` keeps its boolean behavior.

## [0.11.0] 2026-09-15
### Added
- `Frame.snapshot/2` for an atomic read of the cached URL, document request, and
  client-generated document identity.
- Optional `EventWaiter` transforms that run on capture inside the waiting task.
- Managed opt-in event subscriptions: the first waiter enables an event and the
  last releases it. Explicit channel subscriptions remain active independently.
- `Frame.document_request/2` to read the committed document's request without
  event subscriptions, preserving it across same-document navigation.
- `Request.response/2` to retrieve a request's response without subscribing to
  response events, returning `nil` when the request fails without a response.

### Changed
- Frame URL/load-state waits use a separate task for each caller. The connection
  caches current frame state; per-frame recorder processes are removed. Public
  results stay synchronous, and URL predicate errors affect only that caller.

### Fixed
- Download waiters validate their own options, excluding raw event transforms and
  subscription overrides to preserve the `Download` result.
- Clean up abandoned frame waits when callers exit and discard recorded frame
  state when the connection closes.

## [0.10.0] 2026-09-15
### Added
- Download handles with browser-provided filename and URL, reusable through
  `Download.from_event/2`, `Download.save_as/3`, and explicit `Download.delete/2`.
- `Page.expect_download/2` and `Page.await_download/1` for explicit
  arm/action/await download capture, with an optional predicate on download metadata.
- `EventWaiter.arm/3`, `await/1`, and `cancel/1` for one-shot protocol events,
  using linked tasks and ref-tagged replies, with synchronous registration,
  one deadline from arming, optional event predicates, and owner/connection
  lifecycle handling. `:infinity` disables the event timeout.

### Changed
- **Breaking:** `timeout: 0` now means no waiting throughout the client. Protocol
  commands time out without being sent; frame URL/load-state waits check cached
  state once. Replace `timeout: 0` with `timeout: :infinity` where unlimited
  waiting was intended.
- Missing connections, normal stops, supervisor shutdowns, and response timeouts
  return error results at the connection boundary. Other process exits and URL
  predicate bugs propagate instead of being converted to ordinary error results.

### Fixed
- Discard unrelated protocol events from event waiters without extending their
  deadline, preventing mailbox growth while waiting on busy channels.
- Support `:infinity` in frame URL/load-state waits and keyboard actions without
  timeout arithmetic errors. Keyboard delays cannot extend a zero timeout.
- Artifact saves share one timeout across stream reads, clean up failed
  transfers, create parent directories, and preserve existing destinations on
  failure. Stream cleanup runs in an `after` block and preserves the transfer
  result. Saving leaves the source artifact available to other readers.
- Support `:infinity` command timeouts using Playwright's zero-timeout wire value.

## [0.9.0] 2026-09-08
### Added
- Typed local and `PlaywrightEx.FilePayload` in-memory uploads through
  `Frame.set_input_files/2` and the new `ElementHandle.set_input_files/2`,
  including file-chooser handles and empty selections. #80
- Playwright 1.63 APIs for structured ARIA snapshots, OPFS and WebAuthn storage
  state, browser-context event subscriptions (including `dialog_closed`),
  visible and cross-frame selectors, and expanded browser launch options.

### Changed
- Require Playwright 1.63 or newer and use it as the sole protocol baseline.
  Older local drivers are rejected, and remote connections advertise 1.63 and
  reset their protocol state after disconnects.
- Adopt Playwright 1.63's HTTP-credential and tracing wire formats while
  retaining the existing map-or-list public credential API.

### Fixed
- Align channel options, events, and results with Playwright 1.63, including
  headers, enums, cookies, frame polling and selection, subscriptions, tracing
  modes, void results, and protocol logs.
- Correct channel lifecycle tracking across initialization, creation, adoption,
  disposal, and page/frame ownership; console and page errors now reach
  subscribers.
- Support every Playwright 1.63 serialized-value variant without altering
  opaque JSON keys or creating atoms from untrusted data.
- Harden port framing, stderr isolation, and remote artifact cleanup.

## [0.8.0] 2026-08-27
### Changed
- Require Playwright 1.62 or newer. Command timeouts are now sent as protocol
  metadata, matching the Playwright 1.62 driver contract. The bundled
  development dependency is updated to 1.62, and the local port transport warns
  when an older driver is detected.
- Preserve both the protocol error and `error_details` in
  `Page.expect_screenshot/2` errors as `{:error, {error, error_details}}`. #58

### Removed
- Support for the Playwright 1.60 expectation response format. #58

## [0.7.1] 2026-06-19
### Added
- Warn about playwright version < 1.61.0 (port transport only). Commit [cd9e98e]

## [0.7.0] 2026-06-16
### Fixed
- Support the Playwright 1.61 `Frame.expect` wire contract. 1.61 stopped
  returning `%{matches: boolean}` and now signals the assertion outcome by
  success-vs-error: a non-match returns a protocol error carrying
  `error_details`. `Frame.expect/2` now yields a plain `{:ok, boolean}` under
  both 1.60 and 1.61, so `phoenix_test_playwright`'s `assert_has`/`refute_has`
  keep working. `Serialization.deserialize_arg/1` also raises a
  descriptive error on unknown serialized shapes instead of a bare
  `CaseClauseError`. Commit [d6d9ddc], #57, [@oliver-kriska]

## [0.6.1] 2026-06-16
### Added
- Accept all supported options to `Frame.goto`. Commit [8e96071], #49, [@s3cur3]
- `Page.expect_screenshot/2`. Commit [929b90e], #56, [@Wigny]

### Fixed
- Handle `viewport: nil` to disable default viewport. Commit [8139523], #46

## [0.6.0] 2026-05-05
### Added
- `PlaywrightEx.Artifact` for saving and deleting Playwright artifact files. Commit [8178f7c]
- `PlaywrightEx.BrowserContext` clock helpers: `clock_install/2` and `clock_fast_forward/2`. Commit [7b6b977], #30
- `PlaywrightEx.BrowserContext.storage_state/2` and `PlaywrightEx.BrowserContext.set_storage_state/2`. Commit [bcb5b16], #35, [@probably-not]
- `:env` option for local Port transport environment variables. Commit [0095f7f], #34, [@probably-not]
- `PlaywrightEx.Page.bring_to_front/2` to activate a page tab. Commit [7348fa4], #32
### Removed
- Frame `url/2` helper, which is not a supported Playwright server operation. Commit [9490384]
### Fixed
- `:ignore_https_errors` now serializes to Playwright's required `ignoreHTTPSErrors` casing. Commit [80f28be], #45

## [0.5.0] 2026-03-06
### Added
- `PlaywrightEx.Frame`: `is_visible/2`, `is_checked/2`, `is_disabled/2`, `is_enabled/2`, `is_editable/2`, `get_attribute/2`, `input_value/2`, `text_content/2`, `inner_text/2`, `focus/2`, `dispatch_event/2`, `wait_for_function/2`. Commit [8684fda], #22, [@oliver-kriska]
- `PlaywrightEx.Frame.wait_for_selector/2`: `state` and `strict` options. Commit [8684fda], #22, [@oliver-kriska]
- `PlaywrightEx.BrowserContext.add_init_script/2` and `PlaywrightEx.Page.add_init_script/2`. Commit [74e93f6], #23, [@probably-not]
- `PlaywrightEx.unsubscribe/2` and connection-level unsubscribe support. Commit [319a69b]
- `PlaywrightEx.Frame.wait_for_load_state/2` and `PlaywrightEx.Frame.wait_for_url/2` with event-based navigation waiting. Commit [027b0fa]
- Per-frame event recorder process to keep waiter subscriptions continuous across waits. Commit [027b0fa]
- `PlaywrightEx.Page.expect_url/2` for explicit URL expectations on pages. Commit [027b0fa]
- Regex support in argument serialization/deserialization using protocol-native `{r: %{p, f}}` values. Commit [027b0fa]
- `PlaywrightEx.Page.reload/2` to reload current page. Commit [f3c5b21], #25, [@wjrtz]
### Fixed
- `PlaywrightEx.Frame.wait_for_selector/2`: crash when `state` is `"hidden"` or `"detached"` (result has no element). Commit [8684fda], #22
- `PlaywrightEx.BrowserContext.add_init_script/2` and `PlaywrightEx.Page.add_init_script/2`: use `source` parameter name required by Playwright protocol (instead of `content`). Commit [3fd54a1]
- URL regex expectations now send Playwright-compatible string regex flags. Commit [027b0fa]
- Frame waiter exit errors preserve normalized reason atoms in error metadata. Commit [027b0fa]

## [0.4.0] 2026-02-09
### Added
- Support remote Playwright server via websocket. Commit [63fc6eb], [@carsoncall]

## [0.3.2] 2026-01-30
### Fixed
- Typespec bugs. Commit [7275ef9]

## [0.3.1] 2026-01-30
### Added
- Tracing groups in preparation for `PhoenixTest.Playwright.step/3`: `PlaywrightEx.Tracing.group/3`. Commit [545bc4d], [@nathanl]

## [0.3.0] 2025-12-24
### Added
- `PlaywrightEx.Page.mouse_move/2`, `mouse_down/2`, `mouse_up/2` for low-level mouse control. Commit [530e362], [@nathanl]
- `PlaywrightEx.Frame.hover/2` for hovering over elements (supports manual drag operations). Commit [530e362], [@nathanl]
### Fixed
- Serialization of args given to `PlaywrightEx.Frame.evaluate/2`. Commit [fecf965], [@nathanl]

## [0.2.1] 2025-11-28
### Changed
- Suppress node.js errors on termination

## [0.2.0] 2025-11-19
### Changed
- Add typespecs and docs
- Make channel function input and output consistent

## [0.1.2] 2025-11-14
### Changed
- Extract `PlaywrightEx.Supervisor` (spawn `PortServer` outside of `Connection`)

## [0.1.1] 2025-11-14
### Fixed
- Memory leak: Free memory when playwright resource is destroyed (handle `__dispose__` messages)

## [0.1.0] 2025-11-13
### Added
- First draft

[@nathanl]: https://github.com/nathanl
[@carsoncall]: https://github.com/carsoncall
[@oliver-kriska]: https://github.com/oliver-kriska
[@probably-not]: https://github.com/probably-not
[@wjrtz]: https://github.com/wjrtz
[@s3cur3]: https://github.com/s3cur3
[@Wigny]: https://github.com/Wigny

[530e362]: https://github.com/ftes/playwright_ex/commit/530e36
[fecf965]: https://github.com/ftes/playwright_ex/commit/fecf965
[545bc4d]: https://github.com/ftes/playwright_ex/commit/545bc4d
[7275ef9]: https://github.com/ftes/playwright_ex/commit/7275ef9
[63fc6eb]: https://github.com/ftes/playwright_ex/commit/63fc6eb
[74e93f6]: https://github.com/ftes/playwright_ex/commit/74e93f6
[8684fda]: https://github.com/ftes/playwright_ex/commit/8684fda
[3fd54a1]: https://github.com/ftes/playwright_ex/commit/3fd54a1
[319a69b]: https://github.com/ftes/playwright_ex/commit/319a69b
[027b0fa]: https://github.com/ftes/playwright_ex/commit/027b0fa
[f3c5b21]: https://github.com/ftes/playwright_ex/commit/f3c5b21
[7b6b977]: https://github.com/ftes/playwright_ex/commit/7b6b977
[7348fa4]: https://github.com/ftes/playwright_ex/commit/7348fa4
[9490384]: https://github.com/ftes/playwright_ex/commit/9490384
[bcb5b16]: https://github.com/ftes/playwright_ex/commit/bcb5b16
[0095f7f]: https://github.com/ftes/playwright_ex/commit/0095f7f
[80f28be]: https://github.com/ftes/playwright_ex/commit/80f28be
[8178f7c]: https://github.com/ftes/playwright_ex/commit/8178f7c
[8e96071]: https://github.com/ftes/playwright_ex/commit/8e96071
[929b90e]: https://github.com/ftes/playwright_ex/commit/929b90e
[8139523]: https://github.com/ftes/playwright_ex/commit/8139523
[d6d9ddc]: https://github.com/ftes/playwright_ex/commit/d6d9ddc
[cd9e98e]: https://github.com/ftes/playwright_ex/commit/cd9e98e
