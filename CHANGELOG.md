# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
<!-- and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). -->

Upgrading from 0.16: the [migration guide](guides/migration.md) covers the changes, including
those of the release candidates below. From an earlier release, also read the sections up to 0.16.

## [Unreleased]

### Added
- `PlaywrightEx.Case`: a case template giving each test a `context` and a `page` of the shared
  browser.
- `PlaywrightEx.Test.BrowserPool`: Playwright Test's worker browser. `shared/1` is one browser
  per set of options for every test at once; `exclusive/1` one held by the module (`setup_all`)
  or test that calls it, at most `workers` at once (half the schedulers, as Playwright Test's
  default), reused after a passing scope. `on_start` runs once per new driver (e.g. to register
  selectors). On Firefox, use `exclusive/1`. `connect_options` is Playwright Test's
  `connectOptions`: pooled browsers on a remote Playwright server, with the context defaults
  and the recording. `PW_TEST_CONNECT_WS_ENDPOINT` (with `PW_TEST_CONNECT_HEADERS` and
  `PW_TEST_CONNECT_EXPOSE_NETWORK`) is the default when the config sets none, as in Playwright
  Test.
- `PlaywrightEx.Test`: `use PlaywrightEx.Test` after `use ExUnit.Case` (or first in a case
  template's body) registers each test. Every context it creates on a pooled browser, also in a
  `Task`, gets Playwright Test's context defaults (`locale: "en-US"`, a 1280x720 viewport, ...),
  then the config's `context_options`, and is recorded: traces, screenshots and videos with
  Playwright Test's modes and their options, from config and tags (`@tag trace: :on`), kept for
  failures, plus Playwright Test's `error-context.md` of each failed test and a `show-trace`
  hint. `info/0` and `output_path/1` are Playwright Test's `test.info()` and
  `testInfo.outputPath`. In a test, the snapshot matchers take upstream's `name:` (or none),
  resolved by Playwright Test's path templates (`snapshot_dir`, `snapshot_path_template`,
  `snapshot_path/2`) with their `-actual`, `-expected`, `-previous` and `-diff` files in the
  test's output dir, and a snapshot they write fails the test at the end of its body, with all
  its errors reported. `step` is Playwright Test's `test.step` (`box`, `location`, `params`,
  `subtitle`; no `timeout`), `step_skip` its `test.step.skip`, and each matcher call is a step:
  the trace's `test.trace` has the test's steps, nested, and its errors. `Expect.soft/1` is
  `expect.soft`: in a test, a failed soft matcher returns and fails the test at the end of its
  body. See the [Testing with ExUnit](guides/testing-with-exunit.md) guide.

### Changed
- `%PlaywrightEx.Expect{}` also carries `isSoft`, and `isNot` defaults to `false`: build a
  negated receiver with `Expect.not_/1`.
- The facade's `__options__/1` is documented as unstable: its shape may change between releases.
- User callbacks run on behalf of the process that registered them, with its `$callers`, as a
  `Task` does: route and WebSocket route handlers (and their `on_message`/`on_close`), event
  listeners, exposed functions and bindings, locator handlers, and the processes the client
  starts for a call (wait predicates). So the Ecto sandbox, Mox and `Req.Test` find the test in
  them. In a `PlaywrightEx.Test` test, an error a route handler, listener or locator handler
  raises now fails the test at the end of its body, as in Playwright Test, instead of only being
  logged.

### Fixed
- On Unix, stopping `PlaywrightEx.Supervisor` waits until the driver has exited (at most 31 s).
  When the supervisor is stopped before the VM halts, the driver no longer resets the terminal
  afterwards (↑ printing `OA` in the shell after `mix test`). `mix test` and `mix run` halt
  without stopping it, so the guides now stop it in `ExUnit.after_suite/1` or at the end of the
  script.

## [0.17.0-rc.5] 2026-11-10

### Changed
- `Page.wait_for_timeout/2` and `Frame.wait_for_timeout/2` reject `:infinity` (a
  `ValidationError`): their timeout is how long to wait, and `:infinity` used to wait 0 ms.

### Fixed
- `off`, `remove_listener` and `remove_all_listeners` no longer raise `TargetClosedError` once the
  driver is lost, as upstream's never throw.

## [0.17.0-rc.4] 2026-11-09

### Added
- `Expect.to_match_aria_snapshot/3` takes a `path:` option in place of the expected snapshot, as
  `to_have_screenshot` does: the file is the expected snapshot, and is written when missing or
  updating according to `:update_snapshots`.
- `usage-rules.md` ships in the Hex package, so consumers get it through `mix usage_rules.sync`.

### Changed
- `to_have_screenshot` and `to_match_aria_snapshot` print a notice when they write a missing
  snapshot under the default `:update_snapshots`, instead of passing without a word.

## [0.17.0-rc.3] 2026-11-08

### Added
- `select_option` option maps take `valueOrLabel`, so one list can mix matches by value or label
  with `index`: `[%{valueOrLabel: "red"}, %{index: 2}]`.

### Changed
- A disposable is a `%PlaywrightEx.Disposable{}` handle, and `PlaywrightEx.Disposable.t()` says so
  (it was `term()`).

## [0.17.0-rc.2] 2026-11-07

Drives [Playwright 1.65](https://github.com/microsoft/playwright/releases/tag/v1.65.0).

### Added
- `CDPSession.send/4` takes `:timeout` and `:signal`.

### Changed
- JSON values from the driver keep JSON `null` as `:null`, as `JSON.parse` does, instead of
  `nil`: `CDPSession.send/4` results and events, `Locator.aria_snapshot_json/2`, IndexedDB values
  in `storage_state`. Storage state files are read the same way: a `null` in an optional field
  (`"sameSite": null`) fails validation, as it does upstream.
- An error raised by a `CDPSession` listener is emitted as `"error"` when the session has an
  `"error"` listener.
- Upstream's breaking changes in 1.65: actions wait for the element to be not inert, cookie
  matching follows RFC 6265, proxy credentials only answer proxy challenges, text the browser
  does not render is no longer part of accessible names and aria snapshots, and `params` given
  as a string or keyword list are appended to the URL's query.

### Fixed
- A request body is JSON for `content-type: application/json; charset=utf-8` too.
- HAR paths ending in `.ZIP` are zip files.
- MIME types are looked up by file extension case-insensitively (`.JPG` screenshots).
- `Expect.to_have_screenshot/2` raises the driver's error when it fails for another reason than
  a mismatch.

## [0.17.0-rc.1] 2026-11-07

### Added
- `__options__/1` on the facade modules: the options of a function with their doc, since,
  rendered type and typespec, for wrappers that pass them on (`Locator.__options__(:click)`).

### Changed
- The maintainer-only mix tasks (`gen.api`, `gen.protocol`, `parity`, `checksums`) and their
  helpers moved out of `lib` into `dev/` and no longer ship in the Hex package.

### Fixed
- `PlaywrightEx.Supervisor.start_link/1` fails instead of hanging when the driver exits before it initializes.
- A driver install no longer deletes the complete install of a concurrent one unless `force: true`.
- A driver install with a file missing is repaired by `ensure_installed/1` and `install/1`.
- No stray message after `BrowserType.connect` times out, or after a navigation wait fails while
  waiting for the response.
- A call whose sending raises leaves no monitor or callback behind.
- `remove_all_listeners(..., behavior: :wait)` no longer sends errors of later listeners to the caller.
- Calls raise `TargetClosedError` for every exit of the connection process (`:killed` too).
- A message that cannot be encoded as JSON fails its call instead of restarting the driver.

## [0.17.0-rc.0] 2026-11-06

Drives Playwright 1.64.

### Changed
- Rewritten as a 1:1 port of the official JavaScript client (breaking).
  See the [migration guide](guides/migration.md).
- Tuple forms return `{:error, e}` only for the errors upstream rejects with
  (`PlaywrightEx.error()`); other exceptions (bugs, misuse) raise in both forms.
- `PlaywrightEx.Supervisor`'s child id is its `:name`: drivers of different names can share a
  supervision tree.
- `mix playwright_ex.install` fails with the CLI's exit status instead of a `MatchError`.
- Unknown keys in `config :playwright_ex, :expect` raise `ArgumentError` at application start.
- Failed bang matchers raise `PlaywrightEx.ExpectError`, not `ExUnit.AssertionError` (see
  [Testing with ExUnit](guides/testing-with-exunit.md#assertions) to wrap them).
- A lost driver closes its objects as a lost `BrowserType.connect` connection does: pages and
  contexts emit `close`, browsers `disconnected`, and waits on them fail with
  `PlaywrightEx.TargetClosedError` instead of hanging, as do waits on anything else (a worker)
  once the old connection stops. `PlaywrightEx.playwright/1` waits for the restarted driver.
  Handles of the lost driver keep reading their last state while the processes that created
  them live, closing them returns `:ok`, and the loss is logged as an error with the driver's
  exit status.

### Added
- [Concurrency](guides/concurrency.md) guide: listeners in processes, subscribing before
  checking state, promise lifetimes, differences from JS.

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
