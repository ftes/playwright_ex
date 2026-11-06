# Issue drafts (not filed)

One block per open "later" item from PLAN, DECISIONS and test/OTP_BACKLOG.md. Repo:
ftes/playwright_ex. `#draft-N` ids are what DECISIONS_TABLE.md refers to.

---

## #draft-1 Translate the facade docs' JS examples to Elixir

Labels: documentation, enhancement

The generated facade docs carry upstream's 321 code examples in JS (ratified for 1.64). Translate
them in `mix playwright_ex.gen.api`, either from the JS or by taking Python's examples and
rewriting them. Do it after the 1.64 release.

Source: PLAN "Then" 5; DECISIONS "Needs your decision" 6, workstream II.

---

## #draft-2 Four `wait_for_event` timeout docs still have the JS text

Labels: documentation

JS-only option docs take another client's text when the type matches. Four `wait_for_event`
timeout docs have no same-type non-JS sibling, so they still describe the JS behaviour. Write an
Elixir-specific text for them in `ApiRules`.

Source: DECISIONS workstream EE ("Open").

---

## #draft-3 Release 1.64.0

Labels: release

`mix.exs` still says 0.16.0. Set the version to 1.64.0 (versions mirror upstream major.minor),
turn the CHANGELOG's Unreleased section into the release entry, tag and publish.

Source: DECISIONS "Needs your decision" 4.

---

## #draft-4 Require the `Tests` check on `main`

Labels: ci, chore

`main`'s ruleset requires `Test (port)` and `Test (websocket)`, which CI no longer produces.
Require the aggregate `Tests` job instead, and require PRs on `main` (the upstream-update
workflow's tool deny-list is prefix-based, so the ruleset is the real guard).

Source: DECISIONS "Needs your decision" 0, "One CI test matrix", "after Phase 1".

---

## #draft-5 Waiter rejection settles in the waiter's process

Labels: runtime, deviation, discussion

JS rejects a waiter synchronously inside `emit`; here it settles in the waiting process, so
"rejected before the next emit" isn't guaranteed. Left as is and documented (concurrency guide,
architecture "Ordering"). A fix would need a blocking mailbox step (the connection waits for the
waiter's ack, next await or exit) plus a per-process buffer for events of live subscriptions the
current await doesn't arm, else dispatch deadlocks; ~150-250 lines. Even then a `.catch` runs
in the awaiting process, so `browsertype_connect_test`'s "rejected before disconnected" stays
adapted. Open this only if a user hits it.

Source: test/OTP_BACKLOG.md; DECISIONS "after Phase 1".

---

## #draft-6 Flake: HAR `unrouteAll` should stop routeFromHAR

Labels: flaky-test, bug

browsercontext_har_test "context/page.unrouteAll should stop routeFromHAR" fails ~1 in 30 under
load for our client, never for the driver's JS client with the same CDP command order:
`Page.url` is still about:blank after `unroute_all` returns. No ordering difference found in the
dispose path. Next: a CDP trace of a failing run.

Source: test/OTP_BACKLOG.md; DECISIONS round 2 (VF-D2).

---

## #draft-7 Flake: "should not throw when continuing while page is closing"

Labels: flaky-test, runtime

page_close_test fails under full-suite load only (20/20 alone): if the close reaches the driver
before `route.continue`, the close hangs until the context closes. `Promise.void` returns once
`continue` first blocks; check that its send is that first block.

Source: test/OTP_BACKLOG.md.

---

## #draft-8 Watch list: possibly load-flaky tests

Labels: flaky-test

Seen failing once each in loaded full runs: `locator_query_test.exs:324` (webkit),
`conn_test.exs:360` (120 s timeout), `page_screenshot_test.exs:482`,
`page_add_locator_handler_test.exs` "should work" (hover with 2 concurrent pages). Close if CI
stays green for a few weeks; otherwise split into one issue per test.

Source: test/OTP_BACKLOG.md.

---

## #draft-9 Make firefox blocking in CI

Labels: ci, firefox

Firefox is `continue-on-error` in the CI matrix because of Linux-only failures: `innerWidth` vs
the context viewport, and worker timestamps. Fix or tag them, then drop `continue-on-error`.

Source: DECISIONS workstream CC.

---

## #draft-10 Chromium worker races

Labels: flaky-test, upstream

`workers_test:237` hangs for upstream's JS client too (6/510 under 2-CPU load), tagged flaky and
reported as microsoft/playwright#43922. connect_to_worker's console test stays skipped: our
evaluate lands ~0.5 ms later than JS's after the driver resumes node, and fails 5-10%. Re-check
both on each Chromium roll.

Source: DECISIONS workstream CC, "after Phase 1".

---

## #draft-11 Firefox withholds Partitioned cookies from a fresh Bandit server

Labels: test-infra, firefox

browsercontext_cookies_third_party has an `env:` skip: Firefox mostly withholds Partitioned
cookies from third-party frames of a freshly started Bandit test server (upstream's client too).
The mechanism is unknown.

Source: DECISIONS workstream W.

---

## #draft-12 Report the driver crash on an HTTPS proxy closing mid-handshake

Labels: upstream

An HTTPS proxy closing mid-handshake crashed the Node driver (unhandled TLSSocket error). Our
TestProxy now completes the handshake, so the suite no longer hits it. Reproduce against the
driver and report upstream.

Source: DECISIONS "Library specs group 6".

---

## #draft-13 `ClientHelper.number_to_string/1` lacks JS's exponent form

Labels: bug, good first issue

JS `String(1e21)` is `"1e+21"`; ours gives `"1.0e21"` for a float and all the digits for an
integer (also small numbers: JS `1e-7`, ours `1.0e-7`). Port the exponent branch of
Number.prototype.toString.

Source: DECISIONS round 2 (VF-D2, "Open").

---

## #draft-14 Await a screencast `onFrame` that returns a promise

Labels: bug, parity

Upstream awaits `this._onFrame?.(...)` before acking the frame (backpressure). Our
`Client.Screencast` calls the callback but does not await a returned `%Promise{}`, as route
handlers now do (`ClientHelper.call_function/2`).

Source: DECISIONS workstream I.

---

## #draft-15 Typespecs: `Disposable.t()` and storage state keys

Labels: typespecs

`PlaywrightEx.Disposable.t()` is `term()`; make it the union of `DisposableObject` and
`DisposableStub`. Storage state is an open map (`optional(atom()) => term()`); type the
documented keys while keeping undocumented ones (`credentials`, `indexedDB`, `opfs`) round-tripping.

Source: DECISIONS workstreams H and L.

---

## #draft-16 Inline aria snapshots: rebaseline by rewriting source

Labels: enhancement

Without a test runner, an inline aria snapshot that upstream would rebaseline fails with the new
snapshot in the message. Porting the runner's source rewriting would let `update_snapshots`
modes write it back.

Source: DECISIONS round 2 (VF-C2).

---

## #draft-17 Re-verify macOS WebKit `env:` skips on the next WebKit roll

Labels: test, webkit

12 tests carry `env:` skips for Mac WebKit on macOS 26 (middle-click pointerdown in page_mouse,
gray video and screencast frames in video and tracing). Upstream's client fails them too, and
Linux CI passes them. Re-run them with the next WebKit build and drop the skips that pass.

Source: DECISIONS workstreams T, U1, round 2 (C3a-10, VF-E).

---

## #draft-18 Settle latches after the emit that settles them

Labels: bug, runtime

A latch settled in a listener step (`Browser._did_close` settling `_closedPromise`) wakes its
awaiter before the same emit's later listeners run, so after `connect`, `Browser.close!` can
return before the `disconnected` listener ran. JS resolves the promise inside the synchronous
`emit`. Idea: `Runtime.Conn` holds back latch wake-ups until the frame's steps finish. Repro: the
skipped stress test "connect: the disconnected listener has run when close returns".

Source: test/OTP_BACKLOG.md; Phase 2 stress run.

---

## #draft-19 Free a disposed JSHandle's rows

Labels: enhancement, runtime

A disposed JSHandle keeps ~7 heap rows until its context is freed (35k rows after 5k disposes in
perf_test), so a long-lived page grows without bound. Free them on an explicit `dispose` and keep
only a tombstone, as for collected objects.

Source: test/OTP_BACKLOG.md; Phase 2 perf run.

---

## #draft-20 Rows left after remote connect/close on Linux firefox

Labels: bug, runtime

connect_backlog_test "a closed remote connection stops its processes": after 20 connect/close
cycles, Linux firefox CI keeps ~30 rows on the local connection (chromium and webkit under 20,
macOS firefox too); processes and tables do not grow. Find which rows stay (dump the keys before
and after) and free them with the remote Conn.

Source: CI run 42144826747 (firefox).
