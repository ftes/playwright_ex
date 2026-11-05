# Decisions log

Decisions taken while porting autonomously, newest last, for review. The durable design is in
`PLAN.md` (a reviewed decision moves there or gets reverted); conventions in `PORTING.md`.
Each entry: what, why, and what to revisit.

## Needs your decision (before a 1.64 release)

These shape the public API, so changing them after release would break users:
1. **Exception modules** live under `PlaywrightEx.Client.Errors` (`TimeoutError`,
   `TargetClosedError`). Add public aliases (`PlaywrightEx.TimeoutError`, as Python's top-level
   `TimeoutError`)? Matcher failures raise `PlaywrightEx.Matchers.MatcherHint.ExpectError`.
2. **Handle structs** are `%PlaywrightEx.Client.Page{}` while the facade type is
   `PlaywrightEx.Page.t()`; `%PlaywrightEx.Page{}` patterns don't work.
3. **Expect defaults** come from the app env (`config :playwright_ex, :expect`). Also offer
   `Expect.configure/1`?
4. **Release**: version (`mix.exs` is 0.16.0; PLAN says major.minor follow upstream: 1.64.0)
   and CHANGELOG entry.
5. **Doc examples**: the generated facade docs carry 321 upstream JS examples. Translate them
   in the generator, or state they stay JS?

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
- **`wait_for_event` takes Python's arguments** (`event`, options `predicate`/`timeout`), not
  JS `optionsOrPredicate`. Deviation from the JS signature; `event` accepts atoms.
- **Function URL matchers get the URL string**, not a parsed URL (Python, Java, .NET).
  `URLPattern` is dropped from api.json unions (no Elixir counterpart).
- **`LocalUtils.glob_to_regex` caches the driver's regex** per {glob, baseURL, ws}
  (Elixir-only helper; PLAN Decisions: globs via the driver).
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
  PLAN); circular `jsonValue` is `%{"b" => :circular}`; missing-file error lacks "ENOENT:";
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
  the baton itself (sync `Page.frame(url:)` needs it).
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
- Firefox: client-certificates "fetch should work in the browser with request interception"
  fails (no upstream skip). Revisit: lib or environment.

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
