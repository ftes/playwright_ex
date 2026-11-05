# Restructure plan

Mirror the official JS client 1:1 so Playwright releases roll by diffing upstream, and
generate the public contract from the docs for completeness. Clean cut: no legacy API.
Evidence for the choice of client: `README.md`.

## Layers

```
PlaywrightEx                      entry: playwright/1 returns the root object
PlaywrightEx.{Page, Locator, ...} generated facade from api.json (official names)
PlaywrightEx.Expect               generated matcher facade (tuple + bang)
PlaywrightEx.Client.*             hand 1:1 port of playwright-core/src/client/*.ts
PlaywrightEx.Matchers.*           hand 1:1 port of playwright/src/matchers (no jest fork)
PlaywrightEx.Isomorphic.*         small isomorphic helpers (stringUtils, manualPromise, ...)
PlaywrightEx.Protocol.*           generated from protocol.yml + hand port of serializers.ts
PlaywrightEx.Runtime.*            Elixir-only engine: event loop (baton), ETS heap, promises, zones
PlaywrightEx.Transport.Pipe       port of pipeTransport (JSON encode/decode off the baton)
PlaywrightEx.Driver               pinned driver: install, locate, start
PlaywrightEx.Supervisor           OTP form of Playwright.create(): driver, engine, tasks
```

Today's guid-based modules, `Selector`, `EventWaiter`, `launch_browser/2` and
`subscribe/2` are removed. phoenix_test_playwright migrates to locators in one step;
a migration guide maps old calls to new ones.

## Public API (generated)

- Source: `api.json` from `utils/doclint/generateApiJson.js`, filtered to `langs: js`, plus
  an Elixir rules file (like Python's `python_rules.js`): non-JS `timeout` docs, dropped
  JS-only classes (`BrowserServer`, jest assertions), callback forms; `Logger` is an object of
  functions with JS keys (`%{isEnabled: fn, log: fn}`).
- `async: true` methods: `name/n` returns `{:ok, v} | {:error, e}`, `name!/n` raises.
  `async: false` (locators, `url`, `pages`): plain values, readable from any process
  without the baton. Matchers are async methods too: `to_have_text/3` returns
  `:ok | {:error, %ExpectError{}}` (fields mirror JS `matcherResult`), `to_have_text!/3`
  raises `ExUnit.AssertionError`; `%Regex{}` accepted as in JS.
- Timeouts only where the official API has them; `timeout: 0` means no timeout, as in JS,
  and `:infinity` is accepted too. Calls without one (`close`, `evaluate`, `save_as`) are
  bounded by callers if needed; the guide shows a `Task.yield` recipe for cleanup code.
- Arguments: optional positional args stay positional, options always last
  (`evaluate(frame, expr, arg \\ nil, opts \\ [])`). Enums are atoms mapped to wire strings
  (`:no_preference`). No options beyond the official ones.
- Keys, as in the Python client: options (a keyword list or map) have snake_case keys; nested
  objects (option values, positional args) are maps with the JS keys and values, passed as they
  are (`cookies: [%{sameSite: "Lax"}]`), the same shape the client returns. So results
  (`storage_state`) round-trip and each object has one type; no keyword lists nested.
- Errors: one exception per JS class (`Error`, `TimeoutError`, `TargetClosedError`) with the
  JS `message` (API-name prefix, call log), plus a `log` field.
- `on/3` returns the emitter and `off/3` takes the same fun, as in JS. The subscription
  update is queued before `on/3` returns and written at the end of the tick.
- The facade sets the API name for errors (`page.waitForURL`), validates options, carries
  docs/specs and delegates to `Client.*`. `mix playwright_ex.gen.api` emits every api.json member
  except those dropped explicitly in `Mix.PlaywrightEx.ApiRules`, so a missing client impl is
  a compile warning (`mix playwright_ex.parity` flags a stale facade). The facade calls the
  client directly.
- Unknown options and enum values raise `ArgumentError` in both forms (programmer errors).
  The facade checks only keys and enums; value types are checked by the generated protocol
  validator at `channel_call`, as upstream's client does (messages use the JS names).
  Upstream tests that pass options `as any` assert that rejection instead.
- `void` methods return `:ok` (`close/2`, `close!/2`). Handles are the facade structs
  (`%PlaywrightEx.Browser{}`, defined by the generator from the client's `__struct_fields__/0`;
  no conversion at every boundary, one term per object), typed `PlaywrightEx.Browser.t()` and
  inspected as `#PlaywrightEx.Browser<guid>`. Not `@opaque`: since OTP 28 opaques are nominal, so
  a client function returning a typed struct violates the facade spec of another module.
- Wait-for-event: a promise handle (`p = Page.wait_for_event(page, :popup)`, awaited with
  `PlaywrightEx.Promise.await/1`) for members Python has an `expect_*` for, and the callback
  form (`Page.expect_popup(page, fn -> ... end)`). Details: `DECISIONS.md`.

## Concurrency: baton

One token per driver. Only the holder runs client code; `await` releases and re-acquires
it. Dispatch hands the token to listener/handler processes until they return or await.
This reproduces JS exactly: listeners run synchronously in `emit`, re-entrant callbacks
(bindings, locator handlers) can call Playwright, check-then-subscribe is atomic, and
upstream's send-then-register order is safe. Callers still overlap while they await, as
async calls do on Node's single thread. True parallel client code would need per-object
locks and a concurrency review of every ported line, so it is not a goal. Nested
`connect()` connections share the driver's baton. Object state lives in ETS; reads are
lock-free. A callback blocking on non-Playwright work stalls the driver, as in JS.

`PlaywrightEx.Runtime.EventLoop` is the loop: the token server with `post`, `set_timeout`
and the micro/macrotask queues. Ported code names no loop (`Promise.new()`, `race([..])`,
`set_timeout(fn, ms)`): the holder finds it in its process dictionary. Objects carry their
`loop` (for the baton) and `heap` (the table) separately: connections get their own heap,
runtime objects (promises, emitters) live in the loop's.

Proven in `js_spike/` (`lib/runtime/baton.ex`, ~300 lines): a scheduler process owns the
token and never runs client code; settled promises resume before new macrotasks (API
calls, protocol messages, timers), like JS microtasks; listeners and handlers get the
token by handoff; dead holders are reclaimed. 1000 concurrent evaluates: no deadlock,
3.5x faster than sequential on one page, ~30 µs of baton time per call (a third of it
is stack capture, worth optimizing). Each connection has its own ETS table on the
shared token, since guids repeat across connections.

## Infrastructure (not generated from api.json)

- Protocol types/params/events/initializers generated from `protocol.yml`, committed.
- `connection.ts`, `channelOwner.ts`, `eventEmitter.ts`, `waiter.ts`, `timeoutSettings.ts`,
  `errors.ts`, `outofprocess.ts`, `connect.ts`: hand 1:1.
- Driver: version pinned in the library, with checksums. `PlaywrightEx.Driver` downloads
  `playwright-core@<pin>` from the npm registry (sha512 integrity) and Node from nodejs.org
  (SHASUMS256) for the host platform, then installs browsers with that Node. No Node
  needed beforehand. Lazy install on first start (like `esbuild`) and
  `mix playwright_ex.install` for CI/Docker; `executable:` override for npm-managed setups.
  Proven in `driver_install/`: ~56 MB download, 4-7 s, 130 MB cache per pin, Node 24.22.1
  (Python's pin), `.tar.gz`/`.zip` like Python (OTP has no xz), committed checksums for six
  platforms via a `mix driver.checksums` roll step. Alpine/musl: Node from the
  unofficial-builds musl tarballs (checksummed the same way), or `node:` pointing at
  `apk add nodejs`. Local browsers still need a glibc image; remote works on musl.
- No client-side version check: the pinned driver always matches; remote servers reject
  mismatches from the `Playwright/<pin>` user agent.
- Remote: `BrowserType.connect` as in JS, through the local driver's LocalUtils
  (the driver opens the WebSocket), so no Elixir WebSocket client.
- `PlaywrightEx.playwright/1` returns `%Playwright{chromium, firefox, webkit, request,
  selectors, devices}` like `client/playwright.ts`.

## Tracking upstream

Conventions and the roll procedure: `PORTING.md`.

- No line numbers. `@upstream "<path>"` per module, same names, markers only on deviations.
- `mix playwright_ex.parity`: TS methods per file vs Elixir functions; api.json vs facade.
- Roll: bump pin and checksums, regenerate, `git diff vA vB -- packages/playwright-core/src/client`
  (hunk headers name the method), port hunks.

## Decisions

Decisions from autonomous porting are logged in `DECISIONS.md` for review first.

- Versions mirror upstream major.minor from the breaking release on (`1.64.x` drives
  Playwright 1.64), the patch is ours, as in playwright-python. So upstream `since` is ours.
- URL globs via the driver's `LocalUtils.globToRegex`, as the non-JS clients do (regex cached
  per {glob, baseURL, ws}, under the baton). Locator rendering is ported (`locatorGenerators`, `selectorParser`; see Then, 4).
- `sdkLanguage: "javascript"` as upstream, so driver messages match upstream tests, docs and
  issues. The driver rejects anything but javascript|python|java|csharp (no "elixir").
- Strings vs bytes: explicit `{:binary, b}` where JS branches on Buffer (WebSocket, fulfill, fetch).
- Names that are no Elixir function names take Python's: `$eval` is `eval_on_selector`
  (`$`, `$$`, `$$eval` likewise), `and`/`or` are `and_`/`or_` (client and facade). `$eval`
  has no options (the docs list `strict`, the JS client rejects a 4th argument).
- `inspect(locator)` and `to_string(locator)` show the Elixir rendering
  (`Page.get_by_role(page, :button, name: "Submit")`). The test id attribute name is a
  `:persistent_term`, module state shared by connections as in JS.
- Evaluate: JS source strings, omit `isFunction` (like Python); string + `arg` is function source.
- `exposeFunctions`: Elixir closures in `arg` become bindings (port utilityScriptSerializers).
- GC: a tracing collector over the heap (`Runtime.GC`, see DECISIONS "Heap GC"). AbortSignal:
  `PlaywrightEx.AbortController`/`AbortSignal` are global as in JS (`AbortController.new/0`;
  signal state in an application ETS table, any process aborts, listeners run under the baton
  of the loop that added them).
- Zones: process dictionary, handed over with the baton.
- `Expect.to_have_screenshot(target, path: ...)` is one more generated matcher
  (`Page`/`LocatorAssertions.toHaveScreenshot`, JS-only in api.json, kept by the rules file,
  which swaps the testInfo-based `name` for an explicit `path`). Its impl ports the
  `toHaveScreenshot` matcher on top of `page._expectScreenshot`; stabilization and
  comparison stay on the server. `toMatchAriaSnapshot` (inline) is a regular matcher.
  File aria snapshots and soft asserts: later. Skip `toMatchSnapshot` and jest assertions.
- `X | null` results are `nil` (`from_nullable`, `goto`, `opener`): handles are Elixir values,
  not JS ones. `:null` stays for JS values (evaluate results) and inputs that distinguish
  `null` from `undefined` (`viewport: :null`).
- Ported `try {} catch` stays an explicit `try do ... rescue` even when it is the whole function
  body (`Waiter.waitForPromise`), not an implicit try: same behaviour, upstream's shape.
- Out of scope: `launchServer`, `connectOverCDP(transport)`, function serialization,
  inspector; Electron/Android optional. `launchServer`/`BrowserServer` are JS-only in api.json;
  specs using a launched server run on a test fixture over the driver's `launch-server` CLI,
  as Python's and Java's suites do (PORTING, Tests).

## Spike results

All passed in `js_spike/` (22 tests) and `driver_install/` (3 tests, no Node on PATH):

1. Baton runtime; upstream send-then-register restored, `waitForLoadState` atomic.
2. Ordering: console listener ran before `evaluate` returned (300/300); awaiting listeners.
3. Routing: page/context handlers, `fallback`, `times`, `unrouteAll` with wait, globs via
   `LocalUtils.globToRegex` cached per handler.
4. Re-entrancy: `exposeFunction`/`exposeBinding` handlers calling Playwright mid-call,
   including nested bindings.
5. Dialogs: auto-dismiss without listener, accept with listener, dismiss after `off`.
6. Remote: `connect` to `run-server` via LocalUtils, nested connection on one baton,
   1.3 MB buffer and 3 MB path uploads, download `save_as` over streams.
7. Matcher failure renders `get_by_role("button", name="Submit")` via the driver.
8. Driver install, verify, launch chromium without Node.

Follow-ups for the real port: two holders can briefly coexist if a handoff parent is
killed; heap `update` with a function that awaits loses writes (compute first); promise
reactions run synchronously instead of as microtasks; JsonPipe close is fire-and-forget;
`run-server` ignores SIGTERM (tests must `kill -9`).

## Consumers

phoenix_test_playwright (~700 lines, 3-5 days) and fluffy (~700 lines, 4-6 days) migrate
mostly mechanically: handle structs instead of guids, `Locator.*` instead of `Frame.*`
with selectors, `on/3` instead of subscriptions, `set_default_timeout` once instead of a
timeout per call. Both shed code (PTP: two event GenServers; fluffy: protocol plumbing).
Their requests were reviewed against the official clients; only additive ones were kept
(tuple matchers, the error `log` field, `to_have_screenshot` with a path), plus:

- Done: `PlaywrightEx.Driver.version/0` and a `mix playwright_ex.cli` passthrough (`show-trace`,
  `install --with-deps`), as Python's `__main__` and Java's `CLI` do.
- Rejected, done by callers with the official API: per-call client timeouts (`Task.yield`);
  fluffy's document identity (an `add_init_script` stamp read with `location.href` in one
  `evaluate`) and document status (`on(:response)` for navigation requests); `on/3` refs;
  a monitorable pid (monitor the named Supervisor or listen for Browser `:disconnected`).
- `JsLogger` is dropped; the migration guide shows the `on(:console)` / `:weberror` recipe
  and recommends listeners that only `send/2` to the owning process.
- `Page.locator(page, string)` passes raw selectors through (custom engines, `internal:`).

Behaviour changes for the guide: `timeout: 0` now means no timeout; dialogs without a
listener are auto-dismissed instead of hanging; error messages carry the API name prefix;
`Tracing` `coverage:` is removed.

## OTP-native runtime migration (ratified 2026-11-05)

This replaces the baton, heap, GC and JS-runtime emulation with OTP primitives, as the spike
(change `omuunqursqzs`, workspace wpp, `lib/playwright_ex/otp_spike/*`) proved; see DECISIONS
"OTP-native runtime spike". It starts after workstream RR (RegExp) lands.

**Phase 0: infrastructure (one agent, serial; afterwards the integrator).** The client files
compile against a reimplemented `Heap` and `Promise` with the same names.
- `runtime/conn.ex` (new, from spike `connection.ex`): one GenServer per connection, sole
  writer of an `ordered_set, :protected` table. `run/2` runs funs from other processes inside
  the connection.
  - Dispatch: `Client.Connection.dispatch/2` runs one message at a time, behind the barrier.
    The barrier keeps a frame stack, so a nested `emit` returns after its listeners have returned
    or yielded, which keeps JS's order for nested emits.
  - Outgoing messages are buffered and flushed per drain, replacing `at_release` tick batching.
  - The transport is a fun: Pipe for OutOfProcess, JsonPipe for connect.
  - `runtime/invocation.ex`: `yield/0`.
- `runtime/heap.ex` (same API): rows keyed `{owner_guid, local}`, so `_dispose` is one bounded
  prefix `select_delete`.
  - `new_object(module, owner)` puts the rows on the owner. `new_object(module)` is a
    process-local object in the process dictionary: reading it from another process raises,
    `free/1` erases it.
  - `atomic/2` runs a fun in the connection and raises if the fun awaits.
  - `:_type`, `:_guid`, `:_initializer` and `:_connection` come from the handle struct, so they
    stay readable after dispose. Handle fields are `[:guid, :conn, :table, :type, :initializer]`;
    regenerate the facade structs.
  - A disposed object keeps its plain-field rows and settled latches until its anchor is
    freed, so it reads and writes as in JS. Anchors: for a BrowserContext or Browser, the
    processes that created or closed it (`ChannelOwner._set_creator/1` in the caller of
    newContext, launchPersistentContext, launch/connect, close; implicit ones inherit the parent chain's creator,
    else the connection), freed when the last of them exits (the Conn monitors them) or the
    connection closes; for anything else, the nearest BrowserContext (else Browser) ancestor,
    freed with it. `_dispose` marks the object (`{guid, :__retained__}`) and records it under its
    anchor (`{anchor, {:retained, guid}}`, or `{:connection, {:anchored, pid, guid}}`); freeing
    walks that index with bounded prefix deletes. Fields of a freed object raise
    TargetClosedError (deviation: after the creator exits). Bound: a long-lived process keeps
    the contexts it closed (~175 rows each) until it exits. Driver-collected objects (`gc`) are
    freed at once.
- `runtime/promise.ex` (same names), two storage kinds:
  - local `new/0,1`: resolve sends to the creator, from any process. Only the creator awaits,
    once.
  - latch `new(owner[, executor])`: a row on the owner, awaitable many times from any process,
    rejected on dispose if pending; a settled latch keeps its value while its owner is retained.
  - `async/1,2` is no third kind: a process runs the fun and resolves a local promise for the
    creator; `owner: obj` resolves a latch on `obj`, `shared: true` a latch owned by the creator
    process (`ProcessOwner`, freed when it exits). Rule for Phase 1: a promise awaited more than
    once or stored in a field is a latch.
  - Also: `void/1` is fire-and-forget; `then_`/`catch_` are lazy and run in the awaiter.
    `race`/`all` arm the promises, then selective-receive: a losing local stays pending, losing
    latches and asyncs are disarmed. Plus `timer/1`, `resolved/1`, `rejected/1`. `await` inside
    the connection raises.
- `zones.ex` stays; holder and listener processes inherit the zone. `api.ex` drops the baton.
  `facade.ex` drops `GC.unroot`; `promise/3` becomes `Promise.async(fun, shared: true)`. Add
  `listen/1`, which marks a listener as a user listener.
- Delete `event_loop.ex`, `gc.ex`, and their tests (`event_loop`, `gc`, `gc_driver`). Rewrite
  `heap_test.exs`.
- Client infrastructure (frozen after Phase 0):
  - `event_emitter.ex`, listener kinds:
    - user: a process per subscription, FIFO.
    - internal (default): a process per event, behind the barrier.
    - `on_sync/3`: runs inline in the connection, for pure state updates.
    - mailbox: for waiters.
    - `_pendingHandlers` holds invocation refs.
  - `channel_owner.ex`: `_dispose` drops listener rows, stops subscription processes, rejects
    pending latches and retains the rest under the object's anchor (see `heap.ex` above). `_update_subscription` becomes a post from inside the connection. Remove
    `_reset_heap_state`.
  - `connection.ex`: registering the callback and writing the message happen in one `atomic`
    (`# deviation:`). The await monitors the connection process.
  - `waiter.ex`: the spike design, with state in the waiter's process dictionary.
  - `timeout_settings.ex`: rows on the owner.
  - `manual_promise.ex`: `LongStandingScope.new(owner)` with latches. `timeout_runner.ex`:
    `Promise.timer`.
  - `abort_*.ex`: no loop. Listeners run synchronously in the aborting process and only send
    messages. The table owner frees a signal's rows when its creator exits.
  - `out_of_process.ex` and `supervisor.ex`: no EventLoop child; OutOfProcess starts Conn and
    Pipe. `transport/pipe.ex`: no `at_release`.
  - `connect.ex`: each connect gets a child Conn under the supervisor, linked to its parent.
    `Cell` becomes an owned object.
  - `matchers/to_have_url.ex`: a process-local object.
  - `gen.api` wraps `on`, `once`, `add_listener`, `prepend_listener`, `off` and
    `remove_listener` in `Facade.listen`. Regenerate.
- Mechanical edits:
  - The `with_baton` sites in selectors, local_utils and web_socket_route become `Heap.atomic`.
  - About 12 `catch_(async(f), fn _ -> nil end)` become `Promise.void(f)`.
  - Promises stored in fields become latches: route, response, browser,
    `browser_context.ex:163`, `route_handler.ex:61`.
  - The 15 `new_object` sites get an owner or become local.
  - `test/support/{upstream_case,utils}.ex`, `page_listeners_test.exs`.
- Done when:
  - compile `--warnings-as-errors`, dialyzer `--force-check`, parity and `gen.api --check`
    pass.
  - Green: `test/playwright_ex/**` (including a new `runtime/conn_test.exs` porting the spike's
    20 semantics tests), `test/mix/**` and `no_orphan_processes_test`.
  - Green on chromium: page_goto, page_wait_for_navigation, page_event_network,
    page_event_console, page_event_popup, page_route, page_listeners, browsercontext_basic,
    browsertype_launch, interception.
  - One full chromium run with no hangs; its failure list is committed as the per-group backlog.

**Phase 1: fan-out (5 agents, one workspace each).**
- Frozen; only the integrator edits them, and groups send change requests:
  - `runtime/*`, `test/support/*`, `lib/mix/**`
  - `client/{channel_owner,connection,event_emitter,waiter,timeout_settings,errors,client_helper,client_stack_trace,events}.ex`
  - `isomorphic/{manual_promise,timeout_runner}.ex`, `abort_*.ex`
  - PLAN/PORTING/DECISIONS
- Groups:
  - **A, lifecycle and remote.**
    - Files: browser, browser_type, browser_context (except routing), playwright, connect,
      local_utils, json_pipe, cdp_session, selectors, credentials, debugger, webmcp,
      web_storage, clock.
    - Specs: library browser*, browsercontext_* (non-network), browsertype_*, launcher,
      defaultbrowsercontext_*, multiclient, browser_server, playwright_client, logger, signals,
      page_close, page_event_crash, page_clock*, chromium, firefox, headful,
      selectors_register, webmcp*, debugger.
  - **B, page and frame.**
    - Files: page (except routing; also bindings and locator handlers in page/browser_context),
      frame, worker, console_message, dialog, web_error, file_chooser, input.
    - Specs: page basic, goto, navigation, history, wait_for_*, event_*, dialog, listeners,
      add_init_script*, add_locator_handler, expose_function, evaluate*, set_content,
      network_idle, keyboard, mouse; frame_*, workers; library popup, beforeunload,
      browsercontext_expose_function, shared_worker.
  - **C, locators, handles and matchers.**
    - Files: locator, element_handle, js_handle, writable_stream,
      `isomorphic/{locator_*,selector_parser}`, matchers/*.
    - Specs: locator_*, elementhandle_*, jshandle_*, eval_on_selector*, selectors_*,
      queryselector, expect_*, to_match_aria_snapshot, page_aria_*, page_click*, page_fill,
      page_check, page_select_option, page_set_input_files, page_drag, page_drop, wheel,
      retarget, page_strict, page_autowaiting*; library hit_target, tap, locator_*.
  - **D, network.**
    - Files: network, request, response, route, route_handler, har_router, web_socket*, fetch,
      raw_headers; plus routing in page/browser_context (`route`, `unroute*`, `_on_route`,
      `route_from_har`, `route_web_socket`, `_update_*interception*`).
    - Specs: page_route, page_request_*, page_network_*, interception, network_post_data,
      firefox_network_response, page_set_extra_http_headers; library browsercontext_{route,
      network_event, fetch*, har, set_extra_http_headers}, global_fetch*, har*,
      route_web_socket, web_socket, unroute_behavior, proxy*, client_certificates,
      network_timeout, fetch_proxy.
  - **E, artifacts.**
    - Files: artifact, stream, download, video, screencast, tracing, coverage, disposable,
      file_utils.
    - Specs: download*, downloads_path, tracing, video, screencast*, coverage, pdf, screenshot,
      page_screenshot, expect_with_snapshot.
- Each agent:
  1. Audits every await. Check-then-act windows get a subscribe-first reorder marked
     `# deviation: subscribe-first (OTP runtime)`. A read-modify-write spanning an await
     becomes `update/3` or `atomic/2`.
  2. Fixes promise kinds (latch, local or async), un-awaited `then_` and double awaits.
  3. Moves hot pure-state listeners to `on_sync`.
  4. Gets its specs green on chromium, then firefox and webkit.
  5. Keeps a deviation log in its change description.
- Merge order: A, B, D, C, E. Each group rebases onto trunk and reruns its specs.

**Phase 2: integration.**
- Full suite on 3 browsers, compared against the baseline and the CI flake tags.
- Stress tests, 100 runs each: event-before-reply, listener order and `once`, re-entrant
  handlers (routes, bindings, locator handlers), nested emit order, concurrent callers on one
  page, `connect` nested close.
- Perf: 5k handles and 1000 pages; p50/p99 call latency against the baton baseline; no pauses;
  rows back to baseline after close.
- Docs:
  - PLAN: rewrite "Concurrency".
  - PORTING: shim rules (kinds, `atomic`, deviation markers).
  - DECISIONS: one entry with the deviation tally.
  - `PlaywrightEx.Promise` docs: owner lifetime, awaitable from any process.
  - Guides: listeners run in processes; no blocking work in listeners.
- Test WebSocket server per workstream SS.
- Abandon the spike and forget workspace wpp.

**Risks.**
- The facade structs and Dialyzer specs change; fix in Phase 0.
- `PlaywrightEx.Promise` keeps its names, but an await after the owner process exits raises.
- AbortController listener funs must not block; test aborts from a third process.
- `connect`: one Conn per connection, separate tables because guids repeat.
- Route handlers run in a process per event; RouteHandler state goes through `update/3`.
- Locator handlers and bindings are re-entrant: the barrier and yield cover them; add stress
  tests.
- WebSocketRoute and HarRouter: `atomic` and `void`.
- Stray `{:pw, ref, _}` messages: waiter dispose flushes them, and `conn_test` asserts empty
  mailboxes.
- Misclassified listeners or objects raise loudly.
- Blocking user listeners stall their connection: document it.
- Prefix-delete cost: measure; if not bounded, keep a child index.

## Then

1. Done: generator for the `api.json` facade (`mix playwright_ex.gen.api`, phase 2). Callback
   forms (`expect_popup`) and matcher shapes land with the classes that need them.
2. Core port (connection → page/frame/locator → network → matchers), then the remaining
   classes, released as one breaking version with the migration guide. Done: the thin slice
   through BrowserContext → Page → Frame (`new_context`/`new_page`, `goto`, `url`, `title`,
   `close`, the `:page` event, `evaluate`, `Request`/`Response`/`JSHandle` constructors,
   `LongStandingScope`), with mirrored `page-goto`/`browsercontext-basic` specs and both launch
   specs. Done: `Locator`, `FrameLocator` and the selector methods of Frame/Page (`click`,
   `fill`, `text_content`, `get_by_*`, `$eval`, ...), with `locatorUtils` and mirrored
   `locator-click`/`locator-list`/`locator-convenience`/`locator-misc-1`/`page-check` specs. Done: input (`Keyboard`,
   `Mouse`, `Touchscreen`), `Dialog`, `ConsoleMessage`, `WebError`, `Worker`, with mirrored
   page-dialog/keyboard/mouse/event-console/event-pageerror and workers specs. Done: waits
   (`wait_for_event`/`navigation`/`url`/`request`/`response`, `Page.frame`), `urlMatch`,
   promise handles (`PlaywrightEx.Promise`) and `expect_*` callback forms, with mirrored
   page-wait-for-* and page-event-popup specs. Done: ElementHandle, the rest of JSHandle,
   WritableStream, FileChooser, `$`/`$$`/`waitForSelector`/`waitForFunction`, `setInputFiles`,
   `Page.screenshot`, the Locator `_withElement` methods, with mirrored elementhandle-*,
   jshandle-*, page-wait-for-*, page-set-input-files, page-select-option specs. Done: fetch
   (`APIRequest`, `APIRequestContext`, `APIResponse`; `Playwright`/`BrowserContext`/`Page.request`)
   with mirrored browsercontext-fetch*, global-fetch* specs. Done: routing (`Route` incl. `fetch`,
   `RouteHandler`, `WebSocket`, `WebSocketRoute`, `HarRouter`, `route`/`routeFromHAR`/
   `routeWebSocket`, `recordHar`) with mirrored page-route, page-request-*, browsercontext-route,
   network, har and web-socket specs. Done: matchers (`PlaywrightEx.Expect`, incl.
   `to_be_ok`, `to_have_screenshot`), bindings/`exposeFunction`/`addInitScript`/Disposable/
   locator handlers, artifacts (Artifact, Stream, Download, Video, Screencast, Tracing). Done:
   Clock, Coverage, WebStorage, CDPSession, Selectors, Debugger, Credentials, WebMCP,
   `launchPersistentContext`, `connect`, `connectOverCDP` (url). Done: remaining members
   (`removeAllListeners`, `storageState`, `emulateMedia`, `requestGC`, `pause`, `pdf`,
   `Playwright.errors`) and the release gate: the generator emits every member, out-of-scope
   ones (`launchServer`, `PlaywrightAssertions`) are dropped in `Mix.PlaywrightEx.ApiRules`.
   Done: mirroring upstream page/library specs, 261 of 296 files (the rest excluded, see
   DECISIONS "Which upstream specs to mirror"), and the full `EventEmitter`.
3. Done: docs and specs on par with playwright.dev for the generated modules, all in the
   generator (`mix docs --warnings-as-errors` in CI).
   - Docs render from the `spec` AST, not `comment`: notes as admonitions, nested option fields
     as nested bullets, newer options and events tagged `*Since 1.x.*`, `@doc since:` from
     "Added in". Events are `###` headings in the moduledoc (anchors `module-<event>`, so
     `[event: Page.dialog]` links there); `on/3` & co. form the "Events" doc group.
   - Links: generated members as facade functions, the rest and other classes to playwright.dev,
     `TimeoutError` to the exception, raw `[Type]` refs as code. JS examples stay until item 4.
   - Types: `@type goto_options` per member (keyword or map, enums as atoms); objects have one
     type for inputs and results, JS keys (see Keys above). Listener specs per event, as in
     `types.d.ts`. Left `term()`: payloads of unported classes (until ported) and JS values
     (`evaluate`, `json`).
   - No NimbleOptions: its validation can't do the conversion the schema already does.
4. Done: Elixir syntax wherever the client produces the text. A port of
   `isomorphic/locatorGenerators.ts` and `selectorParser.ts` (CSS bodies stay strings;
   `cssParser` is not ported) with an `"elixir"` factory renders `Locator.toString`,
   `String.Chars`, `Inspect` and the matchers' `Locator:` line. The driver's install hint is
   rewritten to `mix playwright_ex.install`. Text the driver renders (call logs) stays JS.
5. Later: the facade docs' 321 upstream examples are JS (ratified for 1.64). Translate them in
   the generator (or take Python's and rewrite) after the release.
