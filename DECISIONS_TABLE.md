# Where DECISIONS and PLAN went

For review before CLOSE (bookmark `restructure-close`) deletes DECISIONS.md, PLAN.md and test/OTP_BACKLOG.md. Destinations:
`arch §X` = docs/architecture.md section, `PORTING §X`, `guide:concurrency` / `guide:migration`,
`#draft-N` = ISSUE_DRAFTS.md, `code` = already stated where it applies (moduledoc, marker
comment, ApiRules, test comment) and needs no durable doc, `dropped: <reason>`. An entry with
several bullets lists each bullet's destination; the first destination is the main one.

## DECISIONS.md (60 entries)

| # | Entry | Where it went |
|---|---|---|
| 0 | Needs your decision (before a 1.64 release) | 0 ruleset: #draft-4; 1 top-level exceptions, 2 handle structs: arch §Generated facade; 3 expect defaults: guide:migration (Timeouts); 4 release: #draft-3; 5 global AbortController: arch §BEAM instead of JS runtime ports; 6 doc examples: #draft-1 |
| 1 | 2026-11-04 Locators on Frame/Page | `$`-names: arch §Generated facade; `$eval` no options: code (ApiRules); raw-selector inspect, description regex, kAnyFrameSelector: dropped: superseded by workstream R (arch §Driver language and rendering); test id `:persistent_term`: code; ElementHandle stub: dropped: obsolete; `Upstream to-do:`: PORTING §Rules |
| 2 | 2026-11-04 Direction check 1 | nil vs JS defaults: PORTING §Idioms, arch §Value mapping; parity enforces order: arch §Port and versions, PORTING §Rules; record_har gap: dropped: resolved (workstreams F, H) |
| 3 | 2026-11-04 Input, Dialog, ConsoleMessage, WebError, Worker (B) | readonly fields as functions: arch §Generated facade; ConsoleMessage inspect: code (test deviation comment); assertions in listeners: PORTING §Tests; Mac-only skips: PORTING §Tests (compile-time tags) |
| 4 | 2026-11-04 waitForEvent, urlMatch, promise handles (C) | promise handles, callback forms: arch §Generated facade, guide:concurrency; blocking wait revisit: dropped: resolved (bang waits, KK); optionsOrPredicate: guide:migration; function URL matchers, URLPattern: arch §URL globs; glob cache: arch §URL globs; `@events` atoms: code (generator) |
| 5 | 2026-11-04 ElementHandle, JSHandle, setInputFiles (A) | `String.Chars` preview, subclass dispatch: code, PORTING §Idioms (`impl/1`); inputValue no options: code (ApiRules); WritableStream `Collectable`: arch §BEAM; test deviations: code; `test/support/utils.ex`: PORTING §Tests |
| 6 | 2026-11-04 fetch / APIRequestContext (G) | four modules, verb shadowing, `Object<K,V>`: code; request data (`{:binary, b}`, `:null`, keyword lists): arch §Value mapping, arch §BEAM; Buffer typing, compact JSON, nested `:null`: dropped: resolved (F, round 2, N); test fixtures: code |
| 7 | 2026-11-04 Routing, HAR, WebSocketRoute (F) | 1- or 2-arity handlers, `string\|Buffer`: arch §Value mapping; globs via driver: arch §URL globs; `_savedZone`, WebSocketRoute server: code (moduledoc deviations); `route` returns nil: dropped: superseded (Disposable, H); MimeType: arch §BEAM (kept ports); Bandit `compress: false`: arch §Test infrastructure; recordHar: dropped: resolved |
| 8 | 2026-11-05 Matchers (E) | one Expect module, `not_`, `to_have_screenshot(path:)`, not-ported list: arch §Generated facade, guide:migration (Known gaps); `to_have_attribute` merge: dropped: superseded (orOptions, KK); ExpectError: code; MatcherUtils: arch §BEAM; expect timeout: guide:migration |
| 9 | 2026-11-05 Bindings, init scripts, Disposable, locator handlers (H) | page callbacks, init script function source: arch §Value mapping; Disposable: code, #draft-15 (type); try/finally: code |
| 10 | 2026-11-05 Artifacts, tracing, video, screencast (I) | streams as Enumerables: arch §BEAM; onFrame promise: #draft-14; listener stacks: code; tail calls drop callers: dropped: inherent BEAM limit; Tracing `coverage:`: guide:migration (Behaviour changes) |
| 11 | 2026-11-05 Clock, Coverage, WebStorage, CDPSession, Selectors, Debugger, Credentials, WebMCP (J) | CDP events by string, `CDPSession.send`: code (ApiRules `@open_events`); Date as DateTime: arch §BEAM; sync members take the baton: dropped: obsolete (no baton); credentials revisit: dropped: resolved (TT); debugger Task locations: dropped: inherent BEAM limit |
| 12 | 2026-11-05 Browser lifecycle, connect (K) | connect via LocalUtils/JsonPipe: arch §Port and versions; `\|\|` on close reason: code; run-server only: dropped: superseded (BB2); heaps/errors revisit: dropped: resolved; Electron/Android: code (parity `@unported_client_files`) |
| 13 | 2026-11-05 Which upstream specs to mirror | arch §Mirroring upstream specs, PORTING §Tests (north star); per-file list: dropped: superseded by the registry (MM); poll helpers: PORTING §Tests |
| 14 | 2026-11-05 Mirrored page specs (groups 1-4) | browser checks and `test.fail` as refute: dropped: superseded (skip tags, `expected_failure/2`, PORTING §Tests); nested describes: PORTING §Tests; snapshot skips: dropped: resolved (U2); waitForLoadState(load) skip: dropped: resolved (Phase 1) |
| 15 | 2026-11-05 Stale-skip sweep and page specs group 5 | `to_pass`/`poll`, Agent for listener state: PORTING §Tests; close-code skips: dropped: resolved (DD); `date` header: code (test comment); browser guards: dropped: resolved (final skip sweep) |
| 16 | 2026-11-05 Remaining members, release gate, teardown (L) | release gate: arch §Generated facade; storage state open map: arch §Generated facade, #draft-15; listener promise leak, calls on a stopped loop: dropped: obsolete (OTP runtime); preloaded modules: arch §Runtime; `pause`, `pdf` px: code |
| 17 | 2026-11-05 Library specs group 8 | events/* specs: dropped: obsolete (Node EventEmitter specs dropped when EventEmitter was trimmed); proxy: dropped: resolved (TestProxy); `_coverage`: code; logger: dropped: resolved (N) |
| 18 | 2026-11-05 Library specs group 6 | TestProxy: arch §Test infrastructure; `addCookies` open object: arch §Generated facade (open maps); TLS renegotiation: dropped: resolved (tls_renegotiation_server.js); bfcache: code; driver crash: #draft-12 |
| 19 | 2026-11-05 Library specs group 7, `once` fix | OnceWrapper, extensions channel: code; device_options: dropped: resolved (N); own EventLoop: dropped: obsolete; connect-to-worker race: #draft-10; headful/multiclient bodiless: dropped: superseded (`:headed`, BB2) |
| 20 | 2026-11-05 Direction check 2 | heap GC: dropped: obsolete (OTP runtime, arch §Runtime); JSON null etc.: arch §Value mapping; stale skips: PORTING §Tests; `signal:` dropped: dropped: superseded (X) |
| 21 | 2026-11-05 Flaky tag | `flaky:` prefix: arch §Mirroring upstream specs, PORTING §Tests; the three tags: dropped: resolved (CC) |
| 22 | 2026-11-05 Library specs groups 9-10; spec mirroring complete | counts: dropped: superseded by parity/registry; bugs: dropped: resolved; storage-state error text: dropped: superseded (Node ENOENT, arch §BEAM); helper modules top-level: PORTING §Tests; not portable: code (upstream_not_ported.txt) |
| 23 | 2026-11-05 Migration guide | guide:migration; awkward names: dropped: resolved (EE); `Selectors.register` once per driver: guide:migration; saveAs canceled: dropped: upstream behaviour (T) |
| 24 | 2026-11-05 Review fixes (N) | JSON null: arch §BEAM, §Value mapping; `logger` callback objects: arch §Generated facade; expect defaults: guide:migration; device descriptors: arch §Value mapping; fresh state on re-created guid, parity root module, `highlight(style:)`: code |
| 25 | 2026-11-05 Heap GC and Map order (M) | tracing GC: dropped: obsolete, named as superseded in arch §Runtime; Map order: arch §Runtime |
| 26 | 2026-11-05 Final skip sweep | skip tags per browser: PORTING §Tests; proxy ipv6: code; glob specs: dropped: superseded (LL); firefox CC: dropped: resolved (GG) |
| 27 | 2026-11-05 EventEmitter completed (O), stale-skip check (P) | 1:1 EventEmitter: dropped: superseded (trimmed to what the client uses, EventEmitter moduledoc); one `emit` arg, removeAllListeners: code (moduledoc); stale-skip check: PORTING §Tests; flaky tags: dropped: resolved |
| 28 | 2026-11-05 Completeness checks (S) | every upstream file: PORTING §Rules, §Tests; unported client files: code (parity task); counts: dropped: stats |
| 29 | 2026-11-05 Locator rendering in Elixir (R) | arch §Driver language and rendering; RegExp struct: arch §Value mapping; install hint: arch §Driver language; chromium-only install: dropped: resolved (One CI matrix) |
| 30 | 2026-11-05 Firefox/WebKit runs (T), CI-only failures (Q) | CI job: dropped: superseded (arch §CI); test-server loopbacks, closing contexts: arch §Test infrastructure; `env:` confirmed with Node: arch §Mirroring, PORTING §Tests; saveAs canceled: dropped: upstream behaviour; Service Worker `ci:` skips: dropped: resolved (none left); subscription batching: arch §Runtime; `Task.await_many` infinity: PORTING §Tests |
| 31 | 2026-11-05 toMatchSnapshot via the driver's comparator (U2) | arch §Test infrastructure; oopif screenshot `env:`: code |
| 32 | 2026-11-05 VideoPlayer (U1) | arch §Test infrastructure; Mac WebKit gray frames: #draft-17 |
| 33 | 2026-11-05 AbortSignal (X) | arch §BEAM (global AbortController); client and facade `signal:`: guide:migration (Errors); statics: dropped: not in api.json, unused; baton revisit: dropped: obsolete |
| 34 | 2026-11-05 Linux firefox/webkit CI (W) | `Upstream.ensure!` lock, TestBrowser, module skips: code; Linux env skips: arch §CI (xvfb), #draft-11 (Partitioned cookies); racing waits via `Promise.async`: PORTING §Tests |
| 35 | 2026-11-05 Driver message batching (Y) | dropped: superseded by per-turn buffering (arch §Runtime names it); worker console races: #draft-10 |
| 36 | 2026-11-05 Final fidelity audit, fixes (Z) | fixes: dropped: done; keyword lists for URLSearchParams/FormData: arch §BEAM; storage-state indent: arch §BEAM (final form, round 2); xvfb: arch §CI; firefox GC loop `env:`: dropped: obsolete (test went with the GC); webkit form-post flaky: dropped: resolved (CC) |
| 37 | 2026-11-05 Local URL glob matching (AA) | dropped: reverted by LL (arch §URL globs names it); 10 s `assert_receive`: PORTING §Tests; expectedSSLError: code; flaky tags: dropped: resolved (CC) |
| 38 | 2026-11-05 One CI test matrix | arch §CI; ruleset: #draft-4; launchServer specs: arch §Test infrastructure; install default browsers: code (Driver) |
| 39 | 2026-11-05 TestServer WebSocket framing (DD) | arch §Test infrastructure (superseded in part by SS) |
| 40 | 2026-11-05 URL globs through the driver again (LL) | arch §URL globs |
| 41 | 2026-11-05 Facade docs for the Elixir API (II) | arch §Generated facade; JS examples: #draft-1 |
| 42 | 2026-11-05 Top-level errors, facade structs, optionsOrPredicate (EE) | arch §Generated facade; optionsOr: guide:migration, code; open docs: #draft-2 |
| 43 | 2026-11-05 launchServer specs (BB2) | arch §Test infrastructure; SIGHUP exit codes, SI-007..009: code; connect reuse scenarios kept: dropped: decided (kept); explicit stop: dropped: superseded (OO) |
| 44 | 2026-11-05 Upstream test registry (MM) | arch §Mirroring upstream specs, PORTING §Tests |
| 45 | 2026-11-05 GC fixes (JJ) | dropped: obsolete (OTP runtime); pause figures kept in arch §Runtime |
| 46 | 2026-11-05 Global AbortController, Expect.not_, bang waits (KK) | arch §BEAM; aborted-signal row: dropped: superseded (rows freed when the creator exits, abort_signal moduledoc); `not_`, bang waits: arch §Generated facade, guide:migration; orOptions: guide:migration |
| 47 | 2026-11-05 Fixtures exit with the test BEAM (OO) | arch §Test infrastructure; `--inspect-brk` window: dropped: accepted, test-only |
| 48 | 2026-11-05 Heap lifetimes without tracing (design study) | dropped: not taken; named as the rejected alternative in arch §Runtime |
| 49 | 2026-11-05 Flake causes and fixes (CC) | UpstreamCase timeouts: arch §Test infrastructure; firefox non-blocking: dropped: firefox blocks since 2026-11-06; connect_to_worker: #draft-10 |
| 50 | 2026-11-05 Stdlib in place of JS ports (QQ) | arch §BEAM (kept jest-style messages, URLSearchParams); `:json.format`: dropped: superseded (round 2 layout); Regex PCRE-only raises: arch §Value mapping; RegExp open: dropped: resolved (RR) |
| 51 | 2026-11-05 OTP-native runtime spike (PP) | arch §Runtime, §Ordering; effort estimate: dropped: history |
| 52 | 2026-11-05 Test WebSocket framing via cowlib (SS) | arch §Test infrastructure |
| 53 | 2026-11-05 Public RegExp, stdlib form encoding (RR) | RegExp: arch §Value mapping, guide:migration; `URI.encode_www_form`: dropped: superseded (WHATWG serializer, arch §BEAM); macOS hang: dropped: resolved (Phase 0) |
| 54 | 2026-11-05 credentials.create takes the returned credential (TT) | arch §Value mapping, §Generated facade (`@result_options`), guide:migration |
| 55 | 2026-11-05 OTP-native runtime, Phase 0 done | arch §Runtime, §Object lifetimes; failing tests: dropped: resolved (Phase 1) |
| 56 | 2026-11-05 OTP-native runtime, Phase 1 done | arch §Ordering, PORTING §Shims; merge order and agent notes: dropped: history |
| 57 | 2026-11-05 after Phase 1 | subscribe-first and `Promise.free/1`: guide:concurrency, arch §Ordering; `on_reply`: PORTING §Shims, arch §Ordering; waiter rejection: arch §Ordering, guide:concurrency, #draft-5; test timeouts: arch §Test infrastructure; workers_test:237: #draft-10; Linux harness: PORTING §Tests; upstream-update workflow: arch §CI, PORTING §Bumping; ruleset: #draft-4; config audit, parity pass: dropped: done (round 2); 1.62 cache error: dropped: history (memory has it); north star: arch §Mirroring |
| 58 | 2026-11-05 north-star ports and harness fidelity | north star and its exceptions: code (upstream_not_ported.txt); second driver, `__testHook*`: arch §Test infrastructure; `:headed`: PORTING §Tests, arch §CI; Selenium: code (CI comments); harness defaults: arch §Test infrastructure; apt retries: code (workflow); remote_server launch options: dropped: resolved (VF-H) |
| 59 | 2026-11-05 parity pass (round 2) | process and counts: dropped: history; RO-033: arch §Ordering; dying listener, once unsubscribe, abort race, one trace per call: arch §Ordering, code; leak warning, tombstone, "Error" name: arch §Object lifetimes, code (EventEmitter moduledoc); `Node.path_resolve/1`, `Node.fs!/3`: PORTING §Tests, arch §BEAM; `@browser_name`/`@browser_major_version`, `slow()`: PORTING §Tests, arch §Mirroring; `Utils.assert_truthy/1`: PORTING §Tests; H-16: PORTING §Tests; H-17: arch §CI; VF-D2: arch §BEAM; HAR flake: #draft-6; `number_to_string`: #draft-13; VF-D1: arch §Value mapping; VF-C2: #draft-16; C3a-10, VF-E macOS WebKit: #draft-17; X-01 `Promise.async`/`void` idiom: PORTING §Tests; Phase 2 backlog (remote Conn stop, process aliases, `await_all_atomic`, `async_once`, params as a function): arch §Object lifetimes, code (markers); VF-C1, VF-B, VF-A1, VF-A2, VF-C3, X-03, A2b-06, C3a-14, modernizr, `set_test_id_attribute`, `_retire`, OOPIF click: code (deviation markers, test comments) |

## PLAN.md (12 sections)

| Section | Where it went |
|---|---|
| Intro (mirror 1:1, generated contract) | arch §Port and versions, §Generated facade |
| Layers | arch §Layers (baton and GC lines rewritten); removed modules: guide:migration |
| Public API (generated) | arch §Generated facade (shapes, handles, names, waits); keys and options: guide:migration (Concepts); timeouts and `Task.yield`: guide:migration; `on/3` queued subscription: dropped: obsolete (baton tick) |
| Concurrency: baton | dropped: superseded; arch §Runtime names it and its costs |
| Infrastructure | arch §Port and versions (driver, remote, no version check), §Layers; spike figures: dropped: history |
| Tracking upstream | PORTING (Rules, Bumping), arch §Port and versions |
| Decisions | versions: arch §Port and versions; globs: arch §URL globs; sdkLanguage: arch §Driver language; bytes, names, evaluate, bindings, nil/`:null`: arch §Value mapping, §Generated facade; inspect: arch §Driver language; GC: dropped: obsolete; AbortSignal, zones: arch §BEAM; to_have_screenshot, out of scope: arch §Generated facade; explicit `try`: code |
| Spike results | dropped: history (baton spike); its follow-ups: dropped: obsolete (baton, heap `update`, microtasks) or resolved (`run-server` SIGTERM by OO) |
| Consumers | arch §Generated facade (consumer requests); behaviour changes: guide:migration; JsLogger recipe: guide:migration |
| OTP-native runtime migration | arch §Runtime, §Object lifetimes, §Ordering; shim rules: PORTING §Shims; listener kinds: arch §Ordering, EventEmitter moduledoc; phases, groups, merge order: dropped: history; risks: arch §Ordering, guide:concurrency (blocking listeners); docs to-dos: done here |
| Quality gate: full parity pass | dropped: done (round 2, DECISIONS entry 59) |
| Before merging: preserve decisions | dropped: done by this pass |
| Then | 1-4: dropped: done (arch §Generated facade, §Driver language describe the result); 5 JS examples: #draft-1 |

## test/OTP_BACKLOG.md

| Item | Where it went |
|---|---|
| Waiter rejection | arch §Ordering, guide:concurrency, #draft-5 |
| Route handler at teardown (RO-033) | arch §Ordering; dropped as an issue: decided |
| HAR `unrouteAll` flake | #draft-6 |
| Watch list (4 tests) | #draft-8 |
| page_close continue while closing | #draft-7 |

## Stats

Counted by script over the cells above.

- DECISIONS: 60 rows. First-named destination: arch 33, dropped 13, code 7, PORTING 4, issue 1,
  guide 2. References across all bullets: arch 95, PORTING 33, guide:migration 14,
  guide:concurrency 3, issue drafts 23 (15 distinct), code 41, dropped 72.
- Dropped bullets (72): resolved, superseded, reverted or done by a later entry 47; obsolete with
  the baton/GC/EventLoop 10; history, process notes or stats 5; decided, accepted, inherent BEAM
  limit, not taken or not in api.json 7; upstream behaviour 2; one duplicate wording (`signal:`).
  None is dropped without a reason.
- PLAN: 13 rows (12 sections plus the intro). First-named: arch 8, dropped 5 (baton concurrency
  superseded; spike results, quality gate, preserve-decisions and Then 1-4 done or history).
- OTP_BACKLOG: 5 rows: arch 2 (waiter rejection, RO-033, both with an issue or decision), issue 3.
- Issue drafts: 17 (`#draft-1`..`#draft-17`), each referenced at least once.
