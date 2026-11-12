# Porting LiveView's e2e suite: what's missing

What has no direct equivalent when porting `phoenix_live_view/test/e2e` (Playwright Test, JS) to
`PlaywrightEx.Test` on ExUnit, and the workaround used. The client API (pages, locators,
matchers, `route_web_socket`, `wait_for_event`, coverage) ports one to one; the gaps are in the
runner and in JS-the-language.

## Status in PlaywrightEx (2026-11-12, from the #201 stack's session)

- In progress on the #201 stack:
  - `toPass` / `expect.poll`, ported into the library. Timeout 0 means "until the test's timeout". Contexts now close shortly before ExUnit kills the test, so the call that hung fails with its call log. `to_pass/2` here can switch to it.
  - "Start now, await later": a public `PlaywrightEx.Promise.async/1` returns once the call is sent, and concurrency.md will say when to use it and when `Task.async` is right instead (a click that opens a dialog).
- Guide notes, in a new "Porting Playwright Test specs" section:
  - listener state that outlives the test (send to the test pid, `off` first, or unlinked state)
  - teardown checks that fail the test, and option fixtures as tags
  - `projects` with `devices[...]`
  - a route handler that waits on the test
  - the porting traps: `:null`, string keys, `RegExp.new`
- By design: `ElementHandle` extends `JSHandle`, so call `JSHandle` functions on it. No delegates.
- Later, or not possible:
  - a per-test listener scope: #209
  - runtime skip (not possible in ExUnit), retries (rejected, use `--failed`), monocart coverage (third-party, not applicable), nested and duplicate describes, asymmetric matchers, module-level `let`s: #210

## Runner (Playwright Test vs ExUnit + PlaywrightEx.Test)

| Upstream | Here | Fidelity |
| --- | --- | --- |
| `projects` (chromium, firefox, webkit with `devices[...]`) | `parameterize:` over `browser_name`, device options from `Playwright.devices/1` | same |
| `browserName` fixture | `browser_name` parameter in the context | same |
| `test.skip()` / `test.skip(cond, reason)` at runtime | `if browser_name != :webkit do ... end` around the body | reported as passed, not skipped; see [Runtime skips](#runtime-skips) |
| fixture teardown that fails the test (`page` fixture's `pageChecks`) | `on_exit` with an `Agent` for the collected errors | same result; the failure is reported from `on_exit` |
| `test.use({ ignoreJSErrors: true })` (option fixture) | `@tag` / `@describetag ignore_js_errors: true`, read by the setup | same |
| `test.beforeEach` / `test.afterEach` | `setup` / `on_exit` registered in a `setup` | same order (afterEach before fixture teardown) |
| Nested `test.describe` (errors.spec.js) | the outer describe is the module (its `beforeEach` a module `setup`), the inner ones `describe`s: ExUnit's don't nest | same full test names; one level of grouping lost |
| `expect(...)` inside an event listener (errors.spec.js:36) | `assert` in the listener: PlaywrightEx.Test fails the test with it at the end of its body | same |
| The same `test.describe` name twice (forms.spec.js:8, one per path in a loop) | one `describe` with the loop inside: ExUnit rejects duplicate describe names | same full test names; grouping and order differ |
| module-level `let` reset in `beforeEach` | an `Agent` per test (the `on_exit` runs in another process) | same |
| `expect(fn).toPass()` | `LiveViewE2E.Utils.to_pass/2` (upstream's intervals and default timeout) | same; not in PlaywrightEx (runner feature) |
| `expect.poll(fn).toBe(...)` (4212, 4323, 4325) | `to_pass(fn -> assert ... end, timeout: 5_000)` | same (poll's intervals, the expect timeout); runner feature too |
| `request` fixture | `LiveViewE2E.Case.request_fixture/1`, created on demand | same (upstream's is lazy too) |
| monocart coverage fixture + reporter (chromium) | left out | no coverage report; runtime comparisons run upstream both with and without it |
| `retries: 2` on CI | none | ExUnit has no retries (`mix test --failed` reruns) |
| `globalTeardown` (POST `/halt`) | none: the server is started and stopped by `bin/server` | same |

## Runtime skips

The suite skips six times. Five depend only on the browser (components x2 and 3636 on WebKit,
colocated x2 on Firefox), one on feature detection in the page (4212: no
`Element.prototype.moveBefore`). ExUnit can do neither: a test can't mark itself skipped once
it runs, and its filters see tags, `test`, `module`, `async` and `test_group`, never
`parameterize:` parameters (`ExUnit.Runner.prepare_tests/4`, Elixir 1.20), so
`--exclude browser_name:webkit` filters nothing.

The port wraps the body in `if`, so a skipped test runs nothing and reports as passed. That
loses only the reporting (skip count, reason); coverage and runtime are the same. For the
browser-only skips, a static `@tag skip_webkit: true` with one browser per run
(`BROWSERS=webkit mix test --exclude skip_webkit`, like `--project webkit`) would give
real skips, but not in a run of all three browsers, and not for 4212.

## Language and concurrency

| Upstream | Here | Fidelity |
| --- | --- | --- |
| A call started and awaited later (`const p = locator.evaluate(() => new Promise(...)); ...; await p`) | No un-awaited call form outside `wait_for_*`; a `Task` races the next action. `attributeMutations` installs its observer with one blocking `evaluate` and reads it with a second | same observable result for the helper |
| A click awaited after the dialog it opens (`const click = locator.click(); const dialog = await waitForEvent("dialog"); ...; await click`, form-unsaved) | `Task.async` for the click: sequential deadlocks, as the click blocks until the dialog is handled. No race here, since the next step waits for the event the call causes | same |
| `expect.poll(...)` with `message:` | the assert's message | same |
| `Promise.all([expect(a)..., expect(b)...])` in `syncLV` | sequential matchers | same (each retries until it holds) |
| JS `null` in an `evaluate` result | `:null` (`undefined` is `nil`), as api-conventions.md says | same; trips up a port that writes `nil` |
| Objects from `evaluate` | maps with string keys (`item["entry"]["foo"]`) | same; noisier than JS |
| JS regex literals PCRE rejects (`/\patched=true/`: `\p` is `p` in JS without `u`, a compile error in PCRE) | `PlaywrightEx.RegExp.new("\\patched=true")`, which sends the JS source | same; a mechanical `~r//` doesn't compile |
| `undefined` to get a default argument (`evalLV(page, code, nested ? "#nested" : undefined)`) | the default spelled out at the call | same; the default is written twice |
| Listener state that outlives the test (module-level arrays filled by `page.on`/`ws.on`: forms, navigation, form-unsaved, components) | an unlinked `Agent.start`, never stopped, or `Page.off/3` before stopping it (the page fixture). Listeners fire until the context closes, last in PlaywrightEx.Test's `on_exit`, after every user `on_exit`; a linked or stopped Agent logs "Uncaught in event listener" | same; one small process leaked per test. Runner gap: no hook after context close, no listener lifetime tied to the test |
| `querystring.parse` | `URI.decode_query` | same here; differs on repeated keys |
| Asymmetric matchers in `toEqual`: `expect.arrayContaining`, `objectContaining` (js.spec.js) | a hand-rolled `assert_array_containing/2`: plain maps must be elements, `{:object_containing, map}` a subset of one | same strength; ExUnit has no asymmetric matchers |
| `expect.stringMatching(re)`, `expect.any(String)` inside a `toEqual` list (streams.spec.js) | `assert [%{"id" => id, ...}, ...] = list`, then `assert id =~ ~r/.../` | same (order and length exact; map patterns are partial, the objects have no other keys); reads less like upstream |
| Tests generated in a loop (`for (const kind of ...) test(...)`) | module-level `for` with `unquote(kind)` in the body | same |
| Arrays mutated in a loop (`push`/`unshift`) | `Enum.reduce` | same |
| A `routeWebSocket` handler that `await`s a promise to hold a message (4350; uploads.spec.js:23-46, where the test also replaces the promise) | the handler must not block (it stalls the connection), so it hands the message to a spawned process that forwards it once released; a replaceable deferred lives in an Agent | same (other messages pass while one is held, as in JS); ~30 lines of plumbing for 3 of JS. A shared `Deferred` would help |
| Loop-generated tests over data built by a helper (4465: `file(...)`) | loop over literal tuples, build the data in the body: a `defp` can't run at compile time | same names and data |
| A spec-local helper named `setup` (4465) | renamed `setup_page`: clashes with ExUnit's `setup` | same |
| `elementHandle.evaluate` (4325) | `JSHandle.evaluate!(element_handle, ...)`: no inheritance, so `ElementHandle` has no `evaluate!` of its own | same; a client ergonomics gap (JS's `ElementHandle extends JSHandle`) |

Upstream flake kept: `issue 3115 - cancelled upload is not re-added` (uploads) fails on Chromium
under parallel load, in both suites (upstream `--repeat-each 4 --workers 9`: 4/4), and passes
alone. Tagged `:upstream_failure`. So is 3530 ("item-4 mounted" counted 0: `syncLV` can return
before the nested LiveView's hook logs; upstream `--repeat-each 30` fails 16 of 90). 3199's
"can limit phx-remove" checks a class that lives 100 ms and failed twice in ~50 Chromium runs
under load (upstream's copy passed 180/180, its sibling test flakes the same way); untagged.
The tags are labels only: nothing is excluded.

Upstream quirk kept: 3709 passes a string with `(reading 's')` to `expect.stringMatching`, which
compiles it as a RegExp (the parentheses are a group), so it can't match the real error text and
the assertion is vacuous. Ported as the same regex.
