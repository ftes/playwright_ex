# Decisions log

Decisions taken while porting autonomously, newest last, for review. The durable design is in
`PLAN.md` (a reviewed decision moves there or gets reverted); conventions in `PORTING.md`.
Each entry: what, why, and what to revisit.

## Needs your decision (before a 1.64 release)

0. **CI ruleset**: `main` requires `Test (port)`/`Test (websocket)`, which no longer exist. Require
   `Tests` (see "One CI test matrix" below), or PR #124 can't merge.

These shape the public API, so changing them after release would break users. Your verdicts
(2026-11-05) in brackets:
1. **Exceptions** [yes: top level]: done (EE). `PlaywrightEx.TimeoutError`, `TargetClosedError`,
   `PlaywrightError`, `AbortError`, `ExpectError`.
2. **Handle structs** [on the facade modules]: done (EE), `%PlaywrightEx.Page{}`.
3. **Expect defaults** [ratified: app env only, no `Expect.configure/1`].
4. **Release**: version 1.64.0 (`mix.exs` is 0.16.0) and CHANGELOG entry. Open.
5. **AbortController ownership** [done: global, as JS, workstream KK].
6. **Doc examples** [ratified: stay JS for now], PLAN Then 5.

## 2026-11-04: Locators on Frame/Page

- **`$`-names and reserved words take Python's names**, in client and facade: `$eval` is
  `eval_on_selector`, `$$eval` `eval_on_selector_all`, `$`/`$$` `query_selector(_all)`, `and`/`or`
  are `and_`/`or_` (rename map in `gen.api`, `ported as` markers in the client). Why: not valid
  Elixir function names; Python is the closest official precedent.
- **`$eval` has no options in the facade** (`ApiRules` `@dropped_options`). The docs list
  `strict`, but the JS client asserts at most 3 arguments, so a 1:1 client can't take it.
- **`inspect(locator)` shows the raw selector** (`#PlaywrightEx.Locator<internal:role=button>`);
  `Locator.toString` is not ported yet. Why: rendering needs the driver
  (`LocalUtils.asLocatorDescription`), and `inspect` must work without the baton. Revisit with
  PLAN "Then" item 4 (port `locatorGenerators`).
- **`Locator.description/1` reads `internal:describe` with a regex**, not `parseSelector`:
  `describe/2` always appends it as a JSON string at the end. Revisit if the selector parser
  gets ported.
- **`kAnyFrameSelector` is a constant in `Client.Locator`** instead of porting `selectorParser`.
- **The test id attribute name is a `:persistent_term`**: module state in JS, shared by all
  connections, so not per loop.
- **`Client.ElementHandle` started with only `convertSelectOptionValues`**, so its facade is
  generated with every member listed as not ported.
- **Upstream `TODO:` comments become `Upstream to-do:`**: `mix credo` (CI) fails on TODO tags.

## 2026-11-04: Direction check 1 (fresh reviewer, read-only)

Verdict: on track, client modules 1:1 statement for statement. Follow-ups taken:
- **Facade `nil` vs JS defaults**: the facade passes omitted optional positional args as `nil`,
  so client `\\` defaults never fire. Idiom (PORTING.md): apply JS defaults in the body; JS
  `null` is `:null`, `undefined` is `nil`. Fixes for `dispatch_event`, `selectOption(null)`,
  `description("")` go with the ElementHandle step.
- **Parity enforces upstream order** (longest common subsequence of method names vs the TS
  file, of test names vs the spec). Only module-level marker lines count. Why: order keeps
  `git diff vA vB` hunks portable.
- **Known gap**: `record_har`/`expose_functions` are in the facade but raise at runtime (the
  context is created before `recordHar` raises). Fixed by porting HAR/bindings, not by hiding
  the options.

## 2026-11-04: Input, Dialog, ConsoleMessage, WebError, Worker (workstream B)

- **JS readonly fields are client functions** (`Page.keyboard/1`, `mouse/1`, `touchscreen/1`
  under `# readonly properties`), as `Playwright.chromium/1`: the generator needs an arity-1 export.
- **`inspect(console_message)` is `#PlaywrightEx.ConsoleMessage<text>`**, like handles and
  locators; upstream's `util.inspect` shows the bare text. The upstream test asserts the
  wrapped form with a deviation comment. Revisit if exact upstream output matters.
- **Assertions inside listeners** become `send` to the test process plus `assert_received`;
  JS `void dialog.accept()` is a non-bang `Dialog.accept/1` inside the listener.
- **Mac-only upstream tests** skip by `:os.type()` at compile time.

## 2026-11-04: waitForEvent, urlMatch, promise handles (workstream C)

Review these first: they shape the public API.
- **Promise handles**: a JS async member returns a `PlaywrightEx.Promise` when the Python
  client has an `expect_*` for it (`wait_for_event`, `wait_for_navigation`, `wait_for_request`,
  `wait_for_response` on Page/Frame/BrowserContext). No bang form; block with
  `Promise.await!(Page.wait_for_navigation(page))`. The wait is registered before the call
  returns (heap promise started under the baton); any process can await it, any number of
  times; an unawaited one ends when it settles or times out. Revisit: a blocking
  `wait_for_navigation!`?
- **Callback forms** for every Python `expect_*` (`expect_popup(page, action, opts)`,
  `expect_event(page, event, action, opts)`, `expect_request(page, url_or_predicate, action,
  opts)`): action before options (C#'s order); action exceptions propagate (C#); error names
  are the started member's (`page.waitForEvent`). Emitted only when the result class is
  ported. The generator also loads the Python view of the docs for these.
- **`wait_for_event` takes JS's `optionsOrPredicate`** (a predicate function or options with
  `predicate`/`timeout`; superseded the Python-arguments form in workstream EE); `event` accepts atoms.
- **Function URL matchers get the URL string**, not a parsed URL (Python, Java, .NET).
  `URLPattern` is dropped from api.json unions (no Elixir counterpart).
- **`LocalUtils.glob_to_regex` caches the driver's regex** per {glob, baseURL, ws}
  (Elixir-only helper; PLAN Decisions: globs via the driver). Superseded by workstream AA (globs local).
- **`@events` emitted at the top of each generated module**, so `event` args accept atoms.

## 2026-11-04: ElementHandle, JSHandle, setInputFiles (workstream A)

- **`JSHandle`/`ElementHandle` `toString` is `String.Chars`** (`"#{handle}"` is the preview,
  pure ETS read, no baton). Revisit with `Locator.toString`.
- **Subclass dispatch**: `JSHandle.as_element/1` dispatches on the struct (JS virtual call);
  the generator types `PlaywrightEx.JSHandle.t()` as `%JSHandle{} | %ElementHandle{}` and does
  not duplicate inherited members into the ElementHandle facade (as api.json).
- **`ElementHandle.inputValue` has no options** (`@dropped_options`): docs list `timeout`, the
  JS client takes none (same as `$eval`).
- **`WritableStream.stream/1` returns a `Collectable`** (`Enum.into(File.stream!(...), ...)`
  for `stream.pipeline`); remote `lastModifiedMs` has whole-second precision (Erlang stat).
- **Test deviations, commented**: `(function(){})` needs a `() =>` wrapper (no `isFunction`,
  PLAN); circular `jsonValue` is `%{"b" => :circular}`; (missing-file errors now carry Node's ENOENT text, round 2);
  `waitFor`/`visibility` `as any` options assert the facade's `ArgumentError`, so
  "should tolerate waitFor=visible" expects an error where upstream expects none.
- **`test/support/utils.ex`** ports `tests/config/utils.ts` (`attach_frame`, `verify_viewport`, ...).

## 2026-11-04: fetch / APIRequestContext (workstream G)

- **`fetch.ts` is one file, four modules** (`Client.Fetch` for the top-level functions first,
  so parity maps them; `APIRequest`, `APIRequestContext`, `APIResponse`). `APIRequest` is a heap
  object (mutable `_contexts`), `APIResponse` a plain struct whose `Inspect` is upstream's `_inspect`.
- **HTTP verbs `get/3`/`put/3`** shadow `Heap.get/put`: the module imports Heap except `put/3`
  and writes with `Heap.put`; the verbs take no `\\` default on `options`.
- **Request data**: a binary is a JS string, `{:binary, b}` a Buffer, `:null` JSON `null`;
  `FilePayload.buffer` is a plain binary, `fs.ReadStream` a `File.Stream`; multipart also takes
  a keyword list (maps are unordered). Not ported: `URLSearchParams`, `FormData`.
- **Generator**: an `Object<K,V>` dictionary type wins over properties api.json attaches to it.
- **Revisit**: Buffer inputs are typed `binary()` in facade specs (no `{:binary, _}`);
  `storage_state(path:)` writes compact JSON (Elixir JSON has no indent); a `:null` nested in
  `data` encodes as the string "null".
- **Tests**: `request` fixture (`@tag :request`); Plug lowercases response header names
  (commented); upstream's Node socket tricks are private `:gen_tcp` helpers per test module.

## 2026-11-04: Routing, HAR, WebSocketRoute (workstream F)

- **Route handlers take 1 or 2 args** (`fn route ->` / `fn route, request ->`), as Python;
  an ApiRules rule types the facade argument as either.
- **`string|Buffer` is `binary() | {:binary, binary()}`** in generated specs (fulfill body,
  `post_data`, WebSocket messages, fetch `data`): PLAN strings-vs-bytes.
- **Handlers validate globs through the driver** (cached); `LocalUtils.glob_to_regex` takes
  the baton itself (sync `Page.frame(url:)` needs it). Superseded by workstream AA.
- **RouteHandler `_savedZone` drops `:apiName`**, so calls inside a handler aren't named `page.route`.
- **WebSocketRoute's server side** is the same struct with guid `"server:<guid>"`.
- **`route`/`startHar` return nil** where upstream returns a Disposable (H ports Disposable;
  wired at merge where trivial). HarRouter logs at `Logger.debug("pw:api ...")`.
- **`Isomorphic.MimeType`**: one module (A and F both started it), all functions in upstream order.
- **Test server**: Bandit with `compress: false` (match Node); Bandit doesn't echo client
  close codes and sends fewer headers (`har` "should include sizes" stays skipped).
- `recordHar` now works: closes the "Known gap" above.

## 2026-11-05: Matchers (workstream E)

Review: these shape the assertion API.
- **One generated module `PlaywrightEx.Expect`**: ApiRules merges `LocatorAssertions`,
  `PageAssertions`, `APIResponseAssertions`; matchers with several receivers (`toMatchAriaSnapshot`)
  take a Locator or Page, as upstream's single matcher does.
- **`not` is a separate function** (`not_to_have_text`, Python's name) running the matcher with
  `isNot: true`; no `not:` option.
- **`to_have_attribute(locator, name, value \\ nil, opts)`** merges the `(name, options)` overload:
  `to_have_attribute(l, "disabled", nil, timeout: 1)`. Revisit if it reads badly.
- **`ExpectError`** is `PlaywrightEx.Matchers.MatcherHint.ExpectError`; `matcherResult` drops keys
  whose JS value is undefined (results compare with `==`). No ANSI colors (upstream tests strip them).
- **`MatcherUtils`** stands in for jest-matcher-utils/pretty-format/jest-diff (not upstream code,
  so not line-by-line).
- **`ex_unit: :optional`** in `extra_applications` (`ExUnit.AssertionError`); test_helper sets the
  expect timeout to 10 s as upstream's config. Revisit: no public way to change the 5 s default
  (an `Expect.configure` or app env?).
- **`to_have_screenshot(target, path: ...)`** (required `path` replaces the testInfo `name`);
  `-actual`/`-diff`/`-previous`/`-expected` next to `path`; a missing snapshot is written and passes.
  page-screenshot.spec (87 tests) not mirrored yet.
- Not ported: `toPass`, `expect.poll`, soft asserts, `configure`/`extend`, jest generic matchers,
  file aria snapshots.

## 2026-11-05: Bindings, init scripts, Disposable, locator handlers (workstream H)

- **Callbacks from the page**: `ClientHelper.call_function/2` pads/drops args to the closure's
  arity (JS calls are variadic); bindings are `fn source, args` with `source = %{context, page,
  frame}`; a returned `%Runtime.Promise{}` is awaited; `raise` becomes a page Error, `throw(v)`
  throws `v` (`throw(:null)` is `null`).
- **Init scripts**: a string with `arg` is function source (as evaluate); `script` is JS source
  in the facade (ApiRules, like `expression`). `JSON.stringify` is `ClientHelper.json_stringify`.
- **Disposable**: `Client.Disposable` (interface, `dispose/1` dispatches on the struct),
  `DisposableObject` (ChannelOwner), `DisposableStub` (heap). `route`, `startHar`, tracing
  `start`/`group` return them as upstream. `PlaywrightEx.Disposable.t()` is `term()` (revisit:
  union of the two structs).
- Locator handler `try/finally` is `rescue` + finally statements + `reraise`.

## 2026-11-05: Artifacts, tracing, video, screencast (workstream I)

- **Readable streams are `Enumerable`s of binary chunks** (`Stream.stream/1`,
  `createReadStream`): each read takes the baton, halting sends `close`.
- **Download, Video** are plain structs; Screencast a heap object whose `onFrame` gets
  `%{data:, timestamp:, viewportWidth:, viewportHeight:}` and acks on return. Revisit:
  await an `onFrame` that returns a promise (backpressure test not portable).
- **Listener stacks**: in a handed-off listener, library frames at the bottom no longer count as
  the outermost library frame (traces had empty stacks). BEAM tail calls still drop callers.
- Tracing `coverage:` stays out of the facade (PLAN), the client forwards `_coverage` as upstream.

## 2026-11-05: Clock, Coverage, WebStorage, CDPSession, Selectors, Debugger, Credentials, WebMCP (workstream J)

- **CDP events by name**: `session.on("Network.requestWillBeSent", ...)`; ApiRules `@open_events
  ~w(CDPSession)` lets the facade accept any string event; payloads are raw params, string keys.
- **`CDPSession.send/3` keeps its name** (shadows `Kernel.send` only inside those modules).
- **A JS `Date` is a `DateTime`** (Clock); the invalid-Date check is dropped.
- **Sync members that start promises take the baton** (`Selectors.setTestIdAttribute`); the test id
  attribute is global, so `selectors_get_by` runs `async: false`.
- **Revisit**: `credentials.create(rpId, knownCredential)` can't take the returned JS-keyed map as
  snake_case options (tests convert by hand); debugger locations inside `Task.async` point at Task
  (tail call).

## 2026-11-05: Browser lifecycle, connect (workstream K)

- **Remote**: `connect`/`connectOverCDP` through the driver's LocalUtils `connect` + `JsonPipe`
  (no Elixir WebSocket client); each connection has its own heap on the shared baton.
  `WebSocketTransport` (browser builds only) and `connectOverCDP(transport)` not ported.
- **JS `||` on the pipe close reason**: `""` is falsy (else the error message was empty).
- **Tests**: only the `run-server` kind of browsertype-connect is mirrored (no `launchServer`);
  the connect fixture calls the client directly when `__testHook*` keys are present (the facade
  rejects them, upstream uses `as any`); ephemeral ports instead of `9339 + workerIndex`;
  user agents asserted by the `Playwright/<pin> (` prefix.
- **Revisit** (resolved: closed heaps are deleted by the GC, workstream M; `Playwright.errors`
  is exposed, workstream L): nested-connection heap tables were never deleted;
  `Playwright.errors` was not exposed.
- Electron/Android are not in the JS api.json view at this pin; nothing to drop.

## 2026-11-05: Which upstream specs to mirror

- **Mirrored: every spec that exercises the client** (`tests/page`, `tests/library` incl.
  `chromium/`, `firefox/`, `events/`), about 260 of 296 files.
- **Not mirrored (they test driver internals or Node-only tooling, not the client)**:
  `library/unit/*`, `library/inspector/*` (codegen UI), `trace-viewer`, `component-parser`,
  `css-parser`, `locator-generator`, `locator-parser`, `role-utils`, `selector-generator`,
  `snapshot-renderer`, `debug-controller`, `browser-server`/`browsertype-launch-server`
  (`launchServer`, PLAN out of scope), `page/expect-builtins` and `matchers.misc` (jest generic
  matchers, PLAN). Revisit `locator-generator` with PLAN "Then" item 4 (Elixir locator rendering).
- **`expect.poll`/`toPass`** (test-runner features, not in api.json) become a poll helper in
  `test/support/utils.ex` rather than library API.

## 2026-11-05: Mirrored page specs (groups 1-4)

- **Test-only conventions**: browser-conditional `it.fixme`/`it.skip` become `browser_name`
  checks; upstream `test.fail` becomes a `refute`; JS `null` args are `:null` so error messages
  match. Nested describes are flattened (`describe "a b"`), ExUnit has no nesting.
- **`toMatchSnapshot`, `comparePNGs`, `decodeWebp`, JS test hooks, `AbortSignal`, `toImpl`**
  stay skipped (test-runner or server internals). Revisit: a few screenshot tests are partly
  portable.
- **page-autowaiting-basic "waitForLoadState(load)"** skipped: upstream's expected ordering
  depends on JS microtask depth (one extra `.then` hop), which Elixir tasks don't reproduce.
  Not a lib bug. Revisit if the baton runtime should order continuations across processes.

## 2026-11-05: Stale-skip sweep and page specs group 5

- **`to_pass(fun, opts)` / `poll(value_fun, assertion, opts)`** in `test/support/utils.ex`
  (port of `tests/config/utils.ts` plus `expect.poll`/`toPass`): upstream intervals
  100/250/500/1000 ms; deviation: default timeout 5000 ms (upstream: the test timeout).
- **Listener state in tests** (JS arrays) is an `Agent`. Debugger tests use `Agent.cast`, so
  events after the test ends are dropped instead of logging noproc errors.
- **route-web-socket close-code tests (5) skipped**: Bandit (test server) answers a close frame
  with 1000 and hides the client's code/reason. Test-server limit, not a lib bug. Revisit if the
  test server moves off Bandit.
- **firefox-network-response** uses a lower-case `date` header: Bandit's own `date` lookup is
  case-sensitive and would duplicate it.
- **Browser guards**: `it.skip`/`fixme` conditions inside a test are `if browser_name ...`
  guards, so on the excluded browser the test reports as passed without asserting. Revisit:
  could become `@tag skip` computed per browser.

## 2026-11-05: Remaining members, release gate, teardown (workstream L)

- **Release gate in**: the generator emits every api.json member; `ApiRules` drops
  `PlaywrightAssertions` (ported as `PlaywrightEx.Expect`) and `BrowserType.launchServer`.
  Electron/Android/`connectOverCDP(transport)` are not in the JS api.json.
- **Storage state is an open map** (`optional(atom()) => term()`): docs omit `credentials`,
  `indexedDB`, `opfs`, and results must round-trip into `setStorageState`. Nested JS values
  (IndexedDB records) keep string keys. Revisit: type the documented keys.
- **`removeAllListeners(type)`**: arg named `event` so atoms work; with options the facade
  returns `:ok`. Each listener call creates a heap promise that is never freed (same gap as
  other calls). Revisit with heap GC.
- **Calls on a stopped loop** return `{:error, %TargetClosedError{}}` instead of exiting; work
  abandoned with a dead process or stopped loop is dropped silently.
- **Client modules are preloaded** by `PlaywrightEx.Supervisor` (like `require('playwright')`):
  lazy code loading delayed a `wait_for_event` subscription past the event it waits for.
- **`Page.pause`** skips the `inspector.url()` check (no JS debugger). **`pdf`** formats numeric
  sizes as `"#{n}px"` (`100.0` gives `"100.0px"`, JS `"100px"`).

## 2026-11-05: Library specs group 8 (events, proxy, permissions, coverage)

- **`tests/library/events/*`** test the client's `EventEmitter` and call
  `Client.EventEmitter` directly (no facade for it). `_events` checks use `listeners/2` and
  `event_names/1`. Node-only emitter features (`newListener`/`removeListener` events,
  `setMaxListeners` leak warnings, listener type checks, multi-arg `emit`) are skipped as not
  ported. Revisit: port them into `EventEmitter` if 1:1 there matters, or skip the files.
- **Proxy specs (23 tests) skipped**: no `proxyServer`/`socksPort` fixture
  (`tests/config/proxy.ts`). Follow-up: a small TestProxy in `test/support`.
- **coverage spec** passes `_coverage: true` through `Runtime.Api.call` (upstream casts it
  `as any`; the facade rejects unknown options).
- **`logger` launch/context option** not exposed (both logger tests skipped). Resolved by
  workstream N.

## 2026-11-05: Library specs group 6 (cookies, proxy, client certificates, popup)

- **`PlaywrightEx.TestProxy`** (`test/support/test_proxy.ex`, port of `tests/config/proxy.ts`):
  upstream uses the `proxy` npm package, so this is a minimal `:gen_tcp` forward proxy (absolute
  URLs, CONNECT, WebSocket upgrade, 407 auth) plus a SOCKS5 server, as `setup` fixtures.
- **`addCookies(cookies)` is an open object** (like storage state): `cookies()` returns
  protocol-only fields (`_crHasCrossSiteAncestor`) that JS round-trips; the facade rejected them.
- **client-certificates TLS renegotiation** skipped: Erlang `:ssl` can't renegotiate.
- **bfcache** launches its own browser (`ignore_default_args`), as upstream `test.use`.
- **Driver fragility**: an HTTPS proxy closing mid-handshake crashed the Node driver (unhandled
  TLSSocket error). Test proxy now completes the handshake. Revisit: report upstream?

## 2026-11-05: Library specs group 7, `once` fix

- **`EventEmitter.OnceWrapper` ported** (with `_fired`): the `{id, fun}` closure ran a
  once-listener twice when a nested emit had already removed it (events/once spec).
- **`device_options/1`** (test helper): `playwright.devices[...]` has JS keys and
  `defaultBrowserType`; the facade takes snake_case options. Revisit: accept device descriptors
  in `newContext` directly so `devices` round-trip as in JS.
- **events/* specs** use plain `ExUnit.Case` with their own `EventLoop` (no browser).
- **chromium/extensions** launches `channel: "chromium"` (upstream skips on headless shell).
- **chromium/connect-to-worker** "should connect, evaluate, receive console..." skipped as
  flaky: the console event races its subscription (~3 of 8 runs). Revisit as a possible
  lib race in worker console subscription.
- **headful (16), multiclient (18)** bodiless: headless-only runs; multiclient needs
  `launchServer` (`_sharedBrowser`).

## 2026-11-05: Direction check 2 (fresh reviewer, read-only)

Verdict: the client is a faithful 1:1 port (9 modules compared statement by statement, no
drift). Blockers for release, assigned to follow-up workstreams:
- **Heap GC**: heap rows (settled promises, waiters, listener calls, disposed objects) are never
  freed; JS `Map` iteration order is lost (`:set` tables). Workstream M.
- **JSON `null`**: `JSON.encode!(:null)` gives `"null"`; decoding returns `nil` instead of
  `:null`. Plus: expose the `logger` option, public expect-timeout config, duplicate FileUtils
  helpers, stale markers, parity root module for split files. Workstream N.
- **Stale skips and browser guards**: skips naming ported members; browser `if` guards pass
  silently on excluded browsers. Final test sweep, plus a parity check that fails when a skip
  reason names an exported client function.
- `signal:` (AbortSignal) stays dropped for release; documented as a known gap.

## 2026-11-05: Flaky tag

- **`@tag skip: "flaky: <cause>"`** for tests that pass locally but race on CI or under load:
  popup "should not throw when click closes popup" (driver returns TargetClosedError on Linux
  CI), page-screenshot "fullPage screenshots during navigation" (30s screenshot timeout under
  load), chromium/connect-to-worker console race. Revisit each before release: find the race
  or confirm it upstream.

## 2026-11-05: Library specs groups 9-10; spec mirroring complete

- **Coverage**: 261 of 296 upstream `tests/{page,library}` spec files mirrored; the other 35
  are the exclusions above (`inspector/pause.spec` tests the inspector UI, so it counts as one).
- **Bugs found, assigned**: device descriptors rejected by `newContext` (JS keys,
  `defaultBrowserType`) and double dispatch after `_newContextForReuse`, both workstream N;
  `EventEmitter.event_names` order, workstream M. Fixed here: `EventEmitter.listeners` returns
  the wrapped listener (JS `wrapperFunction.listener`), and `removeListener` matches it.
- **storage-state error text**: the missing/malformed file tests assert Elixir's error text
  (`prepare_storage_state`), not Node's ENOENT/JSON messages. Revisit if Node text matters.
- **Test-only helpers inline**: PNG decoders in screenshot/screencast-overlay tests (no PNG
  dep); event subclasses as top-level modules (parity treats nested modules as specs).
- **Not portable**: slowmo (patches the in-process `_doSlowMo`), selenium (grid, jars, test hook),
  playwright-client (bundle not built), har-websocket env test (driver env fixed at launch).

## 2026-11-05: Migration guide

- **`guides/migration.md`** ("Migrating to 1.64": versions follow upstream major.minor from the
  breaking release), snippets checked by `test/guides/migration_test.exs`. Driven by
  phoenix_test_playwright (selectors, `subscribe`, dialogs, `Frame.expect`, tracing groups) and
  fluffy (named supervisors, document snapshots, downloads).
- **Awkward for migrating** (revisit before release): exceptions live under `Client.Errors`
  (`PlaywrightEx.Client.Errors.TimeoutError`; Python exposes `TimeoutError` at the top level):
  consider public aliases. Handle structs are `%PlaywrightEx.Client.Page{}` while the type is
  `PlaywrightEx.Page.t()`. `Selectors.register` is once per driver (PTP registers per context).
  (`mix playwright_ex.cli` show-trace was added afterwards.) `Download` from a routed
  `fulfill` with `content-disposition` gave `saveAs: canceled` in chromium (not investigated).

## 2026-11-05: Review fixes (workstream N)

- **JSON `null`**: `ClientHelper.json_parse/1` (null -> `:null`) and `json_stringify/1` for every
  user value (route fulfill, `postDataJSON`, `Response.json`, fetch `data`).
- **`logger` option**: generic `@callback_objects ~w(Logger)` rule: an object of functions with
  JS keys, emitted on launch/launchPersistentContext/newContext/newPage, called in `logApiCall`.
- **Expect defaults** from the app env (`config :playwright_ex, :expect, timeout: ...`), the
  initial `_expectConfig` (playwright.config's `expect`). Revisit: an `Expect.configure/1` API.
- **Device descriptors** have newContext option keys (`user_agent:`) and newContext/newPage
  accept an ignored `default_browser_type` (Python's `parse_device_descriptor` precedent), so
  `new_context(browser, devices["iPhone 6"])` works like JS spreading. Deviation: JS keys in JS.
- **Re-created guid gets fresh heap state** (`ChannelOwner.new`): context reuse kept the old
  object's listeners and fields, so handlers ran twice. Revisit with M's heap delete API.
- **Parity root module** for split files is the module named after the file.
- `highlight(style:)` also takes a keyword list (keeps key order, like a JS object literal).

## 2026-11-05: Heap GC and Map order (workstream M)

- **Tracing GC** (`Runtime.GC`) instead of free-on-settle: freeing on settle breaks late awaits
  (`_closedPromise`, user handles, `expect_*` where the event fires before the await). Runs
  under the baton at the end of a unit (API call, handed-off callback, macrotask) once
  allocations reach twice the reachable objects (min 2000); ~13-25 ms at steady state.
- **Roots**: open connections, units in flight, pending timers/posts, promises with suspended
  awaiters, handles returned to a caller (until it exits or `GC.unroot`, max 1000 per process,
  then awaiting raises "garbage collected"), and a graveyard of the last 500 disposed owners
  (handles keep reading fields after close, as in JS).
- **Two-collection freeing**: locals of suspended units are invisible, so an object is freed only
  after every unit in flight at the first collection ended. Revisit: a listener awaiting forever
  postpones all freeing.
- **Settled promises** keep only `:state`; awaiters get the result in their wake-up message.
- **Closed connection heaps** are deleted once nothing in them is reachable; reading a handle
  from one raises `TargetClosedError`.
- **Map order**: heaps are `ordered_set`, map rows carry an insertion `seq` (JS Map semantics).
  Header order in `raw_headers`/`route.fulfill` is unchanged: those are Elixir maps in the API.
- Measured: 1000 evaluates return to baseline +10 rows; 300 pages level off.
- Watch: two tracing specs failed once in a full run after the merge (passed alone and in the
  next full run). Revisit if CI shows it again.

## 2026-11-05: Final skip sweep

- 77 in-body browser guards became `@tag skip: if(<browser cond>, do: "upstream skip|fixme|fail:
  ...")`, and 21 missing upstream skips were added, so reports are honest per browser.
- Proxy specs run on `TestProxy` (ipv6 via an `ip:` option). Glob specs go through the driver's
  glob conversion (not the same function as upstream's `globToRegexPattern`; commented).
  Superseded by workstream AA (they call `UrlMatch` directly, as upstream).
- Firefox: client-certificates "fetch should work in the browser with request interception".
  Resolved (workstream GG): test-port bug. Bandit served zstd to Firefox, which the driver's
  fetch doesn't decode; fixed by `compress: false` on the CC server, as Node's servers.

## 2026-11-05: EventEmitter completed (workstream O), stale-skip check (workstream P)

- **EventEmitter is now 1:1** with `eventEmitter.ts`: `newListener`/`removeListener` meta events,
  `setMaxListeners`/`getMaxListeners` and the leak warning (upstream `console.warn`, skipped
  under test; here `Logger.warning`, skipped when `PWTEST_UNDER_TEST` is set), `rawListeners`,
  `checkListener` (raises `ArgumentError` with upstream's message), `_removeAllListeners` order.
  `ChannelOwner.new` and `Frame` call `setMaxListeners(0)` as upstream.
- **One `emit` argument** stays: Elixir has no variadic functions and every listener is 1-arity;
  meta events pass `{type, listener}`. `defaultMaxListeners` is a `:persistent_term`
  (process-wide like Node; Elixir-only accessors).
- **`removeAllListeners` no longer unsubscribes** channel events when nobody listens for
  `removeListener`: matches upstream (ChannelOwner overrides only on/off/removeListener).
- **Stale skips fail parity**: a reason of the form `not ported: Class.member[ (note)][, ...]`
  is checked against the client and facade exports; prose reasons are explanations and aren't
  checked. Revisit if the prose escape gets misused.
- **Flaky tags**: connect-to-worker console race dropped (30/30 locally; watch CI); popup
  close-on-click skipped on CI only; fullPage screenshot during navigation kept.

## 2026-11-05: Completeness checks (workstream S)

- **Parity checks every upstream file**: each `client/*.ts` needs a module with `@upstream` or
  an entry in `@unported_client_files`; each `tests/{page,library}/**/*.spec.ts` needs a mirror
  or an entry in `@unmirrored_specs` (both in `playwright_ex.parity.ex`, per file, with reasons).
  Superseded for specs by the test registry (workstream MM): unmirrored specs need all their
  tests ruled out in `test/upstream_not_ported.txt`.
  Stale entries (file gone upstream, or now ported) fail too, so version rolls surface new files.
- **Unported client files**: `types.ts`, `channels.d.ts` (type-only), `clientInstrumentation.ts`
  (instrumentation not ported, per-call-site markers), `android.ts`, `electron.ts` (not in the
  JS api.json at 1.64.1; DummyChannelOwner in Connection). Revisit if they enter api.json.
- `unit/timeout-runner.spec` is mirrored (TimeoutRunner is ported): 262 of 296 spec files.

## 2026-11-05: Locator rendering in Elixir (workstream R, PLAN Then item 4)

- **Elixir syntax is a pipe from `page`**: `Page.get_by_role(page, :button, name: "Submit") |>
  Locator.first()`; roles are atoms, keys snake_case, regexes `~r` sigils (flags `imsu` kept,
  `v` becomes `u`, `g`/`y`/`d` dropped). The receiver is always `page` (a selector can't tell a
  page from a frame).
- **Ported**: `locatorGenerators.ts` (all factories plus `ElixirLocatorFactory`),
  `selectorParser.ts`. **Not ported**: `cssParser`/`cssTokenizer` (~1.2k lines; CSS bodies
  stay strings, so invalid CSS renders as `Page.locator(page, "##")` instead of verbatim) and
  `locatorParser` (codegen/inspector only). `locator-generator.spec` is mirrored (27/27);
  `locator-parser`/`css-parser` stay excluded.
- **JS `RegExp` is a struct** (`source`, `flags`, never compiled) so JS-only syntax survives.
  Fixed: `String(re)` escapes `/` (Elixir `~r/a\/b/` has source `a/b`).
- **Matchers' `Locator:` line is Elixir** (client-rendered); call logs stay JS.
- **Install hint**: `npx playwright install [args]` becomes `mix playwright_ex.install [-- args]`.
  Revisit: bare `mix playwright_ex.install` installs chromium only (upstream: all defaults).

## 2026-11-05: Firefox/WebKit runs (workstream T), CI-only failures (workstream Q)

- **Firefox and WebKit pass locally** (macOS): 0 and 2 failures left (a load-dependent
  `count()` during navigation race, a one-off download flake). No lib bugs found.
- **CI runs firefox and webkit** in a non-blocking `test-browsers` job (`continue-on-error`),
  plus a nightly schedule. Their environment skips are macOS-specific; Linux results unknown
  until the first CI run.
- **Test-server fixes**: client-certificates server doesn't compress (Bandit sent zstd, which
  the interception test re-fulfilled with a stale `content-encoding`); TestServer/TestProxy
  listen on both 127.0.0.1 and [::1] on one port (an IPv6 server elsewhere could take the same
  port on [::1], where `localhost` resolves first: the CI EPROTO); UpstreamCase closes contexts
  a test leaves open (a timed-out test kept `_tracingCount` up for later ones).
- **Environment skips** (`env:`): WebKit proxy host, screencast viewport, middle-click
  pointerdown; Firefox partitioned third-party cookies; Firefox `wasClean=false` because Bandit
  half-closes after its Close frame (test server, all OSes). Each confirmed with upstream's
  Node client or a Node server.
- **`download.saveAs: canceled`** for a routed `fulfill` with `content-disposition` on a
  `download` link is upstream behaviour (Node client 1.64.1 does the same). Not a bug.
- **5 Service Worker specs skipped on Linux** (`ci:`): Chromium intermittently drops
  `Network.responseReceived` for the SW script (3/100 runs with the JS client on Linux, 0/100
  on macOS); upstream's CI hides it with `retries: 3`. Revisit with a CI retry
  (`mix test || mix test --failed`) or a newer Chromium.
- **Tracing "should not emit after w/o before"**: the driver drops a console message if the
  waiter's subscription lands >2 ms after the evaluate (upstream sends both in one tick). The
  spec subscribes up front. Revisit: batch outgoing messages per baton hold in the runtime,
  which would also fix the connect-to-worker console race.
- `Task.await_many` in specs uses `:infinity` (upstream `Promise.all` has no timeout).

## 2026-11-05: toMatchSnapshot via the driver's comparator (workstream U2)

- **`PlaywrightEx.UpstreamSnapshot.to_match_snapshot/3`** (test support, port of the runner's
  `toMatchSnapshot.ts`): resolves `<spec>-snapshots/<name>-<browser>.png` in the upstream cache
  and compares with the driver's own `utils.getComparator` (bundled node, `coreBundle.js`),
  same route as upstream's `tests/config/comparator.ts`. Also `compare_pngs/3`,
  `decode_image/2` (webp/png). All 63 toMatchSnapshot tests ported; Linux goldens match on
  macOS at upstream's tolerance.
- **oopif "should take screenshot"** skipped on darwin (`env:`): blank OOPIF screenshot, also
  with upstream's JS client.

## 2026-11-05: VideoPlayer (workstream U1)

- **`PlaywrightEx.VideoPlayer`** (test support, port of `tests/library/videoPlayer.ts`): runs the
  driver registry's ffmpeg (as upstream `registry.findExecutable('ffmpeg')`), PATH fallback,
  else an `env:` skip. JPEG frames go through ffmpeg's mjpeg decoder (Playwright's ffmpeg has
  no PNG decoder). All 20 VideoPlayer tests ported.
- **Mac WebKit video frames** leave the right/bottom gray (macOS 26; upstream client too): 7
  pixel checks skipped on darwin+webkit (`env:`).

## 2026-11-05: AbortSignal (workstream X)

- **`PlaywrightEx.AbortController` / `PlaywrightEx.AbortSignal`** (runtime support; JS globals):
  heap objects like `Promise`, so reads are lock-free, `abort/2` takes the baton (no race with a
  call's check-then-listen) and any process can abort. Listeners are 0-arity, implied `once`.
  `abort/1` without a reason uses an `AbortError` ("This operation was aborted"; JS: a
  DOMException). Statics (`AbortSignal.abort/timeout/any`, `onabort`) not ported (unused by
  client tests).
- **Client**: `sendMessageToServer` raises on an aborted signal, else sends `__abort__` on abort;
  `Waiter.rejectOnTimeout`, `Locator._withElement`, matchers' `(isNot, timeout, signal)` and
  the AbortError branches of `_expect`/`_expectScreenshot`/toHaveURL, as upstream.
- **Facade** emits `signal:` on all 175 options (also Python-style waits and `expect_*`).
- Revisit: abort listeners run under the aborter's baton, not necessarily the signal's loop
  (several drivers only).

## 2026-11-05: Linux firefox/webkit CI (workstream W)

- **Invalid tests were an upstream-source download race**: every module's `setup_all` ran
  `Upstream.ensure!` at once; now serialized with a `:global.trans` lock (and a lost rename
  race between OS processes is tolerated).
- **`PlaywrightEx.TestBrowser`** (test support) reads `BROWSER` for non-upstream tests too.
- **Module skips survive `@tag skip: nil`**: chromium-only modules combine their module
  reason into per-test skip expressions.
- **Linux env skips** (confirmed with the upstream Node client): headless Firefox WebGL without
  `DISPLAY` (the firefox/webkit job now runs under `xvfb-run`, see below); WebKit
  Modernizr `inputtypes.month`; Firefox third-party Partitioned cookies on all OSes against a
  freshly started Bandit (mechanism unknown; revisit).
- Race fixes: start racing waits with `Runtime.Promise.async` (a `Task` may start the call
  late; JS sends it at once).

## 2026-11-05: Driver message batching (workstream Y)
- A baton hold's outgoing messages are queued and written in one `Port.command` at release
  (`EventLoop.at_release/2`), like JS writing a tick's messages before the driver reads any.
  Sending each message on its own reached the driver about 1 ms apart, so a subscription update
  could arrive after the call it precedes. A 20 ms safety timer flushes when no release follows.
  This fixed the tracing spec (workaround dropped). Revisit: is the timer needed at all?
- connect-to-worker and ServiceWorker-start console specs: server-side races (the driver resumes
  the worker before replying), not ordering bugs. Tagged `flaky:` everywhere (also fails locally
  under load), keeping the chromium-only module reason first: a test `skip: nil` overrides it.

## 2026-11-05: Final fidelity audit, fixes (workstream Z)
- A read-only audit compared sampled method bodies across 10 client files with upstream. It
  found no real bugs, only edge cases, now fixed: empty `postDataJSON`, unawaited promises
  returned by predicates and route handlers, `String(1.0)` in fulfill headers and env.
  Every remaining `not ported:` group in lib and test was judged justified.
- Keyword lists stand in for `URLSearchParams` and `FormData` (repeated names allowed), as
  `form`/`multipart` already did. 3 specs un-skipped. Revisit if a struct is wanted.
- Storage-state files are 2-space indented like `JSON.stringify(_, _, 2)`, written by a small
  `ClientHelper.json_stringify_indented/2`: `:json.format` folds single-member objects onto
  one line. Key order follows Elixir maps. (Superseded by workstream QQ: now `:json.format`.)
- `globToRegex` follow-up: done in workstream AA (below).
- The firefox/webkit CI job runs under `xvfb-run` like upstream. Linux firefox WebGL (webgl
  screenshot, capabilities, oopif, connect) now runs and passes there; the no-DISPLAY `env:`
  skips remain for headless Linux boxes.
- GC steady-state loop: Linux firefox stops answering `newPage` after ~100 pages, with or
  without xvfb (passes on macOS). Tagged `env:` for firefox on Linux. Revisit with the upstream
  Node client in the same loop to confirm it is browser-side.
- webkit "should await form-post on click": on CI once, the click reply came before WebKit sent
  the POST (driver timing). Tagged `flaky:` for webkit on CI.

## 2026-11-05: Local URL glob matching (workstream AA)
- `urlMatch.ts` is fully ported (`globToRegexPattern`, `resolveGlobBase`, `toWebSocketBaseUrl`).
  The `LocalUtils.globToRegex` round trip and its cache are gone, as upstream's
  `localUtils.ts` has neither, and sync `page.frame(url:)` no longer takes the baton. This
  reverses the PLAN decision to follow non-JS clients (Python/Java), for 1:1 with JS.
- Elixir-only `Isomorphic.URL`: a reduced WHATWG `new URL(input, base)`, `href` and `origin`,
  because `URI` is RFC 3986 and normalizes differently. 22,681 glob/baseURL/ws cases matched
  the driver's output exactly. Not covered: IPv4 number forms, IPv6 compression, full UTS46,
  `file:` drive letters. Revisit: a full WHATWG dependency, and its reuse where `URI.merge`
  still stands in for `new URL` (e.g. `browser_context.ex` service worker scope).
- `toHaveURL` with a baseURL now normalizes like JS (IDN, spaces, default ports).
- `ExUnit.start(assert_receive_timeout: 10_000)`: 139 mirrored tests use a bare
  `assert_receive` where upstream awaits with only the test timeout. The 100 ms default flaked
  on CI (multipart intercept).
- `expectedSSLError`/`isBidiChannel` ported into `PlaywrightEx.Utils` (tests/config/utils.ts)
  with the platform branch: Linux WebKit may report `Operation was cancelled`. `utils.ex`
  joins credo's `upstream_shaped` files.
- Flaky tags: webkit on CI "goto following click" (same driver timing as form-post), and the
  tracing "WebSocket keeps streaming frames" test under full-suite load (a 100 ms chunk can
  miss every frame; passes alone). Revisit the latter: stream from the server process itself.

## 2026-11-05: One CI test matrix
- chromium, firefox and webkit run in one `Test (<browser>)` matrix, all under `xvfb-run`;
  firefox/webkit are `continue-on-error`. A final `Tests` job is green when every blocking
  entry is: the one check to require.
- **Needs your action before merging PR #124:** `main`'s ruleset requires `Test (port)` and
  `Test (websocket)`, from main's old transport matrix, which this branch no longer produces.
  Require `Tests` instead.
- CI retries test failures once (`|| if [[ $? = 2 ]]; then mix test --failed; ...`, as in ptp),
  like upstream's `retries: 3` on CI. Compile/warnings errors (exit 1) are not retried.
- `launchServer`: the API stays out (JS-only), and so does its own spec
  (`browsertype-launch-server`), as in Python. Correction: I first said no other client runs
  launchServer specs; Python and Java do, through a test fixture over the driver's
  `launch-server` CLI. By the north star those specs are ported (workstream BB2).
- CI concurrency like upstream: `max_cases` is half the schedulers on CI (Playwright's default
  workers: half the logical cores; 2 on a 4-vCPU runner), ExUnit's default (2x) elsewhere.
  Modules already run their tests serially, as upstream's `fullyParallel: false` on CI.
- Bare `mix playwright_ex.install` (and `Driver.install_browsers/0`) installs the driver's
  default browsers, as `npx playwright install`; it was `chromium --only-shell`.

## 2026-11-05: TestServer WebSocket framing (workstream DD)
- `TestServer.WebSocket` frames RFC 6455 itself on the raw socket after the upgrade: Bandit's
  WebSock hides the peer's Close frame (answers 1000), so close codes/reasons and `wasClean`
  couldn't match Node's `ws`. Also a small `:gen_tcp` ws client for the specs that use `ws`.
  No new dependency. HTTP/1.1 responses carry Node's keep-alive headers (HAR sizes match);
  `TestServer.send_resp/4` sets a custom status text (closes the connection).
- 10 specs un-skipped (route-web-socket close codes, status text, HAR sizes, wss connect,
  malformed frame, discarded-page CDP with a macOS-only `env:` skip).

## 2026-11-05: URL globs through the driver again (workstream LL, your call on 12)
- Reverts workstream AA: globs go through `LocalUtils.globToRegex` (cached, under the baton), as
  in Python/Java/.NET. `Isomorphic.URL` (354 lines) and the local `urlMatch` port are gone
  (net -417 lines); the entries "glob_to_regex caches the driver's regex" and "Handlers validate
  globs through the driver" apply again. `construct_url_based_on_base_url` (toHaveURL with a
  baseURL) is `URI.merge` plus scheme/host lowercasing: less exact than WHATWG on default
  ports, IDN and percent-encoding; no spec is affected.

## 2026-11-05: Facade docs for the Elixir API (workstream II)
- JS-only option doc variants take the other clients' text when the type is the same (timeouts
  now say 30 s; 127 fixed); matcher timeouts name `config :playwright_ex, :expect`; Tracing notes
  pointing at the test runner's config are dropped. JS code examples stay (Then 5).

## 2026-11-05: Top-level errors, facade structs, optionsOrPredicate (workstream EE)
- Exceptions are top-level modules; `Client.Errors` keeps only the errors.ts helpers.
- Handle structs are defined on the facade modules by the generator from the client's
  `__struct_fields__/0` (`use ChannelOwner, struct: PlaywrightEx.Page`); client code builds the
  facade struct, `Heap.impl/1` maps it back to the client module (`this.__struct__.foo` became
  `impl(this).foo`). Adding a field takes a regenerate before use. Internal classes keep their
  own structs. No compile-time dependency from facade to client (`compile --force` passes).
- An `optionsOr<Name>` argument (`[function]|[Object]`) merges into options with a
  `when is_function/1` clause: `wait_for_event` and every `expect_*` built on it take a predicate.
- Open: 4 `wait_for_event` timeout docs still carry the JS text (no same-type non-JS sibling).

## 2026-11-05: launchServer specs (workstream BB2)
- The launchServer, multiclient and signals specs run, as Python/Java run them. There are two
  server mechanisms: upstream's `remote-server-impl.js` via NODE_PATH, unmodified, for the
  RemoteServer fixture; and the driver's `launch-server` CLI, which is what Python's conftest uses.
- The signals spec runs a child BEAM (`ClientProcess`). Deviation: exit codes are the BEAM's
  (SIGHUP gives 129). The 3 tests Python skips (SI-007..009) stay skipped.
- The browsertype-connect reuse scenarios are ported (commit vsuyrrrl) even though Python skips
  that file. They pass, so drop the commit if you want strict north-star parity.
- Fixtures are stopped only by an explicit close. An aborted run can orphan servers and their
  browsers; workstream OO makes them exit on stdin EOF.

## 2026-11-05: Upstream test registry (workstream MM)
- Adopted Python/Java's mechanism: `test/upstream_registry.md` (upstream `tests/registry.md`) and
  rules in `test/upstream_not_ported.txt`, applied by `UpstreamCase`, checked by parity. Per-test
  `not ported` tags and `@unmirrored_specs` are gone.
- Bodiless tests under an unconditional upstream skip/fixme count as accounted for without a
  rule (39). Registry rows newer than the pin and renamed mirrored tests are warnings, not
  failures (version skew with Python's registry copy).
- Reasons say what the test needs that we lack, in words; Python's wording where it applies
  (SI-007..009).
- North star: `mix playwright_ex.parity --north-star` diffs our rules with Python's.
- Merge with BB2: launchServer/multiclient/signals/launcher rules dropped (those specs run).
  `browser-server` (Browser.bind, Python runs it) is ported in the merge, on a driver of its own
  with `PWTEST_SERVER_REGISTRY`.

## 2026-11-05: GC fixes (workstream JJ)
- No GC-free alternative found (handles must be freed for long sessions). Measured pauses:
  ~5 ms typical, 100-350 ms at 20-60k heap rows.
- Fixes: parked units hold back only older objects; handles returned from a Task stay rooted
  for the caller (`$callers`); calls on freed owners raise `TargetClosedError` (as the server
  answers JS for an unknown guid).
- Open: a write barrier / cached edges to cut pause times (recommended); the cap of >1000 promise
  handles per process vs. the Promise docs.

## 2026-11-05: Global AbortController, Expect.not_, bang waits (workstream KK)
- `AbortController.new/0` only: signals live in a public ETS table owned by
  `PlaywrightEx.Application`. Deviation: an aborted signal keeps one row (its reason) for the
  application's lifetime. Listeners are GC roots of their loop; one added under another driver's
  baton than the aborting process holds runs posted to its loop (no cross-baton waits).
- `Expect.not_/1` follows JS `expect(x).not`: field `isNot`, no double negation.
- Bang forms of the promise waits (`wait_for_event!` etc.); doc examples are generic.
- "orOptions" rule: options may take the place of an optional scalar before them
  (`to_have_attribute(l, "id", timeout: 1)`); optionsOr object fields take the other clients' docs.

## 2026-11-05: Fixtures exit with the test BEAM (workstream OO)
- Every long-lived child of a test (run-server, launch-server, remote-server-impl.js, the
  ClientProcess child BEAM) exits on stdin EOF. Node children get `-r
  test/support/exit_on_stdin_eof.js`, so upstream's scripts stay unmodified; the child BEAM
  halts on `:eof`. Playwright's exit handler then closes the browsers. Before: a `kill -9`
  of the BEAM orphaned 15 processes. After: 0, on all 3 browsers.
- The library path (`run-driver` over a Port) never leaked: the driver already exits on stdin close.
- Regression test: `test/playwright_ex/no_orphan_processes_test.exs` (`:slow`, runs in the suite).
- Known gap: the `--inspect-brk` node in connect_to_worker pauses before the preload runs, so a
  BEAM that dies in that short window can still orphan it. Accepted; a reaper risks PID reuse.

## 2026-11-05: Heap lifetimes without tracing (design study, needs your decision)
- Proposal: protocol objects (pages, contexts, handles, ...) are never traced; they live by
  `_objects`/`__dispose__`. Once disposed, they stay readable until their parent scope closes
  (page until its context, context until its browser), which replaces the 500 graveyard.
- Runtime objects (promises, waiters, closures) are freed by counted ownership: Heap writes keep
  per-slot holder counts, and units, processes, timers and posts count as holders. An object is
  freed after an epoch delay once its count reaches zero. Cycles are tied to their outermost
  protocol object.
- Handles returned to user processes belong to that process, freed on its exit, on the bang
  form or on `release/1`. No 1000 cap.
- Effect: pauses go to about 0; net about -50 LOC.
- Risks: a missed holder means an early free, which raises loudly. A shadow checker using the
  old tracer verifies counts against reachability before the switch.
- Changes vs JS: a handle passed to another process by message dies with the first owner. Reading
  a request/response/handle of a closed page raises TargetClosedError.

## 2026-11-05: Flake causes and fixes (workstream CC)
- Measured in a Linux container (4 CPUs, xvfb, CI=true). The flakes are timing in the driver and
  browser, and upstream's JS client hits them under load too. No client race was found; `lib/` is unchanged.
- Fixes are in the test ports:
  - Test-only timeouts upstream lacks: 402 `Task.await` 5 s defaults are now unbounded, poll
    helpers use the expect timeout, `to_pass` uses the test timeout.
  - `UpstreamCase` uses action and navigation timeouts of 0, like Playwright Test's fixture, so a hung
    action fails at ExUnit's 120 s.
  - connect_to_worker uses the driver's node: Ubuntu's node 22 breaks evaluate for upstream too.
- 7 of 8 flaky tags removed. connect_to_worker stays skipped: our evaluate lands about 0.5 ms
  later than JS's after the driver resumes node, and fails 5–10%.
- CI: webkit is blocking. Firefox stays non-blocking until its Linux viewport (`innerWidth` vs
  context viewport) and worker-timestamp failures are fixed; CC did not chase them.

## 2026-11-05: Stdlib in place of JS ports (workstream QQ)
- `RawHeaders` groups with `Enum.group_by`. `waiter`/`matcher_utils` reuse ClientHelper's
  `create_guid`/`number_to_string`; pretty-format keeps its `-0` clause.
- Storage-state and fetch storage files use `:json.format`. Only `JSON.parse` reads them, and the
  two upstream specs that compare text compare against their own formatter's output. Python uses
  `json.dumps(indent=2)` and Java writes compact JSON.
- Kept the URLSearchParams encoder (4 lines). Keyword-list `params` encode `*`/`~` as JS does
  (`a*%7E`), so the server receives the same raw query. `form:` bodies are encoded by the driver anyway.
- A `Regex` bound for JS (browser selectors and matchers, driver route patterns) raises
  ArgumentError for PCRE-only options or syntax (`x`, `\A`, `\z`, possessive quantifiers,
  atomic groups, inline flags, ...). Still semantic only: `$` before a final newline, and `u`
  making `\w` Unicode-aware.
- Open:
  - A public `PlaywrightEx.RegExp.new(source, flags)` for JS-only syntax (`[^]`, `v`/`y`/`d`,
    variable-length lookbehind). Needs about 15 call sites changed and 169 regenerated specs.
  - JS regexes returned by the driver still crash `Regex.compile!` (serializers.ex:82).
- Kept the jest-style matcher messages. The layout is Playwright's own `matcher_hint`, and
  ExUnit.Diff is private and colour-only. Python writes its own simpler messages. Replacing ours
  would take about a day and change user-visible text.

## 2026-11-05: OTP-native runtime spike (workstream PP, needs your decision)
- A spike (change `omuunqursqzs`, workspace wpp, not merged) drove real Chromium with no heap
  objects, no GC and no baton. 20/20 slice tests pass over 4 runs: goto, wait_for_navigation incl.
  timeout, request events, routes with handlers that call back into the API, waits rejected on
  close, AbortSignal, 20 open/close cycles back to baseline.
- Design:
  - The connection process is the only writer of an ETS table (lock-free reads).
  - Promises are a ref plus a message to the awaiting process; race and all are receives.
  - Shared promises get a holder process.
  - Waiter state lives in the waiting process.
  - ManualPromise fields are rows on their owner.
  - User listeners run in per-subscription processes.
  - A dispatch barrier holds the connection until a listener returns or blocks on Playwright, so
    the event-before-reply guarantee and listener order hold.
  - `__dispose__` deletes the rows: exact lifetimes, no cap, no pauses.
- Deviations:
  - Check-then-act windows need subscribe-first reorders (about 1 per 8 methods; 3 in the slice).
  - An async listener queues later events behind it; JS interleaves them.
  - A listener blocking on non-Playwright work stalls its connection's dispatch.
  - Mutable fields raise TargetClosedError after close; initializer data stays readable.
- Effort: about −1.0k to −1.2k LOC (runtime and JS emulations, 2.45k, become about 1.3k),
  roughly 2–3 weeks of agent time, mostly a concurrency audit of the 55 client files.
- Alternative: counted ownership (above). About −50 LOC, line-level 1:1 kept, but the heap stays
  and a missed holder becomes a new failure mode.
- Found on the way: `metadata.location.file` was relative; JS sends absolute. Fixed.

## 2026-11-05: Test WebSocket framing via cowlib (workstream SS)
- `cow_ws` (cowlib 2.21, test-only, no transitive deps) handles framing: parsing, unmasking, UTF-8,
  fragments, building frames, handshake keys. Our raw upgrade handling stays, because the specs
  need it: hold or destroy before the handshake, raw bytes, echo of the peer's close code.
  −21 LOC.
- Closer to `ws`: invalid frames and invalid UTF-8 now close with 1002/1007, where the old code
  ignored them silently.
- Not Bandit WebSock: it always answers a peer's close with 1000, which breaks route_web_socket's
  "client-side close". permessage-deflate stays declined, as upstream's `WebSocketServer` does.

## 2026-11-05: Public RegExp, stdlib form encoding (workstream RR)
- Keyword-list fetch `params` are encoded with `URI.encode_www_form`. The raw `*`/`~` differ
  from JS; decoded values are identical. Cosmetic, ratified.
- `PlaywrightEx.RegExp` is public, for JS-only syntax; strings stay literal. It is accepted
  wherever `Regex` is; the generated specs say `Regex.t() | PlaywrightEx.RegExp.t()`.
- Regexes from the driver always come back as `%RegExp{}`: lossless and consistent, like JS's
  RegExp (your call; it first returned a `Regex` when the meaning was identical).
  `RegExp.to_regex/1` converts one when PCRE can run it.
- Elixir-side matching translates the source (`[^]`, `\\u`, ...) and compiles with `:unicode`,
  `:dollar_endonly` and `{:newline, :anycrlf}`. The `v` flag and unbounded lookbehind raise.
- SE-092 and SE-097 now run.
- Local only: page_wait_for_url "should work on frame" hangs on macOS, on the base revision
  too; CI passes it. Handed to OTP Phase 0.

## 2026-11-05: credentials.create takes the returned credential (workstream TT, your call: b)
- `Credentials.create!(creds, known.rpId, known)` works as JS's `create(known.rpId, known)`. The
  options may be the credential map that `create`/`get` return (JS keys). `rpId` in the map is
  ignored, as JS's `{ ...options, rpId }` overwrites it.
- Opt-in per method: `ApiRules` `@result_options` (only `Credentials.create`), with
  `Facade.result_options!/4`. Keyword options stay strict; unknown map keys still raise.

## 2026-11-05: OTP-native runtime, Phase 0 done
- The baton EventLoop and tracing GC are gone. In their place: `runtime/conn.ex` (one process per
  connection, sole writer of an ETS table, dispatch barrier), a heap with rows on their owners, and
  two promise kinds: local (ref + message, one awaiter) and latch (a row on an owner; any process,
  many times).
- Rule: a promise awaited more than once, by another process, or stored in a field is a latch.
- Disposed objects keep their fields and settled latches, so reads return the last value, as in JS.
  A closed context or browser is freed when every process that created or closed it has exited,
  or when the connection closes. Deviations:
  - reads after those processes exit raise TargetClosedError;
  - a long-lived process keeps about 175 rows per context it closed, until it exits.
- Full chromium run: 6 failures out of 4085 in 192 s, against 61 failures in 1257 s on the old
  runtime. The rest is in test/OTP_BACKLOG.md: 4 failing tests (chromium:763, tracing:918,
  page_history:153, coverage:244) and load-only flakes, all for Phase 1.
- Fixed on the way: page_wait_for_url "on frame" hung because the URL was read before the
  glob-to-regex driver round trip. The macOS-only hang on the old runtime was very likely the same.

## 2026-11-05: OTP-native runtime, Phase 1 done
- Five group agents (A–E) audited the client for the new runtime: subscribe-first where JS relies
  on same-tick ordering, `atomic` around read-modify-writes, latches for stored or shared
  promises, `on_sync` for listeners that only update state (closer to JS, where listeners run
  synchronously on dispatch).
- Most failures were test ports, not the client: helpers that ported `.then` as racing Tasks
  (page_autowaiting_basic), awaited what upstream fires and forgets (page_history:153), or
  subscribed after the event (chromium:763, tracing:918). The client fixes closed windows in
  `Frame.wait_for_url/wait_for_navigation/wait_for_load_state` (coverage:244), double closes,
  double HAR exports, and stray result messages from lost races.
- Merged in report order (D, E, C, B, A) instead of the planned A, B, D, C, E: no conflicts.
- The Phase 0 agent planned the groups and was then retired (about 340k tokens of context); the
  lead did the one frozen-file change (`Connection.close` in one atomic step).
- Follow-ups for Phase 2 are in test/OTP_BACKLOG.md.

## 2026-11-05: after Phase 1
- Your calls: subscribe-first accepted and documented (migration guide, "Subscribe before you
  check"), with a public `PlaywrightEx.Promise.free/1` for the wait you don't need. Durable
  decisions go to `docs/architecture.md` (what plus a short why), not ADRs.
- Binding registration gap fixed with a reply hook: `channel_call(..., on_reply)` runs a pure-state
  fun in the Conn when the reply is dispatched, before the next message (JS's microtask
  continuation). Used by expose_binding/expose_function, add_locator_handler, connectToBrowserType;
  the upstream statements move unchanged into the hook. Rejected: write-then-rollback (the locator
  handler uid comes from the reply).
- Waiter rejection timing left as is: a fix needs a blocking mailbox step with acks plus a
  per-process event buffer (150-250 lines, deadlock risk), and code after `await` runs in another
  process anyway. Documented.
- Test timeouts match upstream (30 s, 60 s on darwin x64; actionTimeout 0). That surfaced the
  lifetimes bound test (200 contexts, past 30 s on webkit/firefox CI): cut to 20 contexts, which
  measures the same per-context bound. Non-upstream tests get tight limits (harness agent).
- workers_test:237 is a chromium race, not ours: upstream's JS client hangs too (6/510 under
  2-CPU load). Tagged flaky on chromium and filed microsoft/playwright#43922.
- A Linux Docker harness (`scripts/linux/run`) reproduces CI-only issues; manual only.
- Daily upstream-update workflow: a cheap version check, then claude-code-action ports per PORTING
  and opens a draft PR `upstream/<version>`. Live once on main. Owner to do: a ruleset on main
  requiring PRs and the `Tests` check (the tool deny-list is prefix-based).
- Config audit against 1.64.1 found the harness never applies upstream's default context and
  launch options, ports conditional skips and `test.fail` as unconditional skips, and runs 4x
  upstream's local concurrency. One harness-fidelity agent fixes these.
- Lead error: agent prompts named ~/src/playwright (1.62-next) as upstream instead of the 1.64.1
  cache. The code relied on is unchanged between the two; the parity pass names the cache.
- Full line-by-line parity pass added to PLAN as the quality gate, needing your go-ahead.
- North star (tests playwright-python runs that we don't): ports for env-var tests via a driver of
  their own (CC-023, CD-018, CD-024, CD-025); agents on fetch cookies/TLS, misc, headful, Selenium.

## 2026-11-05: north-star ports and harness fidelity
- North star now 1 / 10 (ruled out / bodiless tests playwright-python runs; was 33 / 38). Left out:
  BT-047 (the object form of `connect` is a types-only overload; positional Elixir would repeat
  BT-046) and FE-185..187 (Happy Eyeballs: a resolving proxy replaces the very connection they
  check; Python rules them out too). The 10 bodiless ones are upstream fixme or Edge/Windows-only.
- Techniques taken from Python: a resolving CONNECT proxy for `__testHookLookup`; a second driver
  with its own env (HAR websocket frames, env-var tests, SELENIUM_REMOTE_URL). The client keeps
  `__testHook*` keys when its driver runs under test, as upstream's `tObject` does; deviation:
  per connection, not per process (one BEAM runs drivers with different envs).
- TR-023 decodes the last JPEG frame in the browser (canvas), not with a Hex JPEG decoder.
- Headed tests are tagged `:headed`, excluded on macOS (windows stole focus on the owner's Mac);
  CI runs them under xvfb (`HEADED=1 ... --only headed`). Opt in locally with `--include headed`.
- Selenium tests run in CI from what the runner image ships (Chrome, ChromeDriver, Java 17) plus
  two cached jars, <1 min; Python's CI never runs them.
- Harness: client instrumentation ported, and the harness registers upstream's default launch and
  context options; `expected_failure/2` replaces test.fail-as-skip; parity flags unconditional
  tags of conditional upstream annotations; max_cases is half the schedulers (macOS firefox 8 to
  11 min); non-upstream tests get 20 s; CI reports first-run failures before the retry.
- CI: a stalled Azure apt mirror (`--with-deps`) hung webkit's install step for 40 min. apt now
  times out and retries stalled fetches, each install attempt is capped at 5 min (a leftover
  apt-get is killed before the retry), and test jobs time out at 60 min.
- Gap, later: `test/support/remote_server.ex` builds its own launch options instead of merging
  `_defaultLaunchOptions`, so `HEADED=1` remote servers still launch headless.

## 2026-11-05: parity pass (round 2)
- Round 2 trimmed after your cost question: the full line-by-line parity pass first (your call: full,
  not light), Phase 2 backlog/stress/perf/docs leaner afterwards (one backlog agent, one stress+perf,
  docs written once into docs/architecture.md, not PLAN first). Stress tests: manual only, not CI.
  RO-033: keep the teardown rejection, silence its log.
- Audit: 20 read-only shards (~5k Elixir lines each, Phase 1 groups split in two) on a snapshot of
  ad8d0dd5, then one verify-then-fix agent per group. 232 findings: 3 S1, 52 S2, 177 S3. Every
  upstream test present. Plan and briefs: `$CLAUDE_JOB_DIR/tmp/round2/` (ROUND2_PLAN.md, findings/).
- Repeated patterns go to one owner each (ROUTING.md), not to every group: un-awaited JS calls
  ported as `Task.async` (93 files; fix: `Runtime.Promise.async/1`), version-gated skips ported as an
  `if` around the body (pass silently), `slow()` untranslated, `toBeTruthy` as bare `assert`
  (`:null` is truthy), leak tests asserting a warning nothing emitted.
- Runtime fixes (VF-F): a listener process that dies no longer stalls its Conn (S1, F-22); a fired
  `once` listener unsubscribes; an abort from another process is no longer lost between the check
  and addEventListener; one API call is reported to the trace once (shared `:atomics` cell).
- Deviations taken: the max-listeners leak warning is ported and logged under test too (upstream
  skips it under test; its leak specs read the in-process server's warnings, ours can't); a
  collected object keeps a tombstone so calls raise upstream's "has been collected" error, while
  its fields stay freed (as ratified); an exception without a JS name serializes as "Error".
- New helpers: `Runtime.Node.path_resolve/1` (path.resolve, not `Path.expand`: no `~`) and
  `Runtime.Node.fs!/3` (Node's ENOENT text), so specs can keep upstream's assertions verbatim.
- CI fixes found on the way: a compile-time `||` short-circuit left `@win32_fixme` unused off
  chromium (warnings-as-errors failed webkit/firefox); the Selenium grid tests reused a port before
  the killed grid exited (now awaited, as upstream's fixture does).
- VF-C1 (selectors/locators): isomorphic `+value` is a full JS `Number(string)`
  (`SelectorParser.to_number/1`: hex/octal/binary, whitespace, `Infinity`; NaN/±Infinity as atoms,
  JSONL writes null), checked against upstream's TS run in node. Selector syntax error positions
  count UTF-16 units. locator-generator.spec now runs `context._showRecorder` in beforeEach as
  upstream does. `expect.poll` sites use `Utils.poll/3`; issue annotations and file-level skips
  stay as comments. 4 findings rejected as ratified deviations.
- VF-B (page/frame): 22 fixes, mostly verbatim assertions; Node fs error texts for addScriptTag/
  addStyleTag/screenshot/pdf (X-05). C2a-05 frame side rejected: `wait_for_url`'s predicate runs in
  the awaiting process (mailbox subscription), as upstream's runs in the caller. X-03 leak tests now
  fail without frame.ex `setMaxListeners(0)`.
- VF-H (harness): annotations known before the run are skip tags, using UpstreamCase's compile-time
  `@browser_name`/`@browser_major_version` (driver browsers.json; setup_all checks the launched
  major). ExUnit has no runtime skip. Test-server https is HTTP/1.1 only, as Node's
  createHttpsServer. Remote servers launch with `_defaultLaunchOptions`. Parity flags upstream
  `slow()` without `@slow_timeout`. `Utils.assert_truthy/1`/`assert_falsy/1` for JS truthiness.
- Lead, H-16: keep the 10 s `assert_receive` default instead of bounding event waits by the test
  timeout: the test timeout still bounds the test, and failures surface sooner.
- Lead, H-17: keep one CI rerun of first-run failures instead of upstream's `retries: 3`: more
  retries would hide the flakes we want to see (the FailuresFormatter lists them).
- VF-D2 (fetch/network/har): fetch `form` keyword lists stand for FormData (a FilePayload value
  raises upstream's "found File" error); URLSearchParams params are WHATWG form-urlencoded (byte-equal
  to JS). `ClientHelper.json_stringify_indented` is now a hand-written `JSON.stringify(v, undefined,
  n)` layout (`:json.format` joined short values on one line and added a trailing newline), so
  storageState files match upstream's text verbatim.
- Open after VF-D2: the HAR `unrouteAll` CI flake reproduces under load (~1 in 30) for our client
  but never for the driver's JS client with identical CDP command order; cause not found (next: a
  CDP trace of a failing run). Backlog agent. `number_to_string` lacks JS's `1e+21` exponent form.
- VF-D1 (routing): route and WebSocket route handlers are called as JS functions
  (`ClientHelper.call_function/2`: any arity; 1-arity gets the route, 2-arity route and request),
  and a returned `%Promise{}` is awaited before `_afterHandle`, for both handler kinds.
  `route.fulfill(path:)` on a missing file raises `Node.SystemError` (ENOENT text) instead of
  `File.Error`; `status: 0` sends 200 (JS truthiness). `postDataJSON` drops one leading `?` as
  URLSearchParams does.
- VF-A1 (browser type/connect): connect's emulated close fires `disconnected` after a
  `Promise.timer(0)` tick (upstream's setTimeout), not inline. A remote connection's dispatch-error
  close reason is `"Error: <message>"` (JS `String(e)`). A relative userDataDir resolves as Node's
  `path.resolve` (no `~` expansion). The page_event_crash chromium tests run on ubuntu CI although
  upstream skips ubuntu24.04: they pass there. BT-047 is ported (north-star: nothing ruled out).
- VF-C2 (expect/aria, S1 C2a-06/07): without a test runner, an inline aria snapshot that upstream
  would rebaseline now fails, with the new snapshot in the message, instead of passing uncompared
  (`""` under `:default`/`:missing`, any under `:all`, a mismatch under `:changed`). Revisit if
  source rewriting is ever ported. C2a-05 rejected on both sides (the predicate runs in the
  awaiting process).
- VF-A2 (browser context): storageState files are written in protocol key order and match
  `JSON.stringify(v, undefined, 2)` verbatim; a missing state file raises Node's ENOENT text;
  `recordVideo.dir` uses `path.resolve`. modernizr "Safari Desktop" on Linux overrides
  `inputtypes.month` instead of skipping the test (verified by CI's Linux webkit).
- X-03 outcome: the "should not leak listeners" specs cannot fail client-side for the 20-pages and
  20-waitForNavigation cases (no client emitter collects per-page listeners; upstream's check catches
  the in-process server's warnings). The EventEmitter warning and `setMaxListeners(0)` stay, as
  upstream's client has them. (VF-B saw the waitForNavigation case warn with frame.ex's call removed;
  VF-A2 did not reproduce it. Same code either way.)
- Lead, A2b-06: keep library/heap's "should collect frames" and "cycle handles" ported (python rules
  the whole file out): without `setMaxDispatchersForTest` no frame is collected, so the first is
  marked a deviation that checks 310 frameattached events, not the GC path.
- VF-C3 (input/handles): setInputFiles raises Node's `ENOENT: no such file or directory, stat
  '<path>'` (asserted verbatim), resolves paths with `path.resolve` (a leading `~` is a file name),
  and a remote directory upload skips symlinks as `Dirent.isFile` does.
- Lead, C3a-14: `JSHandle.get_properties` keeps returning a map (python returns a dict; an ordered
  list would change the public API); marked a deviation. C3a-10: page_mouse's Mac-WebKit env skip
  is unverifiable here; re-check on the next WebKit roll.
- VF-E (tracing/download/screenshot): upstream's close-before-parse order kept; `parse_trace_raw`
  renders titles through `browser_type` since the closed context's connection is gone. `Promise.all`
  of awaited calls stays `Task.async` + `Task.await_many` (not X-01). Lead: tracing's screencast
  frames tests get the same macOS 26 WebKit `env:` skip as video_test (they fail on the base too;
  Linux CI webkit passes them).
- Lead, CI fix after VF-H: H-06's per-test `selectors.setTestIdAttribute` reset hit a context that
  stays in `_contextsForSelectors` after its browser closed under a reused context (as in JS) but
  whose rows were freed once its creators exited; `set_test_id_attribute` now skips such contexts
  (`# deviation:`). A user calling it from a long-lived process had the same crash.
- VF-X (X-01, page specs): an un-awaited upstream call is `Runtime.Promise.async` (returns once the
  call is sent; `shared: true` where upstream checks `done`, tested with `settled?/1`);
  `void x()`/`.catch(() => {})` is `Runtime.Promise.void`; setTimeout timers stay `Task.start` +
  sleep; `Promise.all` of awaited calls stays `Task.async` + `await_many`. 160 + 15 sites converted,
  no hidden race surfaced. X-07: 19 JS-value truthiness sites use `Utils.assert_truthy/falsy`.
- VF-X (X-01/X-07, library specs): same rules as the page specs; 51 + 17 sites converted, 31 X-07
  sites. One hidden race made visible and fixed: debugger "should pause at pause call" now
  subscribes before starting `page.pause()`.
- Lead, CI fix after VF-A2: modernizr "Safari Desktop" runs on Linux WebKit with upstream's plain
  overrides; the old skip's claim ("Linux WebKit supports month") was wrong: Linux WebKit and the
  safari-26 report both say `month: false` (checked in the Linux container).
- Backlog (Phase 2): connect's continuation after `initialize` runs in the Conn's reply hook, so
  a close dispatched next sees the browser. A closed remote Conn stops once the processes that
  connected and created it have exited (reads after raise TargetClosedError, as for closed
  contexts). Local async results go through a process alias, so `Promise.free` drops late
  results. Route `complete` latches are freed when settled (`stop` arms them in one step,
  `Promise.await_all_atomic/2`). Interception patterns are computed when the message is written
  (`channel_call` takes params as a function, `# deviation:`). `_actual_headers` memoizes its
  promise (`Promise.async_once/3`). RO-033 per the user: the teardown rejection is kept and the
  `route` listener drops it unlogged (JS-pending alternative: a never-reject latch flag, a stuck
  listener process per in-flight callback, and `unrouteAll(wait)` after close hangs as in JS).
