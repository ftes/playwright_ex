# What's ported

Playwright's API is here: browsers, contexts, pages, locators, actions, network mocking, API
testing, emulation, tracing and video, all but `launchServer` (JS-only), `URLPattern`, Electron
and Android. That is the first area below, Automating a browser, and it works without a test
runner too: in an app, a script or a release, for scraping, PDFs, screenshots or tools of your
own. On the test side,
`Playwright.Test` brings Playwright Test's browsers, options, projects, web-first assertions,
snapshots, traces, screenshots, videos and steps to ExUnit ([Testing with
ExUnit](../testing-with-exunit.md)). What's missing is mostly what ExUnit can't host (skipping a
running test, retries in a run, serial mode), a few runner features not ported yet (`test.fail`,
annotations, the HTML report) and JS tooling (UI mode, codegen for Elixir).

✓ ported, ◐ partly, ✗ not ported, n/a: ExUnit or Mix has its own, named in the row. The client
is a port of the JS client, file by file, and the `playwright.parity` Mix task checks in CI that
every upstream client file has a module or a reason it has none.

## Overview

Each area's row lists its main features, each feature's row its main gaps.

| Feature | | Main features / gaps |
|---|---|---|
| **[Automating a browser (tests and scripts)](#automating-a-browser-tests-and-scripts)** | | apps and scripts ✓ · locators and actions ✓ · routing, HAR and WebSockets ✓ · `URLPattern` ✗ · API requests ✓ · devices ✓ · tracing and video ✓ · `launchServer` ✗ · codegen ◐ |
| [Without a test runner](#without-a-test-runner) | ✓ | |
| [Browsers and contexts](#browsers-and-contexts) | ◐ | no `launchServer` (JS-only) |
| [Pages, frames and handles](#pages-frames-and-handles) | ✓ | `evaluate` takes JS source |
| [Locators and actions](#locators-and-actions) | ✓ | |
| [Events and other classes](#events-and-other-classes) | ✓ | |
| [Network](#network) | ◐ | no `URLPattern` |
| [API testing](#api-testing) | ✓ | |
| [Emulation and devices](#emulation-and-devices) | ✓ | |
| [Tracing, screenshots and video](#tracing-screenshots-and-video) | ✓ | |
| [CLI and tooling](#cli-and-tooling) | ◐ | codegen writes no Elixir; no `@axe-core/playwright` |
| **[Writing tests](#writing-tests)** | | `test`, `describe` and hooks n/a · fixtures ◐ · nested `describe` and serial mode ✗ · runtime `test.skip` ✗ · `test.fail` and annotations ✗ |
| [Tests, hooks and annotations](#tests-hooks-and-annotations) | ◐ | no nested `describe`, serial mode, runtime `test.skip`, `test.fail`, annotations or `test.abort` |
| [Fixtures](#fixtures) | ◐ | option fixtures are tags; no function-valued options |
| **[Assertions and snapshots](#assertions-and-snapshots)** | | web-first assertions ◐ · `soft`, `poll` and `toPass` ✓ · `toHaveScreenshot` ✓ · `toMatchAriaSnapshot` ✓ · generic matchers n/a · `expect.extend` ✗ · `toMatchSnapshot` ✗ |
| [Assertions](#assertions) | ◐ | generic matchers are ExUnit's `assert`; no `expect.configure` or `expect.extend`; `toHaveURL` doesn't encode the expected URL |
| [Snapshots](#snapshots) | ◐ | no `toMatchSnapshot`, no inline aria rebaselining |
| **[Configuring tests](#configuring-tests)** | | `test.use` at every level ✓ · context options ✓ · projects ✓ · worker options ◐ · `reuseContext` ✗ · `webServer` and `globalSetup` n/a |
| [Options and projects](#options-and-projects) | ◐ | a project is a name and `use` options; no `reuseContext` |
| [Global setup and webServer](#global-setup-and-webserver) | n/a | |
| **[Running in CI and at scale](#running-in-ci-and-at-scale)** | | workers ◐ · `fullyParallel` ✗ · sharding n/a · retries ◐ · test, expect and action timeouts ✓ · `globalTimeout` ✗ · `github` reporter ✓ · HTML report ✗ |
| [Workers and parallelism](#workers-and-parallelism) | ◐ | no `fullyParallel`, no fresh worker after a failed test, no worker index |
| [Retries and timeouts](#retries-and-timeouts) | ◐ | retries are `mix test --failed`; no global timeout |
| [Reporters](#reporters) | ◐ | no `html`, `blob`, `merge-reports`, `perfetto` or `coverage` |
| **[Debugging and running tests](#debugging-and-running-tests)** | | traces, screenshots and videos ✓ · `error-context.md` ✓ · `test.step` ✓ · a step's `timeout` ✗ · testInfo ◐ · `setup_all` recording ✗ · UI and watch mode ✗ |
| [Artifacts](#artifacts) | ◐ | `setup_all` contexts unrecorded; no stdout and stderr in the trace |
| [Steps and testInfo](#steps-and-testinfo) | ◐ | no step timeout or `TestStepInfo`; `setup_all` steps unrecorded; part of testInfo |
| [Running tests](#running-tests) | ◐ | no UI mode, watch mode, VS Code extension or test agents |
| **[Other platforms](#other-platforms)** | | Electron ✗ · Android ✗ |
| [Electron and Android](#electron-and-android) | ✗ | experimental in JS |

## Automating a browser (tests and scripts)

### Without a test runner

| Feature | | Elixir / note |
|---|---|---|
| apps and scripts | ✓ | `Playwright.Supervisor` in your supervision tree, or started in a script (`mix run`), and `Playwright.instance/1` ([Starting the driver](getting-started.md#starting-the-driver), [First script](getting-started.md#first-script)) |
| releases | ✓ | the supervisor installs the driver on first start, not the browsers, and a release has no `mix playwright.install`: call `Playwright.Driver.install_browsers/2` (`["chromium"]`), or ship the browsers at `PLAYWRIGHT_BROWSERS_PATH` (Playwright's Docker image has them); the driver's settings at boot go in `config/runtime.exs` (`Playwright.Driver`) |
| remote browsers and CDP | ✓ | `BrowserType.connect/3`, `connect_over_cdp/3` ([Remote browsers](../debugging-and-ci.md#remote-browsers)) |

### Browsers and contexts


| Feature | | Elixir / note |
|---|---|---|
| `launch`, `launchPersistentContext` (channels, `headless`, `slowMo`, Chrome extensions) | ✓ | `Playwright.BrowserType.launch/2`, `launch_persistent_context/3` |
| `connect`, `connectOverCDP` | ✓ | `BrowserType.connect/3` (through the local driver, as the JS client), `connect_over_cdp/3` |
| `launchServer`, `BrowserServer`, `connectOverCDP` with a transport | ✗ | not planned: JS-only ([architecture](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md#generated-facade)); a server is the driver's `run-server` ([Remote browsers](../debugging-and-ci.md#remote-browsers)) |
| browser contexts: isolation, several per test | ✓ | `Playwright.Browser.new_context/2`, `Playwright.BrowserContext` |
| storage state, cookies, IndexedDB (logging in once) | ✓ | `BrowserContext.storage_state/2`, `storage_state:` ([Logging in once](../testing-with-exunit.md#logging-in-once)) |

### Pages, frames and handles


| Feature | | Elixir / note |
|---|---|---|
| pages, new pages, popups, navigation (`goto`, `waitForURL`, `waitForLoadState`) | ✓ | `Playwright.Page` ([Events and waiting](../events-and-waiting.md#popups-and-new-pages)) |
| frames, `FrameLocator` | ✓ | `Playwright.Frame`, `Playwright.FrameLocator` |
| `evaluate`, `evaluateHandle`, `addInitScript` | ✓ | JS source, not a function ([API conventions](api-conventions.md#evaluate-takes-js-source)); an init script string is sent as is ([What differs](../porting-playwright-test.md#what-differs)) |
| `exposeFunction`, `exposeBinding` | ✓ | the callback runs in a process of its own ([Concurrency](../concurrency.md#listeners-run-in-processes)) |
| `ElementHandle`, `JSHandle` | ✓ | an `ElementHandle` takes the `JSHandle` functions; `ElementHandle.input_value` has no options arity (upstream documents a `timeout` there as deprecated and ignored, and its client takes none) |

### Locators and actions


| Feature | | Elixir / note |
|---|---|---|
| `getByRole`, `getByText`, `getByLabel`, `getByPlaceholder`, `getByAltText`, `getByTitle`, `getByTestId` | ✓ | `Page.get_by_role/3`, ...; roles as atoms or strings |
| CSS, XPath, `nth`, chaining, `filter`, `and`, `or`, Shadow DOM, strictness | ✓ | `Page.locator/3`, `Locator.filter/2`, `Locator.and_/2`, `Locator.or_/2` |
| actions (`fill`, `check`, `selectOption`, `click`, `press`, `setInputFiles`, `dragTo`, ...), actionability | ✓ | `Playwright.Locator`, `Playwright.Keyboard`, `Playwright.Mouse`, `Playwright.Touchscreen` |
| locator handlers, custom selector engines, `setTestIdAttribute` | ✓ | `Page.add_locator_handler/4`, `Selectors.register/4` |
| aria snapshots | ✓ | `Locator.aria_snapshot/2` |

### Events and other classes


| Feature | | Elixir / note |
|---|---|---|
| `on`, `once`, `off`, `waitForEvent` | ✓ | events are atoms (`:request_failed`) or upstream's strings ([API conventions](api-conventions.md#enums-nil-and-null)) |
| dialogs, downloads, file choosers, console messages, page errors | ✓ | [Events and waiting](../events-and-waiting.md) |
| `Clock`, `Coverage`, `CDPSession`, `Worker` | ✓ | |
| `WebStorage`, `Credentials`, `Debugger`, `WebMCP`, `Disposable` | ✓ | |
| errors: `TimeoutError`, `TargetClosedError`, `AbortSignal` | ✓ | exceptions, `Playwright.TimeoutError`, ... ([API conventions](api-conventions.md#errors)) |

### Network


| Feature | | Elixir / note |
|---|---|---|
| network events, `waitForRequest`, `waitForResponse` | ✓ | [Waiting for requests and responses](../network.md#waiting-for-requests-and-responses) |
| routing: `fulfill`, `continue`, `abort`, `fallback`, `route.fetch`; globs, regexes, functions | ✓ | `Playwright.Route` ([Mocking with routes](../network.md#mocking-with-routes)); a function gets a `URI` |
| `URLPattern` | ✗ | not planned: a JS global, Elixir has none |
| HAR record and replay | ✓ | `record_har:`, `BrowserContext.route_from_har/3` |
| WebSockets, `routeWebSocket` | ✓ | `Playwright.WebSocket`, `Playwright.WebSocketRoute` ([WebSockets](../network.md#websockets)) |
| HTTP authentication, proxy, client certificates, service workers | ✓ | context options |

### API testing


| Feature | | Elixir / note |
|---|---|---|
| `APIRequestContext`: `get`, `post`, `fetch`, `data`, `form`, `multipart` | ✓ | `Playwright.APIRequest`, `Playwright.APIRequestContext` ([API testing](../network.md#api-testing)) |
| a context's `request`, shared cookies and storage state | ✓ | `BrowserContext.request/1`, `Page.request/1` |
| `expect(response).toBeOK()` | ✓ | `Expect.to_be_ok/1` |

### Emulation and devices


| Feature | | Elixir / note |
|---|---|---|
| devices (`devices['iPhone 13']`) | ✓ | `Playwright.device/1`, `Playwright.devices/0` |
| viewport, mobile, touch, locale, timezone, geolocation, permissions, color scheme, media, user agent, offline, JavaScript | ✓ | context options, `Page.emulate_media/2` |

### Tracing, screenshots and video


| Feature | | Elixir / note |
|---|---|---|
| tracing, chunks, groups | ✓ | `Playwright.Tracing` |
| screenshots: page, full page, element | ✓ | `Page.screenshot/2`, `Locator.screenshot/2` |
| videos, screencast | ✓ | `Playwright.Video`, `Playwright.Screencast` |

### CLI and tooling


| Feature | | Elixir / note |
|---|---|---|
| `install`, `--with-deps`, `install-deps`, `uninstall` | ✓ | `mix playwright.install`, `mix playwright.cli install-deps` and `uninstall` |
| `show-trace`, `open`, `screenshot`, `pdf`, `mcp`, ... | ✓ | `mix playwright.cli`, the driver's CLI |
| codegen | ◐ | `mix playwright.cli codegen` runs the driver's; not planned: its targets are the driver's (JavaScript, Python, Java, C#) |
| Inspector (`PWDEBUG=1`, `page.pause()`), `DEBUG=pw:api` | ✓ | [Watching it run](../debugging-and-ci.md#watching-it-run) |
| Docker image, remote browsers | ✓ | [Remote browsers](../debugging-and-ci.md#remote-browsers) |
| `@axe-core/playwright` | ✗ | not ported yet: evaluate axe-core in the page ([Accessibility testing](../testing-with-exunit.md#accessibility-testing)) |

## Writing tests

### Tests, hooks and annotations


| Feature | | Elixir / note |
|---|---|---|
| `test`, `describe` | n/a | ExUnit's, the `test` macro of `use Playwright.Test` |
| nested `describe` | ✗ | not planned: ExUnit's `describe` doesn't nest; a module per outer `describe` ([Not supported](../porting-playwright-test.md#not-supported)) |
| `beforeEach`, `afterEach`, `beforeAll`, `afterAll` | n/a | `setup`, `on_exit`, `setup_all`, an `on_exit` in `setup_all` |
| `describe.serial`, serial mode | ✗ | not planned: ExUnit runs a module's tests in random order; one test, with a `Test.step` per test |
| `test.only`, `test.skip()`, `test.fixme()`, `test.slow()` on a test, tags, `--grep` | n/a | tags known before the run: `@tag :skip` (`skip`, `fixme`), `@tag timeout:` (`slow`), `@tag :smoke` and `mix test --only smoke` (tags, `--grep`), `mix test file:line` (`only`) |
| `test.skip(condition)` in a running test | ✗ | not planned: ExUnit can't skip a running test ([#210](https://github.com/ftes/playwright_ex/issues/210)) |
| `test.fail`, annotations | ✗ | [#286](https://github.com/ftes/playwright_ex/issues/286) |
| parameterized tests | n/a | a `for` around `test`, ExUnit's `parameterize:` |
| `test.abort()` | ✗ | not ported yet |

### Fixtures


| Feature | | Elixir / note |
|---|---|---|
| `browser`, `context`, `page` | ◐ | `Playwright.Case`; a `BrowserType.launch` in a test doesn't inherit the `launch_options` (not ported yet: `_defaultLaunchOptions`) |
| `browserName`, `playwright` | ✓ | `browser_name` in `Playwright.Case`'s context, `Playwright.Test.BrowserPool.playwright/1` |
| `request`, `baseURL` | ◐ | a line each ([What differs](../porting-playwright-test.md#what-differs)); not planned: no fixtures the runner fills in, the test's context map is yours ([architecture](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md#test-runner)) |
| custom fixtures (`test.extend`), worker-scoped and automatic fixtures | n/a | `setup`, `setup_all`, case templates ([Your own case template](../test-options.md#your-own-case-template)) |
| option fixtures (`test.extend` with `{ option: true }`) | ◐ | not ported yet: plain tags or project keys that your `setup` reads ([A check after the test](../testing-with-exunit.md#a-check-after-the-test)) |
| function-valued options (`test.use({ locale: async ({}, use) => ... })`) | ✗ | not ported yet: the options are values |

## Assertions and snapshots

### Assertions


| Feature | | Elixir / note |
|---|---|---|
| locator, page and response assertions | ◐ | `Playwright.Expect`, all of upstream's; `toHaveURL` takes no `URLPattern`, resolves against the base URL with `URI.merge`, and doesn't encode its expected URL, so one with non-ASCII characters or spaces never matches: pass it encoded (not planned: encoding it would be a partial WHATWG port for one matcher, so [#229](https://github.com/ftes/playwright_ex/issues/229) was closed by documenting it, [URL globs](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md#url-globs)) |
| `not`, `expect.soft`, `expect(x, message)` | ✓ | `not_to_*` and `Expect.not_/1`, `Expect.soft/1`, `Expect.message/2` |
| `expect.poll`, `toPass` | ✓ | `Expect.poll/3` (its matcher an ExUnit assertion), `Expect.to_pass/2` (returns the passing attempt's value) |
| the config's `expect` (`timeout`, `toHaveScreenshot`, ...) | ✓ | `config :playwright, :expect` |
| `expect.configure` | ✗ | not planned: the options are the receiver's (`Expect.soft/1`, a matcher's `timeout:`), not a configured `expect` |
| generic matchers (`toBe`, `toEqual`, `toContain`, `toThrow`, ...) | n/a | ExUnit's `assert`, a step as upstream's `expect` ([Assertions](Playwright.Test.html#module-assertions)) |
| asymmetric matchers (`expect.any`, `objectContaining`, `toBeCloseTo`, ...) | n/a | patterns (`assert %{"id" => id} = ...`), `assert_in_delta/3` |
| `expect.extend`, `resolves`, `rejects` | ✗ | not planned: jest's `expect` isn't ported ([architecture](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md#generated-facade)) |

### Snapshots


| Feature | | Elixir / note |
|---|---|---|
| `toHaveScreenshot` (`maxDiffPixels`, `threshold`, `mask`, `stylePath`, ...) | ✓ | `Expect.to_have_screenshot/2` ([Snapshots](Playwright.Test.html#module-snapshots)) |
| `toMatchAriaSnapshot`, inline or in a file | ✓ | `Expect.to_match_aria_snapshot/3` |
| `updateSnapshots`, `ignoreSnapshots`, `snapshotDir`, `snapshotPathTemplate` | ✓ | `config :playwright, :expect` and `:test` |
| rebaselining inline aria snapshots into the source (`--update-source-method`) | ✗ | not ported yet |
| `toMatchSnapshot` | ✗ | not ported yet |

## Configuring tests

### Options and projects


| Feature | | Elixir / note |
|---|---|---|
| `test.use` in the config, a project, a file, a `describe`, a test | ✓ | [Options, devices and projects](../test-options.md) |
| context options (`baseURL`, `viewport`, `locale`, `storageState`, ...), `contextOptions` | ✓ | options of their own, `context_options` ([Context defaults](Playwright.Test.html#module-context-defaults)) |
| `browserName`, `defaultBrowserType`, `headless`, `channel`, `launchOptions`, `connectOptions` | ◐ | the module's, its project's or the config's, as upstream's; a test defined above `@moduletag Test.use(Playwright.device(...))` gets the device's browser but not its context options (not planned: ExUnit gives a test only the `@moduletag`s above it; put the line first, [Browser](Playwright.Test.html#module-browser)) |
| `actionTimeout`, `navigationTimeout`, `trace`, `screenshot`, `video` | ✓ | also per `describe` and test |
| `testIdAttribute` | ◐ | config only. Not planned: the client's is global, as upstream's (`locator.ts`), and ExUnit runs async tests at once in one VM, where upstream's worker runs one test at a time |
| `reuseContext` | ✗ | not ported yet |
| projects (`name`, `use`) | ✓ | `parameterize:` with `Playwright.Test.parameters/1` ([Projects](../test-options.md#projects)) |
| a project's `outputDir`, `snapshotDir`, `snapshotPathTemplate` | ✗ | config only ([#286](https://github.com/ftes/playwright_ex/issues/286)) |
| a project's `timeout`, `retries`, `testMatch`, `grep`, `repeatEach`, `metadata` | ✗ | not planned: ExUnit has no projects; a project is a `parameterize:` map, which ExUnit's filters don't see |
| the config file, `outputDir`, `preserveOutput` | ✓ | `config :playwright, :test` |
| `testDir`, `testMatch`, `testIgnore`, env vars | n/a | `mix.exs`'s `test_paths` and `test_pattern`; read env vars in the config (`System.get_env/2`) |

### Global setup and webServer


| Feature | | Elixir / note |
|---|---|---|
| `webServer` | n/a | `test_helper.exs` ([The app under test](../testing-with-exunit.md#the-app-under-test)) |
| `globalSetup`, `globalTeardown` | n/a | `test_helper.exs`, `ExUnit.after_suite/1` |
| setup projects, project `dependencies` | n/a | `test_helper.exs` ([Logging in once](../testing-with-exunit.md#logging-in-once)) |

## Running in CI and at scale

### Workers and parallelism


| Feature | | Elixir / note |
|---|---|---|
| workers: a browser each, reused after a passing scope, replaced once a failing one (a module or a test) releases it | ✓ | `Playwright.Test.BrowserPool` ([Workers](../test-artifacts.md#workers)) |
| a fresh worker after a failed test | ✗ | not ported yet: a module keeps its worker and its `setup_all` state for its other tests ([Contexts of `setup_all`](Playwright.Test.html#module-contexts-of-setup_all)), and a crashed browser fails the rest of its module, where upstream restarts its worker |
| `workers` | ◐ | a positive integer; not ported yet: upstream's `"50%"` or a numeric string |
| `fullyParallel`, parallel mode | ✗ | not planned: ExUnit runs a module's tests one after another; a module per `describe` with `async: true`, and for `fullyParallel: false` on shared state, a `group:` |
| `workerIndex`, `parallelIndex` | ✗ | not ported yet |
| sharding, `maxFailures`, test order | n/a | `mix test --partitions`, `--max-failures`, `--seed` |

### Retries and timeouts


| Feature | | Elixir / note |
|---|---|---|
| `retries` | ◐ | not planned: ExUnit has no retries in a run ([#210](https://github.com/ftes/playwright_ex/issues/210)); rerun the failures with `mix test --failed` ([Retries](../test-artifacts.md#retries)) |
| `testInfo.retry`, the retry modes | ✓ | retry 1 under `mix test --failed` |
| test timeout | ✓ | ExUnit's (`@tag timeout:`, `--timeout`); the test fails just before it with upstream's message (`TimeoutManagerError`), wherever it hangs; its `on_exit` callbacks run, then its contexts close with it, and the hung call's error follows the message ([Timeouts](Playwright.Test.html#module-timeouts)) |
| `test.setTimeout`, `test.slow` | n/a | `@tag timeout:` |
| `beforeAll` timeout | ✓ | the module's timeout bounds its `setup_all`, which fails with upstream's message (`TimeoutManagerError`); its contexts close with it, and the hung call's error follows the message ([Timeouts](Playwright.Test.html#module-timeouts)) |
| expect, action and navigation timeouts | ✓ | `config :playwright, :expect, timeout:`, `action_timeout`, `navigation_timeout` |
| `globalTimeout` | ✗ | not ported yet |

### Reporters


| Feature | | Elixir / note |
|---|---|---|
| `github`, `reportSlowTests` | ✓ | `Playwright.Test.GitHubFormatter` ([Annotations](../debugging-and-ci.md#annotations)) |
| `list`, `line`, `dot`, `failures` | n/a | ExUnit's CLI formatter |
| `null` | n/a | no formatter: `ExUnit.start(formatters: [])` |
| `json`, `junit` | n/a | an ExUnit formatter from Hex, such as `junit_formatter` |
| custom reporters | n/a | an ExUnit formatter |
| `html`, `blob`, `merge-reports`, `perfetto` | ✗ | not ported yet |
| `coverage` | ✗ | not ported yet: `Playwright.Coverage` collects, your code reports |

## Debugging and running tests

### Artifacts


| Feature | | Elixir / note |
|---|---|---|
| `trace`, `screenshot`, `video`: every mode and option | ✓ | [Traces, screenshots and videos](../test-artifacts.md#traces-screenshots-and-videos) |
| the video's step overlay (`show.test`) | ◐ | not ported yet: it keeps the title of a process killed inside a step, and shows an IPv6 host with a zone id as `fe80` |
| `error-context.md` | ✓ | |
| the test's output dir, `preserveOutput` | ✓ | [Artifacts](Playwright.Test.html#module-artifacts) |
| attachments | ✓ | `Playwright.Test.attach/2`, in the trace |
| `beforeAll` contexts, recorded per test | ✗ | not ported yet: create the context per test ([Contexts of `setup_all`](Playwright.Test.html#module-contexts-of-setup_all)) |
| the test's stdout and stderr in the trace | ✗ | not ported yet |

### Steps and testInfo


| Feature | | Elixir / note |
|---|---|---|
| `test.step` (`box`, `location`), `test.step.skip` | ✓ | `Playwright.Test.step/3`, `step_skip/3` ([Steps](Playwright.Test.html#module-steps)) |
| a step's `timeout` | ✗ | not planned: a step's body can't be interrupted in its own process; the test's timeout bounds it |
| `TestStepInfo` (`step.attach`, `step.skip()`) | ✗ | not ported yet: the body takes no argument |
| driver calls and matchers as steps | ✓ | `pw:api` and `expect` steps in the trace |
| hooks and fixtures as steps | ✗ | not ported yet |
| steps in `beforeAll` | ◐ | they run in `setup_all`, recorded nowhere (not planned: ExUnit runs it before any test); a route handler or listener registered inside a boxed `setup_all` step keeps that step as its steps' parent in later tests (not ported yet) |
| steps and asserts in handlers | ◐ | a handler registered inside `to_pass` or `poll` keeps the matcher's test, so its passed asserts record into that test even after it finished (not ported yet) |
| steps of a library's helpers | ✓ | `Playwright.Test.step/3` with `box: true` locates a helper's step and its errors at the caller; inner steps keep their own location, as upstream's |
| `test.info()` | ◐ | `Playwright.Test.info/0`: `test_pid`, `file`, `test_name`, `output_dir`, `retry`, `timeout`, `deadline`, `use`; `info/1` in `on_exit`, with `status`, `errors`, `duration`; `config`: `Playwright.Test.config/0`; the rest below |
| `test.info()` in `beforeAll` | ◐ | `info/0` in `setup_all` has the module's `file`, `timeout` and `use`, but no `test_pid`, which tells a test from `setup_all` (not planned: upstream's is the first test's, and ExUnit runs `setup_all` before any test) |
| `outputPath`, `attach`, `snapshotPath` | ✓ | `output_path/1`, `attach/2`, `snapshot_path/2` |
| `outputPath` in `beforeAll` | ✗ | not ported yet: `output_path/1` raises in `setup_all`, where upstream's is the first test's dir |
| `annotations`, `project`, `titlePath`, `workerIndex`, `snapshotSuffix`, `tags`, ...; `skip()`, `fail()`, `setTimeout()` | ✗ | not ported yet (annotations and `fail`: [#286](https://github.com/ftes/playwright_ex/issues/286); `skip` in a running test: not planned, [#210](https://github.com/ftes/playwright_ex/issues/210)) |

### Running tests


| Feature | | Elixir / note |
|---|---|---|
| `npx playwright test` and its flags (`--headed`, `--project`, `--last-failed`, ...) | n/a | `mix test` and its flags (`--failed`); the rest in the config, from env vars |
| `--debug` | n/a | `PWDEBUG=1 mix test --trace` ([Watching it run](../debugging-and-ci.md#watching-it-run)) |
| UI mode, watch mode | ✗ | not ported yet |
| VS Code extension | ✗ | not ported yet |
| test agents, component testing | ✗ | not ported yet |

## Other platforms

### Electron and Android


| Feature | | Elixir / note |
|---|---|---|
| Electron (`_electron`) | ✗ | not ported yet: experimental in JS, not in its API docs (`api.json`) |
| Android (`_android`) | ✗ | not ported yet: as Electron |

## Elixir only

- `Playwright.Test.BrowserPool`'s calls with options of their own: another browser in a test
  (`BrowserPool.browser(browser_name: :webkit)`) is pooled, gets the defaults and is recorded;
  `on_start` sets up each new driver.
- `trace`, `screenshot` and `video` per `describe` and test.
- Route handlers, listeners and bindings run with their registrant's `$callers`, so the Ecto
  sandbox, Mox and `Req.Test` find the test ([Route handlers and listeners](../testing-with-exunit.md#route-handlers-and-listeners)).
- `Playwright.Test.info/0`'s `test_pid` and `deadline` (upstream's internal `_deadline()`), and
  `in_registered_scope?/0`, for libraries.
- A tuple and a bang form of every call and matcher; `Expect.to_pass/2` returns the passing
  attempt's value; `to_have_screenshot` and `to_match_aria_snapshot` with a `path:`, also outside
  a test; the errors' `log`.
- `Playwright.device/1` raises for an unknown name, naming the closest.
- The driver as a supervised process (`Playwright.Supervisor`, several at once), downloaded with
  its Node, no npm needed; `mix playwright.install --no-browsers`, `Playwright.Driver.version/0`.
- `Playwright.Test.GitHubFormatter` annotates a failed `setup_all`.

## Differs on purpose

- [What differs](../porting-playwright-test.md#what-differs) and
  [Not supported](../porting-playwright-test.md#not-supported) in Porting Playwright Test specs.
- [From playwright.dev to Elixir](api-conventions.md): names, results, options, events, errors.
- [Where it differs from JS](../concurrency.md#where-it-differs-from-js) in Concurrency.
- The deviations in `Playwright.Test`'s moduledoc, and docs/architecture.md's
  [Generated facade](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md#generated-facade)
  and [Test runner](https://github.com/ftes/playwright_ex/blob/main/docs/architecture.md#test-runner).
