# Where DECISIONS and PLAN went

For review before CLOSE (bookmark `restructure-close`) deletes DECISIONS.md, PLAN.md, ISSUES.md,
test/OTP_BACKLOG.md and this table. Destinations: `arch §X` = docs/architecture.md section,
`PORTING §X`, `guide:<name> (Section)` = guides/ (`guide:concurrency`, `guide:migration`,
`guide:api-conventions`, `guide:testing-with-exunit`, `guide:network`, `guide:debugging-and-ci`),
`CHANGELOG`, `GH #N` = GitHub issue, `code` = already stated where it applies (moduledoc, marker
comment, ApiRules, test comment) and needs no durable doc, `dropped: <reason>`, `decided: <choice>`.
Every former `#draft-N` (ISSUES.md, PLAN.md "Later") now has a final place: done, fixed, a GH issue
or PORTING §Upstream issues to re-check. `59.N` rows cover the bullets DECISIONS appends to entry
59. An entry with several bullets lists each bullet's destination; the first destination is the main
one.

## DECISIONS.md (60 entries)

| # | Entry | Where it went |
|---|---|---|
| 0 | Needs your decision (before a 1.64 release) | 0 ruleset: dropped: done; 1 top-level exceptions, 2 handle structs: arch §Generated facade; 3 expect defaults: guide:api-conventions (Assertions), guide:testing-with-exunit (Assertions); 4 release: decided: 0.17.0-rc.0 (CHANGELOG, GH #126); 5 global AbortController: arch §BEAM instead of JS runtime ports; 6 doc examples: dropped: done |
| 1 | 2026-11-04 Locators on Frame/Page | `$`-names: arch §Generated facade; `$eval` no options: code (ApiRules); raw-selector inspect, description regex, kAnyFrameSelector: dropped: superseded by workstream R (arch §Driver language and rendering); test id `:persistent_term`: code; ElementHandle stub: dropped: obsolete; `Upstream to-do:`: PORTING §Rules |
| 2 | 2026-11-04 Direction check 1 | nil vs JS defaults: PORTING §Idioms, arch §Value mapping; parity enforces order: arch §Port and versions, PORTING §Rules; record_har gap: dropped: resolved (workstreams F, H) |
| 3 | 2026-11-04 Input, Dialog, ConsoleMessage, WebError, Worker (B) | readonly fields as functions: arch §Generated facade; ConsoleMessage inspect: code (test deviation comment); assertions in listeners: PORTING §Tests; Mac-only skips: PORTING §Tests (compile-time tags) |
| 4 | 2026-11-04 waitForEvent, urlMatch, promise handles (C) | promise handles, callback forms: arch §Generated facade, guide:concurrency; blocking wait revisit: dropped: resolved (bang waits, KK); optionsOrPredicate: guide:migration; function URL matchers, URLPattern: arch §URL globs; glob cache: arch §URL globs; `@events` atoms: code (generator) |
| 5 | 2026-11-04 ElementHandle, JSHandle, setInputFiles (A) | `String.Chars` preview, subclass dispatch: code, PORTING §Idioms (`impl/1`); inputValue no options: code (ApiRules); WritableStream `Collectable`: arch §BEAM; test deviations: code; `test/support/utils.ex`: PORTING §Tests |
| 6 | 2026-11-04 fetch / APIRequestContext (G) | four modules, verb shadowing, `Object<K,V>`: code; request data (`{:binary, b}`, `:null`, keyword lists): arch §Value mapping, arch §BEAM; Buffer typing, compact JSON, nested `:null`: dropped: resolved (F, round 2, N); test fixtures: code |
| 7 | 2026-11-04 Routing, HAR, WebSocketRoute (F) | 1- or 2-arity handlers, `string\|Buffer`: arch §Value mapping; globs via driver: arch §URL globs; `_savedZone`, WebSocketRoute server: code (moduledoc deviations); `route` returns nil: dropped: superseded (Disposable, H); MimeType: arch §BEAM (kept ports); Bandit `compress: false`: arch §Test infrastructure; recordHar: dropped: resolved |
| 8 | 2026-11-05 Matchers (E) | one Expect module, `not_`, `to_have_screenshot(path:)`, not-ported list: arch §Generated facade, guide:migration (Known gaps); `to_have_attribute` merge: dropped: superseded (orOptions, KK); ExpectError: code; MatcherUtils: arch §BEAM; expect timeout: guide:api-conventions (Assertions), guide:testing-with-exunit (Assertions) |
| 9 | 2026-11-05 Bindings, init scripts, Disposable, locator handlers (H) | page callbacks, init script function source: arch §Value mapping; Disposable: code, GH #127 (type); try/finally: code |
| 10 | 2026-11-05 Artifacts, tracing, video, screencast (I) | streams as Enumerables: arch §BEAM; onFrame promise: dropped: fixed (59.6); listener stacks: code; tail calls drop callers: dropped: inherent BEAM limit; Tracing `coverage:`: guide:migration (Behaviour changes) |
| 11 | 2026-11-05 Clock, Coverage, WebStorage, CDPSession, Selectors, Debugger, Credentials, WebMCP (J) | CDP events by string, `CDPSession.send`: code (ApiRules `@open_events`); Date as DateTime: arch §BEAM; sync members take the baton: dropped: obsolete (no baton); credentials revisit: dropped: resolved (TT); debugger Task locations: dropped: inherent BEAM limit |
| 12 | 2026-11-05 Browser lifecycle, connect (K) | connect via LocalUtils/JsonPipe: arch §Port and versions; `\|\|` on close reason: code; run-server only: dropped: superseded (BB2); heaps/errors revisit: dropped: resolved; Electron/Android: code (parity `@unported_client_files`) |
| 13 | 2026-11-05 Which upstream specs to mirror | arch §Mirroring upstream specs, PORTING §Tests (north star); per-file list: dropped: superseded by the registry (MM); poll helpers: PORTING §Tests |
| 14 | 2026-11-05 Mirrored page specs (groups 1-4) | browser checks and `test.fail` as refute: dropped: superseded (skip tags, `expected_failure/2`, PORTING §Tests); nested describes: PORTING §Tests; snapshot skips: dropped: resolved (U2); waitForLoadState(load) skip: dropped: resolved (Phase 1) |
| 15 | 2026-11-05 Stale-skip sweep and page specs group 5 | `to_pass`/`poll`, Agent for listener state: PORTING §Tests; close-code skips: dropped: resolved (DD); `date` header: code (test comment); browser guards: dropped: resolved (final skip sweep) |
| 16 | 2026-11-05 Remaining members, release gate, teardown (L) | release gate: arch §Generated facade; storage state open map: arch §Generated facade, GH #127; listener promise leak, calls on a stopped loop: dropped: obsolete (OTP runtime); preloaded modules: arch §Runtime; `pause`, `pdf` px: code |
| 17 | 2026-11-05 Library specs group 8 | events/* specs: dropped: obsolete (Node EventEmitter specs dropped when EventEmitter was trimmed); proxy: dropped: resolved (TestProxy); `_coverage`: code; logger: dropped: resolved (N) |
| 18 | 2026-11-05 Library specs group 6 | TestProxy: arch §Test infrastructure; `addCookies` open object: arch §Generated facade (open maps); TLS renegotiation: dropped: resolved (tls_renegotiation_server.js); bfcache: code; driver crash: GH #130 |
| 19 | 2026-11-05 Library specs group 7, `once` fix | OnceWrapper, extensions channel: code; device_options: dropped: resolved (N); own EventLoop: dropped: obsolete; connect-to-worker race: dropped: fixed (59.35); headful/multiclient bodiless: dropped: superseded (`:headed`, BB2) |
| 20 | 2026-11-05 Direction check 2 | heap GC: dropped: obsolete (OTP runtime, arch §Runtime); JSON null etc.: arch §Value mapping; stale skips: PORTING §Tests; `signal:` dropped: dropped: superseded (X) |
| 21 | 2026-11-05 Flaky tag | `flaky:` prefix: arch §Mirroring upstream specs, PORTING §Tests; the three tags: dropped: resolved (CC) |
| 22 | 2026-11-05 Library specs groups 9-10; spec mirroring complete | counts: dropped: superseded by parity/registry; bugs: dropped: resolved; storage-state error text: dropped: superseded (Node ENOENT, arch §BEAM); helper modules top-level: PORTING §Tests; not portable: code (upstream_not_ported.txt) |
| 23 | 2026-11-05 Migration guide | guide:migration; awkward names: dropped: resolved (EE); `Selectors.register` once per driver: guide:migration; saveAs canceled: dropped: upstream behaviour (T) |
| 24 | 2026-11-05 Review fixes (N) | JSON null: arch §BEAM, §Value mapping; `logger` callback objects: arch §Generated facade; expect defaults: guide:api-conventions (Assertions), guide:testing-with-exunit (Assertions); device descriptors: arch §Value mapping; fresh state on re-created guid, parity root module, `highlight(style:)`: code |
| 25 | 2026-11-05 Heap GC and Map order (M) | tracing GC: dropped: obsolete, named as superseded in arch §Runtime; Map order: arch §Runtime |
| 26 | 2026-11-05 Final skip sweep | skip tags per browser: PORTING §Tests; proxy ipv6: code; glob specs: dropped: superseded (LL); firefox CC: dropped: resolved (GG) |
| 27 | 2026-11-05 EventEmitter completed (O), stale-skip check (P) | 1:1 EventEmitter: dropped: superseded (trimmed to what the client uses, EventEmitter moduledoc); one `emit` arg, removeAllListeners: code (moduledoc); stale-skip check: PORTING §Tests; flaky tags: dropped: resolved |
| 28 | 2026-11-05 Completeness checks (S) | every upstream file: PORTING §Rules, §Tests; unported client files: code (parity task); counts: dropped: stats |
| 29 | 2026-11-05 Locator rendering in Elixir (R) | arch §Driver language and rendering; RegExp struct: arch §Value mapping; install hint: arch §Driver language; chromium-only install: dropped: resolved (One CI matrix) |
| 30 | 2026-11-05 Firefox/WebKit runs (T), CI-only failures (Q) | CI job: dropped: superseded (arch §CI); test-server loopbacks, closing contexts: arch §Test infrastructure; `env:` confirmed with Node: arch §Mirroring, PORTING §Tests; saveAs canceled: dropped: upstream behaviour; Service Worker `ci:` skips: dropped: resolved (none left); subscription batching: arch §Runtime; `Task.await_many` infinity: PORTING §Tests |
| 31 | 2026-11-05 toMatchSnapshot via the driver's comparator (U2) | arch §Test infrastructure; oopif screenshot `env:`: code |
| 32 | 2026-11-05 VideoPlayer (U1) | arch §Test infrastructure; Mac WebKit gray frames: PORTING §Upstream issues to re-check |
| 33 | 2026-11-05 AbortSignal (X) | arch §BEAM (global AbortController); client and facade `signal:`: guide:migration (Errors); statics: dropped: not in api.json, unused; baton revisit: dropped: obsolete |
| 34 | 2026-11-05 Linux firefox/webkit CI (W) | `Upstream.ensure!` lock, TestBrowser, module skips: code; Linux env skips: arch §CI (xvfb), PORTING §Upstream issues to re-check (Partitioned cookies); racing waits via `Promise.async`: PORTING §Tests |
| 35 | 2026-11-05 Driver message batching (Y) | dropped: superseded by per-turn buffering (arch §Runtime names it); worker console races: dropped: fixed (59.35) |
| 36 | 2026-11-05 Final fidelity audit, fixes (Z) | fixes: dropped: done; keyword lists for URLSearchParams/FormData: arch §BEAM; storage-state indent: arch §BEAM (final form, round 2); xvfb: arch §CI; firefox GC loop `env:`: dropped: obsolete (test went with the GC); webkit form-post flaky: dropped: resolved (CC) |
| 37 | 2026-11-05 Local URL glob matching (AA) | dropped: reverted by LL (arch §URL globs names it); 10 s `assert_receive`: PORTING §Tests; expectedSSLError: code; flaky tags: dropped: resolved (CC) |
| 38 | 2026-11-05 One CI test matrix | arch §CI; ruleset: dropped: done; launchServer specs: arch §Test infrastructure; install default browsers: code (Driver) |
| 39 | 2026-11-05 TestServer WebSocket framing (DD) | arch §Test infrastructure (superseded in part by SS) |
| 40 | 2026-11-05 URL globs through the driver again (LL) | arch §URL globs |
| 41 | 2026-11-05 Facade docs for the Elixir API (II) | arch §Generated facade; JS examples: dropped: done (59.29) |
| 42 | 2026-11-05 Top-level errors, facade structs, optionsOrPredicate (EE) | arch §Generated facade; optionsOr: guide:migration, code; open docs: dropped: done |
| 43 | 2026-11-05 launchServer specs (BB2) | arch §Test infrastructure; SIGHUP exit codes, SI-007..009: code; connect reuse scenarios kept: dropped: decided (kept); explicit stop: dropped: superseded (OO) |
| 44 | 2026-11-05 Upstream test registry (MM) | arch §Mirroring upstream specs, PORTING §Tests |
| 45 | 2026-11-05 GC fixes (JJ) | dropped: obsolete (OTP runtime); pause figures kept in arch §Runtime |
| 46 | 2026-11-05 Global AbortController, Expect.not_, bang waits (KK) | arch §BEAM; aborted-signal row: dropped: superseded (rows freed when the creator exits, abort_signal moduledoc); `not_`, bang waits: arch §Generated facade, guide:api-conventions (Assertions; Waiting for events); orOptions: guide:api-conventions (Optional arguments) |
| 47 | 2026-11-05 Fixtures exit with the test BEAM (OO) | arch §Test infrastructure; `--inspect-brk` window: dropped: accepted, test-only |
| 48 | 2026-11-05 Heap lifetimes without tracing (design study) | dropped: not taken; named as the rejected alternative in arch §Runtime |
| 49 | 2026-11-05 Flake causes and fixes (CC) | UpstreamCase timeouts: arch §Test infrastructure; firefox non-blocking: dropped: firefox blocks since 2026-11-06; connect_to_worker: dropped: fixed (59.35) |
| 50 | 2026-11-05 Stdlib in place of JS ports (QQ) | arch §BEAM (kept jest-style messages, URLSearchParams); `:json.format`: dropped: superseded (round 2 layout); Regex PCRE-only raises: arch §Value mapping; RegExp open: dropped: resolved (RR) |
| 51 | 2026-11-05 OTP-native runtime spike (PP) | arch §Runtime, §Ordering; effort estimate: dropped: history |
| 52 | 2026-11-05 Test WebSocket framing via cowlib (SS) | arch §Test infrastructure |
| 53 | 2026-11-05 Public RegExp, stdlib form encoding (RR) | RegExp: arch §Value mapping, guide:migration; `URI.encode_www_form`: dropped: superseded (WHATWG serializer, arch §BEAM); macOS hang: dropped: resolved (Phase 0) |
| 54 | 2026-11-05 credentials.create takes the returned credential (TT) | arch §Value mapping, §Generated facade (`@result_options`), guide:api-conventions (Options) |
| 55 | 2026-11-05 OTP-native runtime, Phase 0 done | arch §Runtime, §Object lifetimes; failing tests: dropped: resolved (Phase 1) |
| 56 | 2026-11-05 OTP-native runtime, Phase 1 done | arch §Ordering, PORTING §Shims; merge order and agent notes: dropped: history |
| 57 | 2026-11-05 after Phase 1 | subscribe-first and `Promise.free/1`: guide:concurrency, arch §Ordering; `on_reply`: PORTING §Shims, arch §Ordering; waiter rejection: arch §Ordering, guide:concurrency, GH #128; test timeouts: arch §Test infrastructure; workers_test:237: PORTING §Upstream issues to re-check; Linux harness: PORTING §Tests; upstream-update workflow: arch §CI, PORTING §Bumping; ruleset: dropped: done; config audit, parity pass: dropped: done (round 2); 1.62 cache error: dropped: history (memory has it); north star: arch §Mirroring |
| 58 | 2026-11-05 north-star ports and harness fidelity | north star and its exceptions: code (upstream_not_ported.txt); second driver, `__testHook*`: arch §Test infrastructure; `:headed`: PORTING §Tests, arch §CI; Selenium: code (CI comments); harness defaults: arch §Test infrastructure; apt retries: code (workflow); remote_server launch options: dropped: resolved (VF-H) |
| 59 | 2026-11-05 parity pass (round 2) | process and counts: dropped: history; RO-033: arch §Ordering; dying listener, once unsubscribe, abort race, one trace per call: arch §Ordering, code; leak warning, tombstone, "Error" name: arch §Object lifetimes, code (EventEmitter moduledoc); `Node.path_resolve/1`, `Node.fs!/3`: dropped: superseded (wr4-paths, 59.11); `@browser_name`/`@browser_major_version`, `slow()`: PORTING §Tests, arch §Mirroring; `Utils.assert_truthy/1`: PORTING §Tests; H-16: PORTING §Tests; H-17: arch §CI; VF-D2: arch §BEAM; HAR flake: dropped: fixed (`_onRoute` deviation, 59.18); `number_to_string`: dropped: fixed (59.6); VF-D1: arch §Value mapping; VF-C2: GH #129; C3a-10, VF-E macOS WebKit: PORTING §Upstream issues to re-check; X-01 `Promise.async`/`void` idiom: PORTING §Tests; Phase 2 backlog (remote Conn stop, process aliases, `await_all_atomic`, `async_once`, params as a function): arch §Object lifetimes, code (markers); VF-C1, VF-B, VF-A1, VF-A2, VF-C3, X-03, A2b-06, C3a-14, modernizr, `set_test_id_attribute`, `_retire`, OOPIF click: code (deviation markers, test comments) |
| 59.0 | row 59 cell fixes (bullets up to the lead webkit-CI fix) | `Node.path_resolve/1`, `Node.fs!/3`: dropped: superseded (wr4-paths, 59.11); HAR flake: dropped: fixed (`_onRoute` deviation, 59.18); `number_to_string`: dropped: fixed (59.6); VF-C2: GH #129; C3a-10, VF-E macOS WebKit: PORTING §Upstream issues to re-check |
| 59.1 | Phase 2 stress/perf | manual only: arch §Test infrastructure, code (perf_test/stress_test headers); figures: dropped: history (context close: 59.20); mid-emit latch gap: dropped: resolved (Conn.wake/unwake, 59.37, 59.44); disposed-handle rows: dropped: resolved (59.33) |
| 59.2 | Lead, webkit CI: backlog leak tests settle, OOPIF setup_all | code (network_backlog_test, oopif_test) |
| 59.3 | User: firefox blocks CI | arch §CI ("every job blocks it"); Linux failures: dropped: resolved |
| 59.4 | User: open items split by owner; no transport matrix | split: dropped: superseded (PLAN/ISSUES deleted; GH #126–#130, PORTING re-checks); transport matrix: arch §Mirroring upstream specs |
| 59.5 | OOPIF "should click" is a browser race | PORTING §Upstream issues to re-check; code (skip comment) |
| 59.6 | #13/#14 fixed | dropped: done; code (ClientHelper `number_to_string`, screencast_test comments) |
| 59.7 | WR3 heap #19: disposed handle frees its rows | arch §Object lifetimes (final form 59.33) |
| 59.8 | WR3 heap #20: JsonPipe freed at dispose | arch §Object lifetimes; details: dropped: history |
| 59.9 | User RD1: `~` not special, `Path.expand` | arch §BEAM, PORTING §Tests |
| 59.10 | User RD2: route/WS-route/locator-handler callbacks are JS functions | arch §Value mapping, code (RouteHandler moduledoc, `ClientHelper.call_function/2`, WebSocketRouteHandler), guide:network |
| 59.11 | Local file access is plain Elixir (wr4-paths) | arch §BEAM, PORTING §Tests, guide:migration (Behaviour changes); storage-state part: superseded by 59.34; Python comparison: dropped: rationale stated in arch |
| 59.12 | User RD3: `get_properties` map; polling out of library | map: code (client js_handle `# deviation:`), facade doc (ApiRules `@notes`); test-runner features: arch §Generated facade (Out of scope), guide:testing-with-exunit (Polling and waiting) |
| 59.13 | Docs plan (wr4-docs) | arch §Generated facade (examples as tests, rejected doctests/compile-only checker), ExampleCase moduledoc, mix.exs docs config |
| 59.14 | User RD4: remote Conn stops once creators exit | arch §Object lifetimes |
| 59.15 | User RD5: suite `assert_receive_timeout: 10_000` | PORTING §Tests, code (test_helper) |
| 59.16 | WR3 runtime ordering (`Conn.wake/2`) | arch §Ordering, code (`Conn.wake/2`); second #20 fix: dropped: history |
| 59.17 | WR3 ClientStackTrace cwd cache | dropped: superseded (59.35, then no cache: ClientStackTrace comment) |
| 59.18 | WR3 `_onRoute` sends update only when expired | code (`# deviation:` in Page and BrowserContext `_on_route`) |
| 59.19 | User RD6: one CI rerun, first failures in summary | arch §CI, code (elixir.yml comment) |
| 59.20 | User RD7: context close +21% with 1000 handles accepted | arch §Runtime |
| 59.21 | User docs Q1: guides block 1.64.0, example count on spike | dropped: superseded (release is 0.17.0-rc.0; all examples and guides done) |
| 59.22 | User docs Q2: `filter_modules`, `:expect` config doc single source | code (mix.exs comment, ApiRules / `Matchers.Expect.__config_doc__/0`) |
| 59.23 | WR5 examples spike | code (ExampleCase moduledoc, test/examples); counts: dropped: history |
| 59.24 | User docs Q3: ExUnit guide framework-neutral, Fluffy link | guide:testing-with-exunit (intro) |
| 59.25 | User: translate all examples, prose polish; dictionary string keys | dropped: done (examples merged, api_docs_test); string keys: code (gen.api dictionary comment), guide:api-conventions (Options) |
| 59.26 | WR6 guides | code (test/guides, debugging_and_ci_test lists untested parts); failure recipe: superseded by 59.38; JS call logs: arch §Driver language |
| 59.27 | WR6 intro docs | guide:migration (0.16 only), PlaywrightEx moduledoc (aliases note), code (cheatsheet_test, getting_started_test `async: false` comment) |
| 59.28 | Lead guides merge | mix.exs extras, guide:debugging-and-ci (`upload-artifact@v7`); open question: superseded by 59.38 |
| 59.29 | Lead docs: examples merged, prose guard | code (ExampleCase, test/playwright_ex/api_docs_test.exs); counts: dropped: history |
| 59.30 | User/lead: option bullets with types | code (gen.api comments) |
| 59.31 | User: one browser per run in ExUnit guide | guide:testing-with-exunit (Setup) |
| 59.32 | User: guides vs upstream, bump step | guide:testing-with-exunit (supervised owner), PORTING §Bumping step 5, .github/prompts/upstream-update.md step 3.5 |
| 59.33 | User RD8: disposed handle frees rows, reads raise | arch §Object lifetimes |
| 59.34 | User RD9: storage-state read error wraps `File.Error` | guide:migration (Behaviour changes), code (`# deviation:` in BrowserContext `prepare_storage_state`) |
| 59.35 | User RD10: stack frames take module source path | code (ClientStackTrace comments) |
| 59.36 | User RD11: `_onRoute` keeps deviation | code (`# deviation:` Page/BrowserContext) |
| 59.37 | User RD12: keep `Conn.wake/2` | arch §Ordering, code |
| 59.38 | User RD13: trace on rerun, retain on failure | guide:testing-with-exunit (Traces and screenshots of failures), test/guides |
| 59.39 | User RD14: shared drivers per worker | PORTING §Tests, code (TestWorkers moduledoc, UpstreamCase `:own_worker`); spike numbers: dropped: history |
| 59.40 | User: release 0.17.0-rc.0 | CHANGELOG, mix.exs `@version`, arch §Port and versions, GH #126, upstream-update.md step 4 |
| 59.41 | User: tuple forms return what JS rejects with | arch §Generated facade, guide:api-conventions (Results), `PlaywrightEx.error` typedoc, CHANGELOG |
| 59.42 | User: bang matchers raise `ExpectError` | arch §Generated facade (with the rejected ExUnit detection), guide:api-conventions (Assertions), guide:testing-with-exunit (Assertions), Expect moduledoc, CHANGELOG; `:expect` validation: CHANGELOG, guide:api-conventions; rest: code |
| 59.43 | Correction: Selectors guard removed | dropped: fixed (guid-reuse bug) |
| 59.44 | User findings 1/2: `Conn.unwake/2`, `expect/4` frees wait | code (`Conn.unwake/2`, `Runtime.Facade.run_action/2` comments) |
| 59.45 | User: lost driver emulates close | `PlaywrightEx.Supervisor` §Lifetimes, OutOfProcess moduledoc + `# deviation:`, arch §Generated facade (consumer requests, `connection_pid/1` rejected), guide:concurrency, CHANGELOG; revisit note: superseded by 59.46 |
| 59.46 | User, revisited: keeper keeps reads, close `:ok`, loss logged, restart stays | arch §Object lifetimes, `PlaywrightEx.Supervisor` §Lifetimes, OutOfProcess moduledoc, `# deviation:` in Page/Browser close and BrowserContext, guide:concurrency (Lifetimes after close), CHANGELOG; no `restart: :exit`: dropped: no consumer needs it |

## PLAN.md (14 sections)

| Section | Where it went |
|---|---|
| Intro (mirror 1:1, generated contract) | arch §Port and versions, §Generated facade |
| Layers | arch §Layers (baton and GC lines rewritten); removed modules: guide:migration |
| Public API (generated) | arch §Generated facade (shapes, handles, names, waits); keys and options: guide:api-conventions (Options); timeouts and `Task.yield`: guide:migration; `on/3` queued subscription: dropped: obsolete (baton tick) |
| Concurrency: baton | dropped: superseded; arch §Runtime names it and its costs |
| Infrastructure | arch §Port and versions (driver, remote, no version check), §Layers; spike figures: dropped: history |
| Tracking upstream | PORTING (Rules, Bumping), arch §Port and versions |
| Decisions | versions: arch §Port and versions; globs: arch §URL globs; sdkLanguage: arch §Driver language; bytes, names, evaluate, bindings, nil/`:null`: arch §Value mapping, §Generated facade; inspect: arch §Driver language; GC: dropped: obsolete; AbortSignal, zones: arch §BEAM; to_have_screenshot, out of scope: arch §Generated facade; explicit `try`: code |
| Spike results | dropped: history (baton spike); its follow-ups: dropped: obsolete (baton, heap `update`, microtasks) or resolved (`run-server` SIGTERM by OO) |
| Consumers | arch §Generated facade (consumer requests); behaviour changes: guide:migration; JsLogger recipe: guide:migration |
| OTP-native runtime migration | arch §Runtime, §Object lifetimes, §Ordering; shim rules: PORTING §Shims; listener kinds: arch §Ordering, EventEmitter moduledoc; phases, groups, merge order: dropped: history; risks: arch §Ordering, guide:concurrency (blocking listeners); docs to-dos: done here |
| Quality gate: full parity pass | dropped: done (round 2, DECISIONS entry 59) |
| Before merging: preserve decisions | dropped: done by this pass |
| Then | 1-4: dropped: done (arch §Generated facade, §Driver language describe the result); 5 JS examples: dropped: done (59.29) |
| Docs | dropped: done (guides/, `PlaywrightEx.ExampleCase`, arch §Generated facade); research notes: dropped: history |
| Later | GH #126-#130 (versions, typespecs, waiter rejection, aria rebaselining, proxy driver crash), PORTING §Upstream issues to re-check (macOS WebKit, Firefox Partitioned cookies, Chromium worker hang, OOPIF); ruleset, #1, #2: dropped: done |

## test/OTP_BACKLOG.md

| Item | Where it went |
|---|---|
| Waiter rejection | arch §Ordering, guide:concurrency, GH #128 |
| Route handler at teardown (RO-033) | arch §Ordering; dropped as an issue: decided |
| HAR `unrouteAll` flake | dropped: fixed (`_onRoute` deviation, 59.18) |
| Watch list (4 tests) | dropped: the watch list stayed green on CI |
| page_close continue while closing | dropped: fixed (stack frames take the module source path, 59.35) |

## Stats

Counted by script over the cells above (`arch §`, `PORTING`, `guide:*`, `GH #N`, `CHANGELOG`,
`code`, `dropped:`, `decided:`; first-named = the first of these in a cell).

- DECISIONS: 107 rows (entries 0-59 plus 59.0-59.46). First-named: arch 52, dropped 21, code 17,
  PORTING 7, guide 9 (testing-with-exunit 4, migration 3, concurrency 1, debugging-and-ci 1),
  CHANGELOG 1. References: arch 116, dropped 106, code 65, PORTING 44, guide 37 (migration 11,
  api-conventions 10, testing-with-exunit 9, concurrency 5, network 1, debugging-and-ci 1), GH 9,
  CHANGELOG 7, decided 1.
- PLAN: 15 rows (14 sections plus the intro). First-named: arch 7, dropped 6, PORTING 1, GH 1.
- OTP_BACKLOG: 5 rows. First-named: dropped 3 (HAR flake and page_close fixed, watch list green),
  arch 2 (waiter rejection with GH #128, RO-033 decided).
- GH issues: 5 distinct (#126-#130), each referenced at least once. No `#draft-N` is left in the
  tables, and every `dropped:` gives a reason.
