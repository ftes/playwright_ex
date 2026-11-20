# What's ported

✓ ported, ◐ partly, ✗ not ported, n/a: ExUnit's own. The client is a port of the JS client, file
by file, and the `playwright.parity` Mix task checks in CI that every upstream client file has a
module or a reason it has none. The details: [Not supported](../porting-playwright-test.md#not-supported)
and "Not ported yet" in Porting Playwright Test specs, and the out-of-scope list in
[architecture.md](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md#generated-facade).

## Client

| JS client | | |
|---|---|---|
| BrowserType: `launch`, `launchPersistentContext`, `connect`, `connectOverCDP` | ✓ | `Playwright.BrowserType` |
| `launchServer`, `BrowserServer`, `connectOverCDP` with a transport | ✗ | JS-only |
| Browser, BrowserContext, Page, Frame, Locator, FrameLocator | ✓ | |
| ElementHandle, JSHandle | ✓ | `evaluate` takes JS source ([API conventions](api-conventions.md#evaluate-takes-js-source)) |
| routing, HAR record and replay, WebSocket, WebSocketRoute | ✓ | `Playwright.Route`, `BrowserContext.route_from_har/3`, `Playwright.WebSocketRoute`; no `URLPattern` (Elixir has none) |
| APIRequest | ✓ | `Playwright.APIRequest`, `Playwright.APIRequestContext` |
| Tracing, Video, Screencast | ✓ | |
| Download, Dialog, FileChooser, Clock, Coverage, CDPSession | ✓ | |
| aria snapshots | ✓ | `Locator.aria_snapshot/2` |
| custom selector engines | ✓ | `Selectors.register/4` |
| every other class of the API: Keyboard, Mouse, Touchscreen, Worker, Request, Response, ConsoleMessage, WebStorage, Credentials, ... | ✓ | and the devices, `Playwright.device/1` |
| Electron, Android | ✗ | experimental in JS (`_electron`, `_android`), not in its API docs (`api.json`) |
| CLI: `install`, `show-trace` | ✓ | `mix playwright.install`, `mix playwright.cli` |
| CLI: `codegen` | ◐ | `mix playwright.cli codegen` runs the driver's, which writes no Elixir |

## Test runner

`Playwright.Test` runs Playwright Test's parts on ExUnit ([Testing with
ExUnit](../testing-with-exunit.md)).

| Playwright Test | | |
|---|---|---|
| `test`, `describe` | n/a | a `describe` doesn't nest |
| `describe.serial`, serial mode | n/a | one test, with a step per test |
| hooks | n/a | `setup`, `setup_all`, `on_exit` |
| fixtures `browser`, `browserName`, `context`, `page` | ◐ | `Playwright.Case`; a `BrowserType.launch` in a test doesn't inherit `launch_options` |
| fixtures `request`, `baseURL` | ◐ | a line each ([What differs](../porting-playwright-test.md#what-differs)) |
| custom fixtures (`test.extend`) | n/a | `setup`, case templates; option fixtures are tags |
| `test.use` | ◐ | values, not functions ([Test options](../test-options.md)) |
| projects | ◐ | `parameterize:`; no per-project `outputDir`, `snapshotDir`, `snapshotPathTemplate`, `dependencies` |
| workers | ◐ | `Playwright.Test.BrowserPool`; no `fullyParallel`, no fresh worker after a failed test |
| retries | ◐ | `mix test --failed`, which the retry modes go by ([Retries](../test-artifacts.md#retries)) |
| sharding | n/a | `mix test --partitions` |
| timeouts: test, action, navigation, expect | ✓ | ExUnit's test timeout, `action_timeout`, `navigation_timeout`, `config :playwright, :expect` |
| `test.skip`, `test.fixme`, `test.slow` on a test; tags | n/a | tags known before the run (`@tag :skip`, `@tag timeout:`, `--only`) |
| `test.skip(condition)` inside a test | ✗ | ExUnit can't skip a running test |
| `test.fail`, annotations | ✗ | |
| `test.step` | ◐ | `Playwright.Test.step/3`; no step timeout, no `step.attach`, a `setup_all` step is recorded nowhere |
| `testInfo` | ✓ | `Playwright.Test.info/0`, `attach/2`, `output_path/1`, `snapshot_path/2` |
| web-first matchers, `expect.soft`, `expect.poll`, `toPass` | ✓ | `Playwright.Expect`; no `URLPattern` |
| generic and asymmetric matchers (`toEqual`, `expect.any`, ...), `expect.configure` | ✗ | ExUnit's `assert`; the matchers' own `timeout:` |
| `expect.extend`, `resolves`, `rejects` | ✗ | |
| `toHaveScreenshot` | ✓ | |
| `toMatchAriaSnapshot` | ◐ | no rebaselining of inline snapshots into the source |
| `toMatchSnapshot` | ✗ | |
| traces, screenshots, videos, `error-context.md` | ◐ | the `trace`, `screenshot` and `video` options; a `setup_all` context isn't recorded, the test's stdout and stderr aren't in the trace |
| reporter `github` | ✓ | `Playwright.Test.GitHubFormatter` |
| reporters `list`, `line`, `dot` | n/a | ExUnit's CLI formatter |
| reporters `json`, `junit` | n/a | an ExUnit formatter from Hex, such as `junit_formatter` |
| reporters `html`, `blob`; `merge-reports` | ✗ | |
| `webServer`, `globalSetup` | n/a | `test_helper.exs` |
| UI mode, watch mode | ✗ | |
