# Restructure plan

Mirror the official JS client 1:1 so Playwright releases roll by diffing upstream, and
generate the public contract from the docs for completeness. Clean cut: no legacy API.
Evidence for the choice of client: `README.md`.

## Layers

```
PlaywrightEx                      entry: playwright/1 returns the root object
PlaywrightEx.{Page, Locator, ...} generated facade from api.json (official names)
PlaywrightEx.Expect               generated matcher facade (raise only)
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
  `async: false` (locators, `url`, `pages`): plain values. Matchers raise.
- The facade sets the API name for errors (`page.waitForURL`), validates options, carries
  docs/specs and delegates to `Client.*`. A missing impl function is a compile warning.
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

## Infrastructure (not generated from api.json)

- Protocol types/params/events/initializers generated from `protocol.yml`, committed.
- `connection.ts`, `channelOwner.ts`, `eventEmitter.ts`, `waiter.ts`, `timeoutSettings.ts`,
  `errors.ts`, `outofprocess.ts`, `connect.ts`: hand 1:1.
- Driver: version pinned in the library, with checksums. `PlaywrightEx.Driver` downloads
  `playwright-core@<pin>` from the npm registry (sha512 integrity) and Node from nodejs.org
  (SHASUMS256) for the host platform, then installs browsers with that Node. No Node
  needed beforehand. Lazy install on first start (like `esbuild`) and
  `mix playwright_ex.install` for CI/Docker; `executable:` override for npm-managed setups.
- No client-side version check: the pinned driver always matches; remote servers reject
  mismatches from the `Playwright/<pin>` user agent.
- Remote: `BrowserType.connect` as in JS, through the local driver's LocalUtils
  (the driver opens the WebSocket), so no Elixir WebSocket client.
- `PlaywrightEx.playwright/1` returns `%Playwright{chromium, firefox, webkit, request,
  selectors, devices}` like `client/playwright.ts`.

## Tracking upstream

- No line numbers. `@upstream "<path>"` per module, same names, markers only on deviations.
- `mix playwright_ex.parity`: TS methods per file vs Elixir functions; api.json vs facade.
- Roll: bump pin and checksums, regenerate, `git diff vA vB -- packages/playwright-core/src/client`
  (hunk headers name the method), port hunks.

## Decisions

- Locator rendering and URL globs via the driver's `LocalUtils.asLocatorDescription` and
  `globToRegex` (as non-JS clients do; regex cached per route), instead of porting ~3.3k
  lines of locator/selector/CSS parsers.
- `sdkLanguage: "python"` so server messages render snake_case locators.
- Strings vs bytes: explicit `{:binary, b}` where JS branches on Buffer (WebSocket, fulfill, fetch).
- Evaluate: JS source strings, omit `isFunction` (like Python); string + `arg` is function source.
- `exposeFunctions`: Elixir closures in `arg` become bindings (port utilityScriptSerializers).
- GC: keep initializer in the struct, tombstone in ETS. AbortSignal: drop at first.
- Zones: process dictionary, handed over with the baton.
- testInfo-bound matchers (`toHaveScreenshot`, file aria snapshots, soft): behaviour for
  ExUnit later. Skip `toMatchSnapshot` and generic jest assertions.
- Out of scope: `launchServer`, `connectOverCDP(transport)`, function serialization,
  inspector; Electron/Android optional.

## Spikes (before porting)

1. Baton runtime in place of the loop process; upstream send-then-register restored.
2. Ordering: console listener has run before `evaluate` returns; awaiting listener.
3. Routing: page + context handlers, `fallback`, `times`, `unroute` with wait.
4. Re-entrancy: `exposeBinding` handler calling back into Playwright mid-call.
5. Dialogs: auto-dismiss without listener, accept with listener.
6. Remote: `connect` to `run-server` through LocalUtils, nested connection on one baton,
   download `save_as` and large `set_input_files` over the remote stream.
7. LocalUtils `asLocatorDescription` in matcher errors; `globToRegex` for routes.
8. Driver install without Node: download, verify, run, install chromium.

## Then

1. Generators (`api.json` facade, `protocol.yml` channels) and parity task.
2. Core port (connection → page/frame/locator → network → matchers), then the remaining
   classes, released as one breaking version with the migration guide.
