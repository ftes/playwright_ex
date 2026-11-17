# Changelog for v1

1.x is a statement-by-statement port of Playwright's JavaScript client. It needs Elixir 1.18 or
later (CI tests down to OTP 27). Its major.minor is Playwright's and the patch is ours: depend on
`~> 1.65.0`. Upgrading from 0.16: read the [upgrading guide](guides/upgrading.md).

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
0.16 APIs are gone. The [upgrading guide](guides/upgrading.md) covers every change. From before
0.16, also read the sections up to 0.16.

## [Unreleased]

Drives [Playwright 1.65.1](https://github.com/microsoft/playwright/releases/tag/v1.65.1), on
Node 26.13.1. No API changes.

### Added

- **RC only:** `use Playwright.Test` (and `use Playwright.Case`) takes `context_options:`,
  Playwright Test's `test.use({ locale: 'de-DE' })`: the options, or a function of the test's
  context (`&Mod.fun/1`, e.g. over your `parameterize:` values), over the config's per key, under
  the call's, for every context of the module's tests (#257). A `nil` option there or in the
  config falls back to the default under it, as upstream skips `undefined` ones.
- **RC only:** `use Playwright.Case` also aliases `Playwright.Keyboard` and `Playwright.Mouse`, so
  `Keyboard` and `Mouse` in such a module now resolve to Playwright's modules.

### Fixed

- `mix playwright.install` and `mix playwright.cli` failed with "module :public_key is not
  available" when run before the project was compiled (e.g. right after `mix deps.get` in CI).
- Contexts and request contexts created in a module's `setup_all` get the context defaults, the
  config's `context_options` (`base_url` too) and timeouts, as Playwright Test's `beforeAll`
  does, and each test records those still open in its trace and screenshots (#257).
- A context created in `setup_all` before `use Playwright.Test` registered the module (a case
  template's own `setup_all` with the `use` only in its `using`, or a `setup_all` above the
  module's `use`) makes the module's `setup_all` raise, naming the fix, as such a context in
  `setup` already does.
- A module's `setup_all` that hangs fails past ExUnit's timeout of the module, with
  `"setup_all" hook timeout of 60000ms exceeded.`, as Playwright Test's `beforeAll` hook
  times out (#257).

## [1.65.0-rc.1] 2026-11-16

Drives [Playwright 1.65.0](https://github.com/microsoft/playwright/releases/tag/v1.65.0). The
[upgrading guide](guides/upgrading.md) has the recipe for each breaking change.

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
  dismissed. See [Behaviour changes](guides/upgrading.md#behaviour-changes).
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
  events and waiting, network, debugging and CI, concurrency, upgrading from 0.16.

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
