# Porting LiveView's e2e suite: what's missing

What has no direct equivalent when porting `phoenix_live_view/test/e2e` (Playwright Test, JS) to
`PlaywrightEx.Test` on ExUnit, and the workaround used. The client API (pages, locators,
matchers, `route_web_socket`, `wait_for_event`, coverage) ports one to one; the gaps are in the
runner and in JS-the-language.

## Runner (Playwright Test vs ExUnit + PlaywrightEx.Test)

| Upstream | Here | Fidelity |
| --- | --- | --- |
| `projects` (chromium, firefox, webkit with `devices[...]`) | `parameterize:` over `browser_name`, device options from `Playwright.devices/1` | same |
| `browserName` fixture | `browser_name` parameter in the context | same |
| `test.skip()` / `test.skip(cond, reason)` at runtime | `if browser_name != :webkit do ... end` around the body | reported as passed, not skipped: ExUnit has no runtime skip, and parameters are not tags (`--exclude browser_name:webkit` filters nothing) |
| fixture teardown that fails the test (`page` fixture's `pageChecks`) | `on_exit` with an `Agent` for the collected errors | same result; the failure is reported from `on_exit` |
| `test.use({ ignoreJSErrors: true })` (option fixture) | `@tag` / `@describetag ignore_js_errors: true`, read by the setup | same |
| `test.beforeEach` / `test.afterEach` | `setup` / `on_exit` registered in a `setup` | same order (afterEach before fixture teardown) |
| module-level `let` reset in `beforeEach` | an `Agent` per test (the `on_exit` runs in another process) | same |
| `expect(fn).toPass()` | `LiveViewE2E.Utils.to_pass/2` (upstream's intervals and default timeout) | same; not in PlaywrightEx (runner feature) |
| `request` fixture | `LiveViewE2E.Case.request_fixture/1`, created on demand | same (upstream's is lazy too) |
| monocart coverage fixture + reporter (chromium) | left out | no coverage report; runtime comparisons run upstream both with and without it |
| `retries: 2` on CI | none | ExUnit has no retries (`mix test --failed` reruns) |
| `globalTeardown` (POST `/halt`) | none: the server is started and stopped by `bin/server` | same |

## Language and concurrency

| Upstream | Here | Fidelity |
| --- | --- | --- |
| A call started and awaited later (`const p = locator.evaluate(() => new Promise(...)); ...; await p`) | No un-awaited call form outside `wait_for_*`; a `Task` races the next action. `attributeMutations` installs its observer with one blocking `evaluate` and reads it with a second | same observable result for the helper |
| `Promise.all([expect(a)..., expect(b)...])` in `syncLV` | sequential matchers | same (each retries until it holds) |
