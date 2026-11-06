# Architecture

Why PlaywrightEx is built the way it is, for contributors (not in hexdocs). The how (rules,
idioms, traps, bumping the pin) is in [`PORTING.md`](../PORTING.md); users get
[`guides/concurrency.md`](../guides/concurrency.md).

## Layers

```
PlaywrightEx                      entry: playwright/1 returns the root object
PlaywrightEx.{Page, Locator, ...} facade generated from api.json (official names, docs, specs)
PlaywrightEx.Expect               generated matcher facade (tuple + bang)
PlaywrightEx.Client.*             hand 1:1 port of playwright-core/src/client/*.ts
PlaywrightEx.Matchers.*           hand 1:1 port of playwright/src/matchers
PlaywrightEx.Isomorphic.*         isomorphic helpers (manualPromise, locatorGenerators, ...)
PlaywrightEx.Protocol.*           generated from protocol.yml, plus a port of serializers.ts
PlaywrightEx.Runtime.*            Elixir only: connection process, heap, promises, zones
PlaywrightEx.Transport.Pipe       port of pipeTransport (JSON off the connection process)
PlaywrightEx.Driver               pinned driver: install, locate, start
PlaywrightEx.Supervisor           OTP form of Playwright.create(): driver, connection, tasks
```

## Port and versions

The client is a statement-by-statement port of the official JS client at a pinned version, so a
Playwright release rolls by porting `git diff vA vB` hunks (see PORTING, "Bumping"). The JS
client is the source because it is the reference implementation: the other language clients
lag it and differ among themselves. Modules carry `@upstream "<path>"`, keep upstream's method
order (parity checks it) and mark only deviations.

Versions will mirror upstream major.minor once the port is stable (`1.64.x` drives Playwright
1.64; the patch is ours), as playwright-python does; upstream's `since` is then ours. Until then
releases are 0.17 release candidates (PLAN "Later").

The driver is pinned too: `PlaywrightEx.Driver` downloads `playwright-core@<pin>` from npm
(sha512) and Node from nodejs.org (SHASUMS256, committed for six platforms; musl from
unofficial-builds), lazily on first start or with `mix playwright_ex.install`. No Node needed
beforehand, and no client-side version check: the pin always matches, and remote servers reject
mismatches by the `Playwright/<pin>` user agent. `executable:` points at an npm-managed CLI.
Remote browsers (`BrowserType.connect`) go through the local driver's `LocalUtils.connect` and
`JsonPipe`, as the JS client does, so there is no Elixir WebSocket client.

## Generated facade

`mix playwright_ex.gen.api` emits every api.json member (`langs: js`) as a facade module that
names the API call for errors, validates option keys and enums, carries docs and specs, and
calls the client. A missing client function is then a compile warning, so completeness is
checked, not hoped for. Elixir-only adjustments live in `Mix.PlaywrightEx.ApiRules` (dropped
members and options, merged overloads, callback objects such as `Logger`, open maps such as
storage state and cookies, `@result_options` for `Credentials.create`).

- Shapes: `name/n` returns `{:ok, v} | {:error, e}`, `name!/n` raises; sync members return
  plain values; void members return `:ok`. Options are snake_case keyword lists or maps, nested
  objects keep JS keys in both directions, so results round-trip and each object has one type.
  Optional positional arguments stay positional, options last.
- Handles are facade structs (`%PlaywrightEx.Page{}`) built from the client's
  `__struct_fields__/0`, not `@opaque` (OTP 28 opaques are nominal, which breaks cross-module
  specs). Exceptions are top-level (`PlaywrightEx.TimeoutError`, ...) with the JS message.
- Names that are no Elixir function names take Python's (`$eval` is `eval_on_selector`,
  `and`/`or` are `and_`/`or_`, `not` is `not_to_*` and `Expect.not_/1`): the closest official
  precedent. JS readonly fields are arity-1 functions.
- Waits JS starts without `await` return a `PlaywrightEx.Promise` where Python has an
  `expect_*`, and get the callback form too (`expect_popup(page, action)`, C#'s order). Bang
  waits exist but await at once.
- Docs render from the `spec` AST, not `comment` (admonitions, nested option bullets,
  `*Since 1.x.*`, events as moduledoc headings). Non-JS doc variants replace JS-only text where
  the type matches. A JS example with an Elixir translation in `test/examples` (tests, so each
  compiles and runs; `PlaywrightEx.ExampleCase`) is rendered in Elixir, keyed by the JS text; the
  rest stay JS until translated.
- Out of scope: `launchServer`/`BrowserServer` (JS-only), `connectOverCDP(transport)`, function
  serialization, the inspector, the test runner (`toPass`, `expect.poll`, soft asserts, file aria
  snapshots, jest matchers). `to_have_screenshot(target, path:)` stays, with an explicit path in
  place of `testInfo`.
- Consumer requests (phoenix_test_playwright, fluffy) were checked against the official
  clients; only additive ones were kept (tuple matchers, the error `log` field,
  `to_have_screenshot` with a path, `Driver.version/0`, `mix playwright_ex.cli`). Per-call client
  timeouts, document identity and a monitorable pid are done by callers with the official API.

## Runtime

One process per connection (`PlaywrightEx.Runtime.Conn`) owns an `ordered_set`, `:protected`
ETS table and dispatches driver messages one at a time. It is the only writer: client code runs
in the caller's process, reads rows lock-free, and sends writes as funs to run in the connection
(`Conn.run/2`). So a read-modify-write (`Heap.update/3`, `Heap.atomic/2`) is atomic, as a
synchronous JS section is, while callers in many processes overlap as async JS calls do.
`await` inside the connection raises: dispatch must not block.

`PlaywrightEx.Runtime.Heap` maps `this._x` to rows keyed `{owner_guid, local}`, so disposing an
object and everything it owns is one bounded prefix delete. Map rows carry an insertion
sequence (JS Map order). A runtime object without an owner (`new_object(module)`) lives in its
creator's process dictionary.

Promises (`PlaywrightEx.Runtime.Promise`) are messages, in two kinds. A local promise is a ref
whose result is sent to its creator, which awaits it once. A latch is a row on an owner, awaitable
any number of times from any process, rejected when its owner is disposed. `async/2` runs a
function in a process of its own and settles a local promise, or a latch (`owner:` an object,
`shared: true` the calling process). `void/1` fires and forgets. `then_`/`catch_` are lazy and
run in the awaiter; `race`/`all` are selective receives. Rule: a promise awaited more than once,
by another process, or stored in a field is a latch.

Outgoing messages are buffered and written once per turn of the connection process, which
replaces per-message writes (a subscription update arrived ~1 ms after the call it precedes) and
the baton's tick batching with its safety timer. `PlaywrightEx.Supervisor` preloads the client
modules: lazy code loading once delayed a subscription past its event.

This supersedes the baton event loop: one token per driver, client code only in its holder,
an ETS heap freed by a tracing GC. That reproduced JS ordering exactly but cost ~30 µs of token
time per call, 100-350 ms GC pauses at 20-60k rows and a cap of 1000 handles per process. On the
OTP runtime the full chromium suite went from 1257 s (61 failures) to 192 s (6) before the
concurrency audit. Counted ownership (keep the heap, count holders) was the rejected
alternative: smaller, but a missed holder becomes a new failure mode.

## Object lifetimes

JS keeps a closed object readable while referenced. Here a disposed object keeps its field rows
and settled latches until its anchor is freed, so reads after close return the last values. The
anchor of a BrowserContext or Browser is the set of processes that created or closed it
(`ChannelOwner._set_creator/1`; implicit ones inherit the parent chain's, else the connection);
the Conn monitors them and frees the rows when the last exits or the connection closes. Anything
else is anchored to its nearest context (else browser). After that, fields raise
`TargetClosedError` and writes are dropped. Initializer data, type and guid live on the handle
struct and stay readable forever.

The cost: a long-lived process keeps ~175 rows per context it closed until it exits. Objects the
driver collects (`gc`) are freed at once, with a tombstone so calls raise upstream's "has been
collected" error. A JSHandle disposed by itself (`dispose`, not with its page) is freed at once
too, without a tombstone: calls raise `TargetClosedError` as in JS, and so do field reads (JS:
the last preview). A remote connection's JsonPipe is freed when disposed. A closed remote
connection's Conn stops once the processes that connected have exited. Latches shared with `shared: true` go when their creator exits; `Promise.free/1`
drops a wait nobody needs. AbortSignal rows go when their creator exits.

Rejected: free-on-settle (breaks late awaits of `_closedPromise` and `expect_*` handles) and the
tracing GC's 500-object graveyard.

## Ordering

A dispatch barrier keeps JS's guarantees: an event is handled before the reply that follows it,
and listeners run in order. Each listener is a dispatch step; the connection waits until the
listener returns or first awaits Playwright, as JS runs listeners synchronously until their
first `await`. Calls from listeners are served meanwhile, so re-entrant callbacks (routes,
bindings, locator handlers) don't deadlock. The barrier keeps a frame stack, so a nested `emit`
returns after its own listeners, in JS order. A listener process that dies releases the barrier.
A promise settled in that synchronous section (by the dispatch, a step, or a listener the barrier
waits for) wakes its awaiters once the frame stack is empty, as JS runs the continuation as a
microtask after the whole `emit`: `Browser.close` returns after the `disconnected` listeners.

Listener kinds (`PlaywrightEx.Client.EventEmitter`): user listeners (added through the facade)
get one process per subscription, FIFO; internal listeners a process per event; `on_sync/3`
runs inline in the connection for pure state updates (closest to JS, and no process hop on hot
events); mailbox subscriptions turn events into messages for waiters.

What differs from JS, accepted:
- Code after an `await` runs in the caller's process, possibly after the next event. Where an
  event the call enables reads what that code writes (bindings, locator handlers,
  `connectToBrowserType`), the statements move unchanged into a `channel_call/5` `on_reply` hook
  that runs in the connection on reply. Rejected: write-then-rollback (the handler uid comes from
  the reply).
- Check-then-subscribe is no longer one tick. Ported code subscribes first where JS relies on it
  (`# deviation: subscribe-first (OTP runtime)`, about one method in eight); users get the same
  advice in the concurrency guide, with `Promise.free/1` for the unused wait.
- A waiter rejects in its own process, not inside `emit`, so "rejected before the next emit" is
  not guaranteed. A fix needs a blocking mailbox step with acks plus a per-process event buffer
  (150-250 lines, deadlock risk), and a `.catch` would still run in another process.
- An async user listener queues its subscription's later events; JS interleaves them. A
  listener blocking on non-Playwright work stalls its connection, as in JS.
- A route callback pending at teardown rejects with `TargetClosedError`, dropped unlogged; JS
  leaves it pending (which would keep a process per callback stuck).

## BEAM instead of JS runtime ports

Where JS leans on Node or the browser runtime, the BEAM or stdlib stands in, so there is less
code to keep in sync: Elixir `JSON` (with `ClientHelper.json_parse/1` mapping `null` to `:null`),
`Process.send_after/3` for timers (`Promise.timer/1`), process dictionaries for zones (inherited
by listener processes), ETS for state, `Enumerable`/`Collectable` for streams, `DateTime` for
`Date`, keyword lists for `URLSearchParams`/`FormData`. `PlaywrightEx.AbortController` is global
as in JS: signals live in an ETS table of the application, any process aborts, listeners run in
the aborting process and only send messages. Local file access is plain Elixir: `path.resolve` is
`Path.expand/1`, a failed `fs` call raises `File.Error`; Node's error texts are not imitated.

Kept as ports because the output is user-visible and must match: the MIME table, the
`URLSearchParams` serializer (byte-equal to JS), the `JSON.stringify(v, undefined, 2)` layout of
storage-state files (`:json.format` differs), and `MatcherUtils` in place of
jest-matcher-utils/pretty-format/jest-diff (ExUnit.Diff is private and colour-only).

## Value mapping

- `undefined` is `nil`, JS `null` is `:null` (JSON `null` decodes to `:null`); `X | null`
  results are `nil`, as they are handles, not JS values. The facade passes omitted optional
  arguments as `nil`, so JS defaults apply in the body.
- Bytes are `{:binary, b}` where JS branches on Buffer; binaries are strings.
- `PlaywrightEx.RegExp` is public for JS-only syntax; a `Regex` is translated to a JS regex and
  PCRE-only syntax raises. Regexes from the driver always come back as `%RegExp{}` (lossless).
- `evaluate` takes JS source; a string plus `arg` is function source (no `isFunction`, like
  Python). Elixir closures in `arg` become bindings (utilityScriptSerializers).
- Callbacks from the page are called as JS functions (`ClientHelper.call_function/2` pads or drops
  arguments to the arity); a returned `%Promise{}` is awaited; `raise` becomes a page error.
- Result maps can be passed back as options where JS does (`Credentials.create`, device
  descriptors with an ignored `default_browser_type`).

## URL globs

Globs become regexes through the driver (`LocalUtils.globToRegex`, cached per glob, base URL and
WebSocket flag), as Python, Java and .NET do. Function matchers get the URL string, as in those
clients; `URLPattern` has no Elixir counterpart and is dropped. A local port of `urlMatch` with a reduced WHATWG
URL was tried and reverted: 417 more lines to keep exact for no user-visible gain.
`toHaveURL` with a base URL uses `URI.merge` plus lowercasing, less exact than WHATWG on
default ports, IDN and percent-encoding.

## Driver language and rendering

The client announces `sdkLanguage: "javascript"`: the driver accepts only
javascript|python|java|csharp, and JS keeps its messages identical to upstream's tests, docs and
issues. So driver-rendered text (call logs, errors) stays JS. Text the client renders is Elixir:
`locatorGenerators` and `selectorParser` are ported with an Elixir factory, so `inspect(locator)`,
`to_string` and the matchers' `Locator:` line read `Page.get_by_role(page, :button, name: "Submit")`.
`cssParser` is not ported (CSS bodies stay strings). Driver install hints name
`mix playwright_ex.install`.

## Mirroring upstream specs

Upstream's specs are the test suite: one module per spec file, same names and order, assertions
verbatim. The north star is to run what the non-JS clients run: specs of JS-only API, of the
in-process server or of the test runner stay bodiless, ruled out in
`test/upstream_not_ported.txt` against `test/upstream_registry.md` (playwright-python and -java's
mechanism, so their rule sets can be compared with `mix playwright_ex.parity --north-star`).
Parity fails on unported registry tests, stale rules and stale skips (a reason naming a member
that now exists), so a version roll surfaces new work.

Skip tags say why: `upstream skip|fixme|fail:`, `not ported:`, `env:` (host or browser
behaviour, confirmed with upstream's Node client), `ci:` and `flaky:`. Annotations known before
the run are compile-time tags (`@browser_name`, `@browser_major_version`), because ExUnit has no
runtime skip and an `if` around the body passes silently. `test.fail` is `expected_failure/2`.
Test-side deviations carry `# deviation:` like lib code.

## Test infrastructure

Fixtures mirror upstream's (`PlaywrightEx.UpstreamCase`, Playwright Test's default context and
launch options, 30 s test timeout, action timeout 0). `PlaywrightEx.TestServer` ports upstream's
test server on Bandit (`compress: false`, both loopbacks on one port, HTTP/1.1 https as Node's).
WebSocket framing uses cowlib's `cow_ws` on the raw socket: Bandit's WebSock answers every close
with 1000 and hides the peer's close frame. `TestProxy` is a small `:gen_tcp` HTTP and SOCKS5
proxy. Snapshot comparison and video decoding use the driver's own comparator and ffmpeg.
`launchServer` specs run on the driver's `launch-server` CLI or upstream's unmodified
`remote-server-impl.js`, as Python's and Java's suites do. Tests of driver env vars run a second
driver with its own env; under test the client keeps `__testHook*` keys per connection. Every long-lived child (servers, the
`ClientProcess` BEAM) exits on stdin EOF, so a killed test BEAM leaves no orphans
(`no_orphan_processes_test`). Upstream assets come from the pinned release cache, not vendored.
Stress and perf runs are manual, not CI.

## CI

One matrix runs chromium, firefox and webkit under `xvfb-run`; the aggregate `Tests` job is the
check to require, and all three browsers block it. Test failures (exit 2) are rerun once with `--failed`; compile errors (exit
1) are not. One rerun rather than upstream's `retries: 3`, so flakes stay visible.
`max_cases` is half the schedulers on CI, like Playwright's default workers. Headed tests run
under xvfb with `HEADED=1 --only headed`. A daily workflow checks npm for a new release and opens a
draft PR that ports it per PORTING.
