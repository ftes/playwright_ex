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

## Runtime (2026-11-12)

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
