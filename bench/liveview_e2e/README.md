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

`playwright.noteardown.config.js` (put it next to upstream's `playwright.config.js`):

```js
import config from "./playwright.config.js";
const { globalTeardown, ...rest } = config;
export default process.env.PW_NO_COVERAGE ? { ...rest, reporter: [["list"]] } : rest;
```
