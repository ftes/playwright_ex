# Decisions log

Decisions taken while porting autonomously, newest last, for review. The durable design is in
`PLAN.md` (a reviewed decision moves there or gets reverted); conventions in `PORTING.md`.
Each entry: what, why, and what to revisit.

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
- **Revisit**: nested-connection heap tables are never deleted (one ETS table per `connect`);
  `Playwright.errors` not exposed (the generator would mistype it).
- Electron/Android are not in the JS api.json view at this pin; nothing to drop.
