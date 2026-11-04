# Restructure plan

Mirror the official JS client 1:1 so Playwright releases roll by diffing upstream, and
generate the public contract from the docs for completeness. Evidence: `README.md`.

## Layers

```
PlaywrightEx                      entry: playwright/1 (root object), launch_browser/2 (compat)
PlaywrightEx.{Page, Locator, ...} generated facade from api.json (official names)
PlaywrightEx.Expect               generated matcher facade (raise only)
PlaywrightEx.Client.*             hand 1:1 port of playwright-core/src/client/*.ts
PlaywrightEx.Matchers.*           hand 1:1 port of playwright/src/matchers (no jest fork)
PlaywrightEx.Isomorphic.*         port of needed isomorphic files (urlMatch, stringUtils, ...)
PlaywrightEx.Protocol.*           generated from protocol.yml + hand port of serializers.ts
PlaywrightEx.Runtime.*            Elixir-only engine: baton, ETS heap, promises, zones
PlaywrightEx.Transport.*          ports of pipeTransport / connect.ts (JSON off the baton)
PlaywrightEx.Supervisor           OTP form of Playwright.create(): transport, engine, tasks
PlaywrightEx.Channels.*           legacy guid API, deprecated (see Compat)
PlaywrightEx.Selector             kept, built on Isomorphic locator utils
```

## Public API (generated)

- Source: `api.json` from `utils/doclint/generateApiJson.js`, filtered to `langs: js`, plus
  an Elixir rules file (like Python's `python_rules.js`): non-JS `timeout` docs, dropped
  JS-only classes (`BrowserServer`, `Logger`, jest assertions), callback forms.
- `async: true` methods: `name/n` returns `{:ok, v} | {:error, e}`, `name!/n` raises.
  `async: false` (locators, `url`, `pages`): plain values. Matchers raise.
- Facade sets the API name for errors (`page.waitForURL`), validates options, carries
  docs/specs, and delegates to `Client.*`. A missing impl function is a compile warning.
- Wait-for-event: both a promise handle (`p = Page.wait_for_event(page, :popup)`) and the
  callback form (`Page.expect_popup(page, fn -> ... end)`).

## Concurrency: baton

One token per driver. Only the holder runs client code; `await` releases and re-acquires
it. Dispatch hands the token to listener/handler processes until they return or await,
reproducing JS ordering (sync `emit`), re-entrancy (bindings, locator handlers) and
atomic check-then-subscribe. Nested `connect()` connections share the driver's baton.
Mutable object state lives in ETS; reads are lock-free. JSON encoding stays in the
transport. A callback blocking on non-Playwright work stalls the driver, as in JS.

## Compat

~80 of today's 94 functions are protocol commands: generate `Channels.*` from
`protocol.yml` as guid-based `{:ok, _}` wrappers. The ~14 composed ones (route/unroute,
wait_for_url/load_state, expect/await_download, EventWaiter, document_request/snapshot,
expect_result/expect_url, Locator.evaluate) become thin wrappers over `Client.*`.
`subscribe/2` stays as a raw dispatch tap; `initializer!/2` reads the heap. Consumers
(phoenix_test_playwright) first swap aliases, then adopt locators.

## Infrastructure (not generated from api.json)

- Protocol types/params/events/initializers generated from `protocol.yml`, committed.
- `connection.ts`, `channelOwner.ts`, `eventEmitter.ts`, `waiter.ts`, `timeoutSettings.ts`,
  `errors.ts`, `outofprocess.ts`, `connect.ts`: hand 1:1.
- Driver pinned in the library; `mix playwright_ex.install` downloads that exact
  `playwright-core` (+ optional Node), like Python's bundled driver. Override via
  `executable:`; only then check major.minor. Remote: send `User-Agent: Playwright/<pin>`,
  the server rejects mismatches.
- `PlaywrightEx.playwright/1` returns `%Playwright{chromium, firefox, webkit, request,
  selectors, devices}` like `client/playwright.ts`.

## Tracking upstream

- No line numbers. `@upstream "<path>"` per module, same names, markers only on deviations.
- `mix playwright_ex.parity`: TS methods per file vs Elixir functions; api.json vs facade.
- Roll: bump pin, regenerate, `git diff vA vB -- packages/playwright-core/src/client`
  (hunk headers name the method), port hunks.

## Decisions

- Strings vs bytes: explicit `{:binary, b}` where JS branches on Buffer (WebSocket, fulfill, fetch).
- Evaluate: JS source strings, omit `isFunction` (like Python); string + `arg` is function source.
- `exposeFunctions`: Elixir closures in `arg` become bindings (port utilityScriptSerializers).
- `sdkLanguage: "python"` so server messages render snake_case locators.
- Locator rendering via `LocalUtils.asLocatorDescription`/`globToRegex` RPCs (as Java does),
  instead of porting ~2.5k lines of locator generators/parsers.
- GC: keep initializer in the struct, tombstone in ETS. AbortSignal: drop at first.
- Zones: process dictionary, propagated with the baton.
- testInfo-bound matchers (`toHaveScreenshot`, file aria snapshots, soft): behaviour for
  ExUnit later. Skip `toMatchSnapshot` and generic jest assertions.
- Out of scope: `launchServer`, `connectOverCDP(transport)`, function serialization,
  inspector; Electron/Android optional.

## Next steps

1. Spike in `js/`: baton, console-ordering test, routing with `fallback`, `exposeBinding`
   calling back into Playwright, remote download stream.
2. Generators (`api.json` facade, `protocol.yml` channels) and parity task.
3. Core port (connection → page/frame/locator → network → matchers), new API beside
   `Channels.*` in one breaking release; then the remaining classes.
