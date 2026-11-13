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
PlaywrightEx.Protocol.*           generated from protocol/spec/*.yml, plus a port of serializers.ts
PlaywrightEx.Runtime.*            Elixir only: connection process, heap, promises, zones
PlaywrightEx.Transport.Pipe       port of pipeTransport (JSON off the connection process)
PlaywrightEx.Driver               pinned driver: install, locate
PlaywrightEx.Supervisor           OTP form of outofprocess.start(): driver and connection
```

## Port and versions

The client is a statement-by-statement port of the official JS client at a pinned version, so a
Playwright release rolls by porting `git diff vA vB` hunks (see PORTING, "Bumping"). The JS
client is the source because it is the reference implementation: the other language clients
lag it and differ among themselves. Modules carry `@upstream "<path>"`, keep upstream's method
order (parity checks it) and mark only deviations.

Versions will mirror upstream major.minor once the port is stable (`1.64.x` drives Playwright
1.64; the patch is ours), as playwright-python does; upstream's `since` is then ours. Until then
releases are 0.17 release candidates (GH #126).

The driver is pinned too: `PlaywrightEx.Driver` downloads `playwright-core@<pin>` from npm
(sha512) and Node from nodejs.org (SHASUMS256, committed for six platforms; no musl, like
Playwright), lazily on first start or with `mix playwright_ex.install`. No Node needed
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
- Tuple forms return what the JS promise rejects with (`Facade.error?/1`: the library's errors,
  `RuntimeError` for the client's `new Error`, the protocol `ValidationError`, `JSON.DecodeError`,
  `File.Error`); anything else raises in both forms. The criterion is upstream's, so it needs no
  per-call judgment or bump step and upstream predicts it. Rejected: raising for input errors the
  client detects (`File.read/1`'s convention), as the driver's input errors (a bad selector) still
  arrive as `PlaywrightError`, so callers couldn't rely on it, and each of upstream's ~75
  `throw new Error` would need classifying. Our own Elixir-side checks (unknown option or event,
  RegExp translation) raise `ArgumentError`.
- Bang matchers raise `PlaywrightEx.ExpectError`, as JS's expect throws its own error (ExUnit
  reports it as a failure with the same text). Rejected: `ExUnit.AssertionError` when ExUnit is
  loaded: it is loaded in nearly every mix/iex run, so detection gains nothing and makes behaviour
  depend on the environment. Callers who want ExUnit's error wrap the call (testing-with-exunit
  guide).
- Names that are no Elixir function names take Python's (`$eval` is `eval_on_selector`,
  `and`/`or` are `and_`/`or_`, `not` is `not_to_*` and `Expect.not_/1`): the closest official
  precedent. JS readonly fields are arity-1 functions.
- Waits JS starts without `await` return a `PlaywrightEx.Promise` where Python has an
  `expect_*`, and get the callback form too (`expect_popup(page, action)`, C#'s order). Bang
  waits exist but await at once.
- Docs render from the `spec` AST, not `comment` (admonitions, nested option bullets,
  `*Since Playwright 1.x.*` as text, not `since:` metadata while our versions differ, events as
  moduledoc headings). Non-JS doc variants replace JS-only text where
  the type matches. A JS example with an Elixir translation in `test/examples` (tests, so each
  compiles and runs; `PlaywrightEx.ExampleCase`) is rendered in Elixir, keyed by the JS text; the
  rest stay JS until translated. Rejected: `iex>` doctests (scripts with no printable results or
  fixtures, and they would live in generated moduledocs) and a compile-only checker (weaker, as
  the tests give compiling for free).
- Out of scope: `launchServer`/`BrowserServer` (JS-only), `connectOverCDP(transport)`, function
  serialization, the inspector, Playwright Test (jest matchers); `PlaywrightEx.Test` is an
  ExUnit layer instead (see Test runner), whose tests give the matchers a ported `testInfo` for
  snapshot names, soft errors, steps and the test's deadline. `toPass` and `expect.poll` are
  matchers of a function (`Expect.to_pass/2`, `Expect.poll/3`), `poll`'s jest matcher an ExUnit
  assertion. `expect.soft` is `soft/1`, a receiver as `not_/1` is (`isSoft`), and
  `expect(x, message)` is `message/2` (`message`), in any order with them.
  `to_have_screenshot(target, path:)` and `to_match_aria_snapshot(target, path:)` stay, with an
  explicit path in place of a `name`, also outside a test.
- Consumer requests (phoenix_test_playwright, fluffy) were checked against the official
  clients; only additive ones were kept (tuple matchers, the error `log` field,
  `to_have_screenshot` with a path, `Driver.version/0`, `mix playwright_ex.cli`). Per-call client
  timeouts and document identity are done by callers with the official API. A lost driver is
  noticed by Browser `disconnected`: a lost local driver emits it too (pages and contexts emit
  `close` first), as `connect` does for its connection (rejected: a public `connection_pid/1`).
  Waits on anything else (a worker) reject once the old connection process stops.

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
any number of times from any process, rejected when its owner is disposed. A wait also monitors
the connection process of what it awaits (a latch, a call, an event): if that exits, the wait
rejects with `TargetClosedError` instead of hanging. `async/2` runs a
function in a process of its own and settles a local promise, or a latch (`owner:` an object,
`shared: true` the calling process). `void/1` fires and forgets. `then_`/`catch_` are lazy and
run in the awaiter; `race`/`all` are selective receives.

A process the client starts on one caller's behalf carries that caller's `$callers`, as a `Task`
does (`PlaywrightEx.Runtime.Callers`): an async function's (`Promise.start`), a user listener's
subscription process, and the listener processes that run a user callback (routes, WebSocket
routes and their handlers, bindings, locator handlers), which adopt the registrant's `$callers`,
captured at registration as `RouteHandler` captures its zone. So `testInfo`, the Ecto sandbox and
Mox find the test there, and an error nothing handles (the listener sink) fails the test of the
process's `$callers`, as upstream's worker fails its current test (`workerMain.ts`
`unhandledError`); elsewhere it is logged. Shared processes (the connection, transport, pool,
supervisors, async functions started in the connection) get none. Rejected: `$callers` in the
zone, as upstream finds the test through the worker's global, not the zone, a saved zone's `run`
ends before the error reaches the sink, and listeners, bindings and locator handlers have no
saved zone upstream.

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

The cost: a long-lived process keeps ~175 rows per context it closed until it exits. Closing a
context frees its children one by one (linear, ~7 µs each); accepted, with no close-walk
optimization. Objects the driver collects (`gc`) are freed at once, with a tombstone so calls
raise upstream's "has been collected" error. A JSHandle disposed by itself (`dispose`, not with its page) is freed at once too,
without a tombstone: calls raise `TargetClosedError` as in JS, and so do field reads (JS: the last
preview). A remote connection's JsonPipe is freed when disposed. An object the driver creates under
the guid of a disposed one (a reused context and its pages) ends the old one's retention, as rows
are keyed by guid. A closed remote connection's Conn stops once the processes that connected have
exited. Latches shared with `shared: true` go when their creator exits; `Promise.free/1` drops a
wait nobody needs. AbortSignal rows go when their creator exits.

A lost local driver's Conn hands its table to a keeper process before it stops
(`Conn.hand_off/2`), so its handles read their last state (closed, the last URL) as JS objects
stay readable while referenced. Calls and writes raise `TargetClosedError`, as the connection
process is gone; `close` of a page, context or browser returns, as JS's catches that error. The
table goes whole once every process that created or anchored one of its objects has exited, or
with the supervisor (monitored, so a brutal kill counts too). `OutOfProcess` logs the loss
(`Logger.error`) with the driver's exit status, once, and not on a normal stop.

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

## Test runner

`PlaywrightEx.Test`'s core is native, not a port. ExUnit is the runner, as pytest, NUnit and JUnit
are for the non-JS clients, whose plugins (pytest-playwright, Playwright.NUnit, Java's
`@UsePlaywright`) it follows: Playwright Test's names and defaults (trace, screenshot and video
modes, artifact names, `testInfo.outputDir`, context defaults), and upstream's artifact code as
the model (`ArtifactsRecorder` hooks on `ClientInstrumentation`, `mergeTraceFiles`). The only
fixture the facade can't provide is a pooled browser, so it is an explicit module; contexts and
pages come from the plain API, and the user owns the ExUnit context map. Everything about the
test (recording, context defaults, soft errors, output and snapshot paths, steps) is found
through the calling process or its `$callers`, as the Ecto sandbox finds its owner. Settings with
no call site (the recording modes) are config plus ExUnit tags; the rest are arguments.

| upstream | here |
|---|---|
| worker `browser` fixture, worker reuse by hash | `BrowserPool.browser/1` (cap `workers`, reuse by key, stopped after a failure; a key is all of its options, as the hash) |
| `connectOptions` | `connect_options` (part of the browser key) |
| env defaults (`PW_TEST_CONNECT_*`, `PLAYWRIGHT_TEST_BASE_URL`) | not read: upstream's runner and tools set them, nothing does here; config only, `System.get_env` in `config/test.exs` |
| `playwright` fixture | `BrowserPool.playwright/1` |
| `context`/`page` fixtures, `browser.newContext()` | `Browser.new_context!/2`, `BrowserContext.new_page!/1`; `PlaywrightEx.Case` puts them together |
| `request` fixture | `APIRequest.new_context!/2` in the test (disposed at its end); not in `PlaywrightEx.Case`, where each test would pay for it |
| auto `_setupArtifacts` | the recording of every registered test (`error-context.md` whatever the modes) |
| `_combinedContextOptions` (`{...contextOptions, ...options}`) | Playwright Test's defaults, then config `context_options`, then the call's (`key in options`) |
| `actionTimeout`, `navigationTimeout` (default 0) | config `action_timeout`, `navigation_timeout` (default `:infinity`), set on each context |
| test timeout, `closeReason` "Test timeout of Nms exceeded." | ExUnit's timeout; the recorder closes the test's contexts with that reason just before it |
| `test.use({ trace, screenshot, video })` | `@moduletag`/`@describetag`/`@tag` over config |
| `testIdAttribute` (per test) | config `test_id_attribute`, set on each pooled driver: the client's value is global to the VM, not to a worker |
| `--trace <mode>` | `TRACE` read in `config/test.exs` |
| `test.info()` | `info/0` (`test_pid`, `file`, `test_name`, `output_dir`), raises outside a test |
| `testInfo.status`, `errors`, `expectedStatus`, `duration` in teardown | `info(test_pid)` in `on_exit` (another process), kept until ExUnit's `on_exit` process exits |
| `testInfo.outputPath`/`snapshotPath` | `output_path(name)` (one string, no segments), `snapshot_path(name, opts)` (a string or a list of segments) |
| `test.step` | `step/2,3` (no timeout) |
| `testInfo.attach` | `attach/2` (`test.attach` step, `trace.attachments`) |
| list reporter's `npx playwright show-trace <path>` | a failure prints `mix playwright_ex.cli show-trace <path>` |
| retry modes (`on-first-retry`, ...) | not supported: ExUnit has no retries; the `TRACE=1 mix test --failed` recipe |

Deviations the port requires:

- Closing the test's leftover contexts, last in its `on_exit`: a pooled browser outlives the test,
  where upstream's worker browser closes them later. Its request contexts left are disposed, as
  upstream's `request` fixture is.
- A video of every context the test creates, not only the fixtures' (there are no context
  fixtures), and `video.show.test`'s title overlay on all of them.
- `actionTimeout`/`navigationTimeout` per context, in the listener's after-create hook (and a
  request context's `timeout`), not on the Playwright (`_setupContextOptions`): a pooled driver's
  Playwright outlives the test and serves any process.
- The test timeout's close before the timeout. Upstream fails the test, then closes its contexts
  with the reason; ExUnit kills the test process, which nothing can follow. So the test's
  recorder closes them `min(1 s, 5%)` before ExUnit's timeout (`--trace` and `:infinity` have
  none): the close's artifact steps and the failing call's reply fit in it (about 50 ms with a
  trace and a screenshot), and a test stuck outside Playwright still gets ExUnit's
  `TimeoutError`. ExUnit's clock starts at the test process's spawn, ours at the registration
  just after. A test that ends earlier cancels it.
- `use PlaywrightEx.Test` as the first line of a case template's body: a template's own `setup`
  callbacks run before those its `using` brings in, so the test is registered before them.

A pooled driver hosts one browser, as upstream's worker runs its project's. Each pooled driver gets
one static listener when it starts (`runBeforeCreateBrowserContext`, `runAfterCreateBrowserContext`,
`runBeforeCloseBrowserContext` and their request context counterparts), which finds the creating
process's test (an ETS lookup of it and its `$callers`) and hands the context to that test's
recorder, so a test's recording sees the contexts of all its browsers. The recorder process
starts at the test's first context (at its registration when it traces, for its steps): a test
without contexts runs none, and its `error-context.md` comes from `TestInfo`. A context a test
process creates before its registration (a template's `setup` with the `use` only in `using`)
makes the registration raise with the fix; one outside any test gets no defaults and no
recording. The driver also adds every call's stack to each trace on its connection, so the trace
merge keeps a chunk's own actions' stacks and sources.

The pool is upstream's worker model. `browser/1` is held by the scope that calls it: `setup_all`'s
module (upstream runs a file in one worker), or the test (a `Task` resolves to it through
`$callers`); a test of a module that holds one calls on its module's, as upstream's tests share
their worker's `browser`. A worker is a driver and one browser per key (all of the options, as
upstream's worker hash covers the project's), reused warm by the next scope of its key unless the
scope failed, else stopped (upstream replaces a worker after a failure). A scope with no known
result (no registered test, a doctest) counts as passed: upstream always knows, and discarding the
unknown would start a driver per module of a plain `ExUnit.Case` suite. At most `workers` of them
run (upstream's, default half the cores, `packages/playwright/src/common/config.ts:111`), stopping
ones included (upstream awaits `worker.stop()` before starting another,
`packages/playwright/src/runner/dispatcher.ts:153`); waiters are served first come first served,
and at the cap a key with no free driver stops the longest idle free one of another key. A module
that waits for one costs nothing, so ExUnit's `max_cases` above `workers` is fine. A scope that
holds one takes its further keys over the cap, so none waits while holding one. The release is the
last step of the test's `on_exit` (after its artifacts) or an `on_exit` of `setup_all`'s, never a
`DOWN`: `on_exit` runs after the test process exits. A module's outcome is its tests', which
ExUnit's runner spawns from the process that ran `setup_all` (`Process.info(pid, :parent)`). The
drivers stop in `ExUnit.after_suite/1`, as `mix test` halts without stopping applications (#191).
The pool starts on first use, never with the application: a release has no ExUnit.

Compared with upstream's dispatcher (`packages/playwright/src/runner/dispatcher.ts`,
`testGroups.ts`):

| | Playwright Test | here |
|---|---|---|
| unit of work | a test group: a file's tests of one project | the scope that calls `browser/1`: a module (`setup_all`) or a test, as ExUnit schedules modules |
| worker | a process with one Playwright and one browser, for one worker hash | a driver and one browser per key (all of the options): the same |
| browsers per worker | 1 | the same |
| job to worker | a free worker of the job's hash, else a new one, restarting a free worker of another hash (`_scheduleJob`) | the same: a free slot of the key, else a new one, stopping the longest idle free slot of another key at the cap |
| after a failure | the worker is replaced | the same |
| ordering | the queue grouped by hash, so a worker rarely switches | ExUnit's random module order (not portable: ExUnit owns it), so a run that mixes configurations restarts workers often: one configuration per invocation |
| idle workers | `_isWorkerRedundant` stops a worker no queued job needs | stopped lazily, when the cap needs room: there is no queue to look ahead |
| where waiting happens | the dispatcher's queue, before a worker runs the group | inside `browser/1`: no timeout in `setup_all`, the test timeout in `setup` or a test |
| a scope needing a second configuration | another project, another worker | a further key over `workers`, so a scope that holds one never waits for itself |
| concurrency | `workers`, half the cores | ExUnit's `max_cases` (twice the schedulers, about four times as many) with `workers` drivers: modules past `workers` wait at no cost, those that never call `browser/1` are unaffected |
| per-project worker limit | `project.workers` | not needed: one configuration per invocation sets `workers` per run; serial runs use ExUnit's `async: false` |
| `fullyParallel` | a file's tests across workers | not ported: ExUnit runs a module's tests serially |

The defaults: `workers` half the schedulers (upstream's number), ExUnit's `max_cases` unchanged.
`workers` is not `max_cases`: each running browser test keeps a browser, a renderer and the
driver busy, so twice the cores oversubscribes the CPU. LiveView's e2e suite at `max_cases` 36 on
18 schedulers took 64.6 s at 15.0 GB peak with 9 workers (load 15), and 80.2 s at 38.7 GB with 36
(load 57). A suite that mostly waits on the app needs more `workers`, toward the core count, with
`max_cases` at about the core count: past it, the app's CPU saturates (see the guide's Workers
section).

Upstream knows a test's result in-process (`testInfo.errors`, `status`) when it closes contexts
and keeps artifacts; ExUnit tells `on_exit` nothing. So `use PlaywrightEx.Test` brings a `test`
macro that hands the body to `ExUnit.Case.test/3` with a mark at its end and a `catch` that
notes the error and re-raises it: a test passed when it was marked and its process exited
`:shutdown`, which a monitor sees for raises, exits, throws, timeouts (`:killed`), linked crashes
and failed setups. The `catch` gives `error-context.md` the errors; failure output stays
ExUnit's, byte for byte (tested). Its `setup` registers the test and adds the test's first
`on_exit`, which runs last. The mark also takes the end-of-body screenshots
(`didFinishTestFunction`). Not covered: doctests and other macros' tests (no mark: their
artifacts are kept), a failure only in an `on_exit` (it counts as passed), and a failure in a
case template's own `setup` before the registration. Rejected: an ExUnit formatter (a second
piece to install; `module_finished` never comes for a module `--max-failures` stops), a
`defoverridable` wrapper of each test (renames the test's frame), and a monitor on the
`setup_all` process (its `DOWN` races the user's `on_exit`).

A crashed browser fails the remaining tests of its module, where upstream restarts its worker;
the failed module's driver is then stopped. ExUnit gives the context a
`parameterize:` module's values, not its parameter map, so the output dir guesses the map for
its hash.

The matchers' `testInfo` is the running test, found by the calling process or its `$callers`
(upstream's worker sets it per test): it resolves snapshot names by upstream's path templates
and keeps the test's errors, a matcher result's `softError` (a snapshot it wrote, a soft
matcher's failure). The `test` macro's mark raises them at the end of the body, one as itself and
several as an `ExUnit.MultiError` (with a later failure too), which ExUnit 1.18 to 1.20 report as
numbered failures; a test without them fails as before. A matcher outside a test (no `testInfo`)
prints the soft error, as before, and a soft matcher there fails as any, as upstream's without a
step.

The matchers and traces need part of Playwright Test's worker, so that part is ported:
`PlaywrightEx.Test.TestInfo` (`testInfo.ts`: snapshot paths, `_failWithError`, steps, `attach`),
`PlaywrightEx.Test.TestTracing` (`testTracing.ts`: `test.trace`) and `step/3` (`test.step`),
with upstream source references and `-- not ported`/`# deviation:` comments. They have no
`@upstream`, as parity tracks the client API, not the runner; the rest of the runner is native.

`toPass` and `expect.poll` are ported (`matchers.ts`, `expect.ts`, `pollAgainstDeadline`), as
upstream's specs and suites ported onto `PlaywrightEx.Test` (LiveView's e2e) use them often
and a helper per suite drifted from upstream's intervals, deadlines and steps. Being matchers,
they get `expect.soft`, steps and the expect config for free; `poll`'s matcher is an ExUnit
assertion (`Expect.poll(fn -> v end, &assert(&1 == 3))`), as the jest matchers are not ported. Their
callbacks run in the calling process, not raced against the deadline (a running callback overruns
it), for the reason a step has no timeout.

Rejected: porting the rest of Playwright Test, `createExpect` (`expect.configure`; `expect.soft`
and `expect(x, message)` are fields of the receiver, `soft/1` and `message/2`, not a configured
`expect`), a step's `timeout` (a process can't be interrupted, so the body would run in another
process, with another `self()` and mailbox, and on past the timeout; the test's timeout bounds
it). For the pool and fixtures: a browser shared by every test at once (one connection serves
any process), its one driver and browser the bottleneck. On LiveView's e2e suite it was slower
than a worker per module and failed under load, for about half the memory
([#213](https://github.com/ftes/playwright_ex/issues/213)); on an app's full e2e suite (18 cores,
`max_cases` 18) it took 106.8 s at 4.5 GB, against 93.8 s at 6.5 GB for 16 workers. Also
rejected: ambient fixtures (context keys the
runner fills in: the user owns the map), a lazy module lease (a module's first test taking the
browser for the module; a scope holds what it calls), serving waiters LIFO (first come first
served bounds every wait), an `:open` lease that outlives its scope, `fresh: true` for a cold
driver (`on_start` sets up each new one), retry modes (ExUnit has no retries), and tags for
options other than the recording modes (a template maps its own tags).

## Mirroring upstream specs

Upstream's specs are the test suite: one module per spec file, same names and order, assertions
verbatim. The north star is to run what the non-JS clients run: specs of JS-only API, of the
in-process server (upstream's `default` mode, client and server in one Node process; we always run
as its `driver` mode does) or of the test runner stay bodiless, ruled out in
`test/upstream_not_ported.txt` against `test/upstream_registry.md` (playwright-python and -java's
mechanism, so their rule sets can be compared with `mix playwright_ex.parity --north-star`).
Parity fails on unported registry tests, stale rules and stale skips (a reason naming a member
that now exists), so a version roll surfaces new work. Skip tags and annotations: PORTING, "Tests".

## Test infrastructure

Fixtures mirror upstream's (`PlaywrightEx.UpstreamCase`, Playwright Test's default context and
launch options, 30 s test timeout, action timeout 0). `PlaywrightEx.TestServer` ports upstream's
test server on Bandit (`compress: false`, both loopbacks on one port, HTTP/1.1 https as Node's).
WebSocket framing uses cowlib's `cow_ws` on the raw socket: Bandit's WebSock answers every close
with 1000 and hides the peer's close frame. `TestProxy` is a small `:gen_tcp` HTTP and SOCKS5
proxy. Snapshot comparison and video decoding use the driver's own comparator and ffmpeg.
`launchServer` specs run on the driver's `launch-server` CLI or upstream's unmodified
`remote-server-impl.js`, as Python's and Java's suites do. The suite runs on `PlaywrightEx.Test`:
each upstream and example module holds `BrowserPool.browser/1`, upstream's worker, all on one
driver key (under test, set up as Playwright Test's fixtures by `on_start`), so they reuse each
other's drivers. Cleanup closes only what a
test or module created: a passing module's driver goes on to the next. Tests of driver env vars run a second driver with its own env; under test the client keeps `__testHook*` keys per connection. Every long-lived child (servers, the
`ClientProcess` BEAM) exits on stdin EOF, so a killed test BEAM leaves no orphans
(`no_orphan_processes_test`). Upstream assets come from the pinned release cache, not vendored.
Stress and perf runs are manual, not CI.

## CI

One matrix runs chromium, firefox and webkit on one Xvfb per job, split by `mix test --partitions`
(test files round-robin) into 6 jobs for firefox and 3 each for the others; the aggregate `quality`
job is the check to require, and every job blocks it. Test failures (exit 2) are rerun once with `--failed`; compile
errors (exit 1) are not. One rerun rather than upstream's `retries: 3`, so flakes stay visible.
`max_cases` is half the schedulers on CI, like Playwright's default workers (`PW_MAX_CASES`, or the
workflow_dispatch input `max_cases`, overrides it). Headed tests run under xvfb with
`HEADED=1 --only headed`, in each browser's first partition. deps and `_build` are cached, written
on main only. A new push to a PR cancels its running CI; other runs (main, nightly, dispatched
experiments) are never cancelled or queued. A daily workflow checks npm for a new release and opens a
draft PR that ports it per PORTING.
