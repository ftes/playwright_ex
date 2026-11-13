# LiveView e2e on PlaywrightEx.Test

A mechanical port of [Phoenix LiveView's e2e suite](https://github.com/phoenixframework/phoenix_live_view/tree/main/test/e2e)
(Playwright Test) to ExUnit with `PlaywrightEx.Test`, to find what's missing and compare runtime.
Gaps and workarounds: [DIFFICULTIES.md](DIFFICULTIES.md).

Both suites run against the same LiveView e2e server:

```sh
# a LiveView checkout, once
git clone https://github.com/phoenixframework/phoenix_live_view && cd phoenix_live_view
MIX_ENV=e2e mix deps.get && mix deps.get && mix assets.build && npm ci

# the server on :4004
LV_PATH=path/to/phoenix_live_view bin/server

# this port (all three browsers; BROWSERS=chromium for one)
mix test

# upstream, without its globalTeardown (which halts the server)
cd path/to/phoenix_live_view/test/e2e && npx playwright test -c playwright.noteardown.config.js
```

## Runtime on the final #201 stack (2026-11-13)

Pin `regexp-new-regex` 1dcc2715 (#204 merge): `BrowserPool.browser/1` (a browser per module, as
Playwright Test's workers; the shared pool is gone) and cheaper tracing (passing
`retain_on_failure` tests discard their trace chunks). Measured by the #201 session under the
perf lock with `caffeinate`, 9 workers, against upstream's 58.0 s from the quiet run below.

| Run | Wall (`Finished in`) | Result |
| --- | --- | --- |
| port, seed 1 | 56.0 s | 697 / 699 |
| port, seed 2 | 57.6 s | 698 / 699 |

Module time (summed over the 219 modules) is +7.7% over upstream's, down from +19.4%: chromium
+8 s, webkit +12 s, firefox +10 s. The median per-test gap is +24-30 ms (it was +88 ms). Module
time exceeds test time by 15-17 s, mostly in one-test Firefox modules, each 1-4.6 s slower than
upstream's same file. Probably a browser start per module, where upstream's workers reuse
one; not measured. Starting the longest modules first would save another ~10 s (an LPT
schedule: 46.8 s). Failures: `issue 3115` (Chromium, also upstream) every run, 2835 once.

The sections below are history, on pin 47caed19, where `BrowserPool.shared/1` and
`exclusive/1` still existed (the `POOL=exclusive` switch).

## Runtime at quiet load (2026-11-12, 18:47)

One run each, with the display kept awake (`caffeinate -di`: WebKit on macOS stalls while the
display is off, and a run with it off timed out ~150 WebKit tests in both suites). Pin
`regexp-new-regex` 47caed19, 699 tests, 3 browsers. Upstream has its coverage off.

| Workers / `max_cases` | Upstream | Port, default pool | Port, `POOL=exclusive` |
| --- | --- | --- | --- |
| 9 | 58.0 s | 70.8 s (+22%) | 65.0 s (+12%) |
| 4 | 97.7 s | 115.6 s (+18%) | |

The gap to upstream is about the same at 4 workers as at 9, so most of it is cost per test.
The shared browser's extra cost over exclusive ones (~6 s at 9) grows with concurrency.

Follow-up in [ftes/playwright_ex#213](https://github.com/ftes/playwright_ex/issues/213#issuecomment-6832051624):
- The order isn't the cause. `mix test` starts the runner, then compiles the test files in
  parallel (in an order shuffled by the seed). Each module joins the async queue when its file
  finishes compiling (`Mix.Compilers.Test.require_and_run/3`, `ExUnit.Server.add_module/2`;
  undocumented). Most files here compile in 30-50 ms, but navigation and streams take 220 ms and
  forms 457 ms (`mix test --profile-require time`), so these large modules tend to start last.
  Requiring the 8 longest files first in `test_helper.exs` gives 63.1 s. Upstream loses a similar
  10-14 s to its tail.
- The gap is per test: about +210-290 ms with the shared pool and about +110 ms with exclusive
  browsers. The `on_exit` teardown alone takes 107-192 ms per test.

## Runtime under load (2026-11-12, 16:46)

699 tests, 3 browsers, 9 workers / `max_cases` (half the cores) on both sides, one shared server,
Playwright 1.65. Full wall time including startup, one run each in interleaved order, under the
shared perf lock. Another session's single-file test runs kept the load at 16-25, so expect a
few seconds of noise.

| Run | Wall | Result |
| --- | --- | --- |
| upstream, coverage off | 63 s, 62 s | 5 / 3 failed, 6 skipped |
| upstream as shipped (chromium coverage, monocart report) | 64 s | 3 failed, 6 skipped |
| port, default pool (shared chromium/webkit, exclusive firefox) | 75 s, 73 s | 2 / 1 failed |
| port, `POOL=exclusive` (a browser per module, as upstream's workers) | 67 s | 1 failed |

The port takes about 15-20% longer with the default pool and about 7% longer with exclusive
browsers. Under this load, sharing one browser across 9 concurrent modules costs more than it
saves. Upstream's coverage costs little here.

Failures in these runs: `issue 3115` (Chromium) in every run of both suites. Upstream also
failed 2835 in every run, on one or two browsers that varied between runs: it reads the upload
state before the auto upload consumes the files. Upstream failed `streams work in teleported
LiveComponent`, 3199 (Firefox) and 3529 (Firefox) once each. The port failed 3199 (Chromium)
once.
The port never failed 2835; perhaps its sequential `sync_lv` waits slightly longer than
upstream's `Promise.all` (not verified). Upstream's 6 skips are passes in the port
(DIFFICULTIES.md).

`playwright.noteardown.config.js` (put it next to upstream's `playwright.config.js`):

```js
import config from "./playwright.config.js";
const { globalTeardown, ...rest } = config;
export default process.env.PW_NO_COVERAGE ? { ...rest, reporter: [["list"]] } : rest;
```
