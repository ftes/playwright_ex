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
PlaywrightEx.Runtime.*            Elixir-only engine: baton, ETS heap, promises, zones
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
  JS-only classes (`BrowserServer`, `Logger`, jest assertions), callback forms.
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
  (`:no_preference`); `storage_state` round-trips. No options beyond the official ones.
- Errors: one exception per JS class (`Error`, `TimeoutError`, `TargetClosedError`) with the
  JS `message` (API-name prefix, call log), plus a `log` field.
- `on/3` returns the emitter and `off/3` takes the same fun, as in JS. The subscription
  update is sent before `on/3` returns.
- The facade sets the API name for errors (`page.waitForURL`), validates options, carries
  docs/specs and delegates to `Client.*`. `mix playwright_ex.gen.api` emits the members the
  client exports and lists the rest as not ported, so regenerate after porting a method
  (`mix playwright_ex.parity` flags a stale facade). The facade calls the client directly: a
  client function that disappears is a compile warning. This is interim: before release the
  generator emits every member (see Then, item 2).
- Unknown options and enum values raise `ArgumentError` in both forms (programmer errors).
  Upstream tests that pass options `as any` assert that rejection instead.
- `void` methods return `:ok` (`close/2`, `close!/2`). Handles stay the client structs
  (no conversion at every boundary, one term per object), behind an opaque
  `PlaywrightEx.Browser.t()` and inspected as `#PlaywrightEx.Browser<guid>`.
- Wait-for-event: a promise handle (`p = Page.wait_for_event(page, :popup)`) and the
  callback form (`Page.expect_popup(page, fn -> ... end)`).

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

- Locator rendering and URL globs via the driver's `LocalUtils.asLocatorDescription` and
  `globToRegex` (as non-JS clients do; regex cached per route), instead of porting ~3.3k
  lines of locator/selector/CSS parsers.
- `sdkLanguage: "javascript"` as upstream, so driver messages match upstream tests, docs and
  issues. The driver rejects anything but javascript|python|java|csharp (no "elixir").
- Strings vs bytes: explicit `{:binary, b}` where JS branches on Buffer (WebSocket, fulfill, fetch).
- Evaluate: JS source strings, omit `isFunction` (like Python); string + `arg` is function source.
- `exposeFunctions`: Elixir closures in `arg` become bindings (port utilityScriptSerializers).
- GC: keep initializer in the struct, tombstone in ETS. AbortSignal: drop at first.
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
  inspector; Electron/Android optional.

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

- `PlaywrightEx.Driver.version/0` and a `mix playwright_ex.cli` passthrough (`show-trace`,
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

## Then

1. Done: generator for the `api.json` facade (`mix playwright_ex.gen.api`, phase 2). Callback
   forms (`expect_popup`) and matcher shapes land with the classes that need them.
2. Core port (connection → page/frame/locator → network → matchers), then the remaining
   classes, released as one breaking version with the migration guide. Next: a thin slice
   through BrowserContext → Page → Frame (`new_context`/`new_page`, `goto`, `url`, `title`,
   `close`, the `:page` event, the `Request`/`Response` that `goto` needs), with mirrored
   `page-goto`/`browsercontext-basic` specs and the two launch specs waiting on Page and
   BrowserContext. Done so far: `Request`/`Response`/`RawHeaders` (network.ts, without
   routing and `finished`). Release gate: "generate
   all". Out-of-scope classes and members (`launchServer`, `connectOverCDP(transport)`,
   Electron/Android unless ported) are dropped explicitly in `Mix.PlaywrightEx.ApiRules`, the
   generator stops checking client exports and emits every remaining member, so a missing
   impl is a compile warning and fails CI. Classes can switch one at a time once complete
   (a rules entry), so finished ones can't regress while the rest are ported.
3. Later: Elixir syntax wherever the client produces the text. Locator descriptions and
   `inspect` via a port of `isomorphic/locatorGenerators.ts` (and the selector parser it needs)
   with an Elixir factory, revising the `asLocatorDescription` decision above; exact-match
   rewrites of fixed driver hints (install command: `mix playwright_ex.install`). Locators the
   driver renders inside errors stay JS.
