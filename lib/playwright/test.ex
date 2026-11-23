defmodule Playwright.Test do
  @moduledoc """
  Playwright Test's per-test machinery on ExUnit: each test's result, its artifacts (traces,
  screenshots, videos, `error-context.md`), Playwright Test's context defaults, soft errors,
  snapshot and output paths, and steps. The browser comes from `Playwright.Test.BrowserPool`,
  contexts and pages from the plain API; `Playwright.Case` puts them together.

      # config/test.exs
      config :playwright, :test,
        trace: :on_first_retry,       # traced under `mix test --failed`
        screenshot: :only_on_failure,
        base_url: "http://localhost:4000"

      defmodule MyApp.CheckoutTest do
        use ExUnit.Case, async: true
        use Playwright.Test

        alias Playwright.{Browser, BrowserContext, Page}

        setup_all do
          %{browser: Playwright.Test.BrowserPool.browser()}
        end

        setup %{browser: browser} do
          %{page: BrowserContext.new_page!(Browser.new_context!(browser))}
        end

        test "pays", %{page: page} do
          ...
        end
      end

  The runner is native, not a port of Playwright Test: it follows the runners of the official
  non-JS clients (pytest-playwright, Playwright.NUnit, Java's `@UsePlaywright`) on ExUnit, with
  Playwright Test's names and defaults where they exist (`packages/playwright/src/index.ts`).
  What the ported matchers and traces need of Playwright Test's worker is ported: testInfo's
  snapshot paths and errors (`testInfo.ts`), `step/3` (`test.step`) and the `test.trace` of
  `trace.zip` (`testTracing.ts`).

  ## Registration

  `use Playwright.Test` comes after `use ExUnit.Case` (or in a case template's `using`). It
  imports a `test` macro, which hands the test to `ExUnit.Case.test/3` with the body's end
  marked, so the test's `on_exit` learns whether it passed, and `assert/1,2` and `refute/1,2`,
  which are also steps (see "Assertions"). And it adds a `setup` that
  registers each test: its recording modes, its output dir and an `on_exit` (the first, so it
  runs last) that keeps or drops the artifacts by the result, then releases the test's
  `BrowserPool.browser/1` drivers. Tests of other macros (doctests, a `property`) count as
  failed for their artifacts, and a failure only in an `on_exit` callback counts as passed.

  In a case template, `use Playwright.Test` may also be the first line of the template's
  body: a template's own `setup` callbacks run before those its `using` brings in, so the test
  is registered before them, and their contexts are recorded too. That `use` takes no options
  (they go in `using`); a module's later `use`s (a template's `using` and the module's own) only
  add their options (see "Artifacts"). With the `use` only in the template's body, the
  `setup_all` timeout (see "Timeouts") covers only the template's `setup_all` callbacks. A
  context that a test process creates, or a `BrowserPool.browser/1` call it makes, before its
  registration (a template's `setup` with no `use` in the body) makes the registration raise,
  with that fix. It registers the module's `setup_all` process too, as upstream runs its
  `beforeAll` hooks with its `all-hooks-included` fixtures: see "Contexts of `setup_all`". A
  `setup_all` runs in that process, not a test's, so one that creates a context or calls
  `BrowserPool.browser/1` before the registration (a template's own `setup_all`, or one above
  the module's `use`) makes the module's `setup_all` raise, with the fix, and fails all its tests. A context created outside
  both (in an `on_exit` callback, in a module without `use Playwright.Test`, in a process with
  neither in its `$callers`, on a driver you started yourself) gets no defaults and no recording.

  The rest is called qualified, as upstream's `test.info()` and `test.step()`: `info/0`
  (`info/1` in `on_exit`, with the test's result), `output_path/1`, `attach/2`, `snapshot_path/2`, `step/2,3` and `step_skip/2,3`. They work in the test's
  process and in processes with it in `$callers` (a `Task`, and the client's callback
  processes, see "Route handlers and listeners" in the Testing with ExUnit guide); outside a
  test they raise. `info/0`, `step/2,3` and `step_skip/2,3` also work in the module's
  `setup_all`: `info/0` with the module's fields (see "Contexts of `setup_all`"), the steps
  unrecorded (see "Steps").

  An error a listener or route handler of the test raises fails the test and stops it at once,
  as upstream's worker does (`unhandledError`): the test's process exits with the error, and
  later such errors are dropped. A test that traps exits isn't stopped: ExUnit may report it
  passed, while the error is in `error-context.md` and `Playwright.Test.info/1`. A test
  defined with `ExUnit.Case.test` isn't a Playwright test: its listener errors are only logged.
  Two deviations: the stopped test's failure screenshots are taken at teardown, as its contexts
  close, after its `on_exit` callbacks may have run, where upstream takes them first
  (`_didFinishTestFunction`); and once the body ended (in `on_exit`), such an error is logged,
  where upstream still fails the test during its `afterEach` hooks and teardown.

  ## Artifacts

  Every context the test creates on a `BrowserPool` browser, in the test or a process with it
  in `$callers`, is recorded. The recording starts with the test's first context (or at its
  registration when it traces, for its steps); a test without contexts records nothing.
  Contexts left open are closed after the test, last in its `on_exit`, and request contexts of
  `Playwright.APIRequest.new_context/2` left are disposed; a context closed earlier keeps its
  artifacts. Each test writes to its own dir under `output_dir`, named as upstream's
  `testInfo.outputDir` (`checkout-pays-1a2b3` for the test "pays" in `test/checkout_test.exs`,
  the suffix a hash of the module and its `parameterize:` parameters):

    * `trace.zip` - one trace of all its contexts, their `request`s and its request contexts
      (`Playwright.APIRequest.new_context/2`), recorded with screenshots, snapshots and
      sources unless the trace's options say otherwise. A failed test that keeps one prints
      `mix playwright.cli show-trace <path>` after the run, below ExUnit's summary.
    * `test-finished-N.png`, or `test-failed-N.png` for a failed test - a screenshot of every
      page open at the end of the test's body (before its `on_exit` callbacks), then of those
      open when their context closes (`timeout: 5000, caret: :initial`, as upstream). A test
      that a listener's or route handler's error stopped (above) has no end of its body: its
      pages' screenshots are taken as its contexts close, after its `on_exit` callbacks
      (upstream takes them before the `afterEach` hooks).
    * `video.webm`, `video-1.webm`, ... - every page's video. A context created with its own
      `record_video` keeps it, and its video is copied here too.
    * `error-context.md` - a failed test's errors, source and an aria snapshot (`mode: :ai`) of
      the first page of the first context closed after the failure (upstream's `didFinishTest`
      and `buildErrorContext`), whatever the modes.

  The modes are config, the project's over it (`parameters/1`), the module's `use` options over
  those, and `use/1` in tags over those (a test's `@tag` over its `@describetag` over the
  module's `@moduletag`): `trace` and `video` `:off`
  (default), `:on`, `:retain_on_failure` or a retry mode, `screenshot` `:off`, `:on`,
  `:only_on_failure` or `:on_first_failure` (upstream's deprecated `:retry_with_trace` and
  `:retry_with_video` are `:on_first_retry`; another value records nothing, as upstream's). Each
  is also the `:mode` of a keyword list (or map) of options, as upstream's object forms, `:off`
  without one: `trace:
  [mode: :on, snapshots: false]`, `screenshot: [mode: :on, full_page: true]`, `video: [mode:
  :on, size: %{width: 640, height: 480}]`. The trace's `:snapshots` (a boolean or `%{dom: _, aria: _, screen: _}`),
  `:screenshots` and `:sources` are `Playwright.Tracing.start/2`'s, `true` by default, as is
  `:attachments` (those of `attach/2` in `trace.zip`); the
  screenshot's `:full_page` and `:omit_background` are `Playwright.Page.screenshot/2`'s; the
  video's `:size` and `:fps` are `record_video`'s, and its `:show` is upstream's map:
  `%{actions: _}` is `record_video`'s `showActions`, `%{test: %{level: _, position: _, fontSize:
  _}}` overlays the test's title and its steps' (`level` `"file"`, `"title"` or `"step"`) on
  each page of its contexts. With it, don't call `step/2,3` in a route handler that holds a
  page's navigation (a document request): the step's overlay waits for that navigation, so the
  test hangs until its timeout, as upstream's does.

  `use Playwright.Test, trace: :on` is upstream's file-level `test.use({ trace: 'on' })` (the
  modes are worker-scoped options there), with the values the config takes; an unknown option (or a
  context option the facade rejects) raises at compile time. A module's `use`s merge per key, the later winning
  (see "Context defaults").
  A template's own `use Playwright.Test, ...` lines go before the forwarded options, which win per
  option, as a test file's `test.use` beats a project's device.
  ExUnit.Case's keys (`:async`, ...) are ignored, so a template forwards its options from `using
  opts` as is: `use Playwright.Test, unquote(opts)`, as `Playwright.Case` does. A template
  with options of its own pops them first (`{sandbox, opts} = Keyword.pop(opts, :sandbox)`),
  as they raise here. Tags named `trace`, `screenshot` or `video` set no mode: only `use/1`'s
  keys are read.

  The `*_on_failure` modes record every test and keep the files of failed ones, as upstream
  (files you write to `output_path/1` stay). A failing artifact step is logged; the test's
  result stands.

  The retry modes go by the test's `retry` (see below), as upstream's: `:on_first_retry`
  records retry 1, `:on_all_retries` every retry, `:retain_on_first_failure` records the first
  run and keeps a failure's, `:retain_on_failure_and_retries` records every run and keeps a
  failure's and every retry's; the screenshot's `:on_first_failure` is `:only_on_failure` of
  the first run.

  A test's dir is deleted before it runs, as upstream's, so no file of an earlier run is left
  in it. ExUnit has no retries in a run: a test under `mix test --failed` is upstream's retry
  (`info/0`'s `retry`, 1), and writes to `<dir>-retry1`, next to the dir of its first run. So
  with `trace: :on_first_retry`,
  `mix test || { [ $? -eq 2 ] && mix test --failed; }` traces the failures' rerun and keeps the
  first run's files (exit status 2 means tests failed; anything else isn't retried). A run
  without `--failed` deletes the test's `-retry1` dir too, where
  upstream deletes all of `output_dir` at the start of a run: here the dirs of tests that didn't
  run stay. Config `preserve_output` is upstream's `preserveOutput`: `:always` (default) keeps
  the files at the end of each test, `:failures_only` only a failed test's, `:never` none.

  ## Context defaults

  Every context and request context a test (or its module's `setup_all`) creates on a
  `BrowserPool` browser (`Playwright.Browser.new_context/2`,
  `Playwright.BrowserType.launch_persistent_context/3`, `Playwright.APIRequest.new_context/2`) gets Playwright Test's context defaults (`locale:
  "en-US"`, a 1280x720 viewport, `color_scheme: :light`, ...), then the config's context options
  over them, then the project's, the module's, the describe's and the test's (below), for each
  option the call doesn't give, as upstream's `_combinedContextOptions`. `viewport: :null` is
  none. An option replaces the one under it as a whole (`extra_http_headers` too, as upstream's
  shallow spread).

  The context options are options of their own, upstream's option fixtures, with the names
  `Playwright.Browser.new_context/2` takes them by: `accept_downloads`, `base_url`,
  `bypass_csp`, `client_certificates`, `color_scheme`, `contrast`, `device_scale_factor`,
  `extra_http_headers`, `forced_colors`, `geolocation`, `has_touch`, `http_credentials`,
  `ignore_https_errors`, `is_mobile`, `java_script_enabled`, `locale`, `offline`, `permissions`,
  `proxy`, `reduced_motion`, `screen`, `service_workers`, `storage_state`, `timezone_id`,
  `user_agent` and `viewport`. `use Playwright.Test, locale: "de-DE"` (or `use Playwright.Case,
  ...`) is upstream's file-level `test.use({ locale: 'de-DE' })`: the module's options,
  evaluated and validated at compile time (the values as `new_context/2` checks them). A
  function raises there: upstream's function-valued options, its option fixtures' functions,
  aren't ported. A module's `use`s apply in order, each over those before it per option.

  A device is a keyword list of these options and its `default_browser_type` (see "Browser"),
  spread into the others as upstream's `...devices['iPhone 13']`: `use Playwright.Test,
  Playwright.device("iPhone 13")` after `use Playwright.Case, async: true`, or in one `use`,
  `use Playwright.Case, [async: true] ++ Playwright.device("iPhone 13")`. A later key wins, as in
  JS's spread, so upstream's `{ ...devices['iPhone 13'], viewport }` is
  `Playwright.device("iPhone 13") ++ [viewport: %{width: 800, height: 600}]`.
  The options may be a map too.

  `context_options` is upstream's `contextOptions`: `new_context/2`'s options, for those that
  are no option of their own (`record_har`, `strict_selectors`). It is one option, as upstream's
  one fixture: the highest level that sets it replaces the others' as a whole. And it is under
  every option of its own, whatever level sets either, as upstream's fixture of an option reads
  `contextOptions` only when no level sets the option. `context_options: nil` falls back as any
  option's `nil` (below), so does a misspelled `Playwright.devices()["typo"]`, silently: use
  `Playwright.device/1`, which raises for an unknown name.

  Below the module, `use/1` gives the options to ExUnit as a tag, for a describe block
  (`@describetag Test.use(locale: "de-DE")`, upstream's `test.use` in a `test.describe`) or a
  test (`@tag`); `@moduletag` works too, the worker options included, as upstream's top-level
  `test.use`. A project's
  are `parameters/1` in the module's `parameterize:` (upstream's `project.use`).

  The layers, each over the one before per option: Playwright Test's defaults, the config's,
  the project's, the module's (`use`, then `@moduletag`), the describe's, the test's, then the
  call's own. Any option a layer (the config, a project, the module's `use`, a tag) gives as
  `nil` is unset there, as upstream's `undefined` option override, so the layer under it gives
  it, in the end the default: the config's `nil` falls back to the default, the project's to
  the config's, and a module's or a tag's to the project's or the config's, past the module's
  own `use`s and tags, as upstream's `test.use` of `undefined` goes back to the config's.
  `context_options: nil` is the bag of the layer under. A call's own options are no layer: a
  context option's `nil` there is passed as given, over the layers, as upstream's
  `newContext({ locale: undefined })` spreads it over the defaults, so
  `Browser.new_context!(browser, locale: nil)` gets the client's default, not the layers'.
  `BrowserPool.browser(connect_options: nil)` launches; its `browser_name` and
  `launch_options` take no `nil`. The config's, the project's and the
  module's reach every context the module creates: a test's, those of its `Task`s, and those of
  `setup_all`, as upstream's `beforeAll` gets the `use` options. A describe's and a test's reach
  the test's contexts only: ExUnit runs `setup_all` without them. The project's options are read
  from the parameters ExUnit runs the module with, the others from the test's tags.

  ## Browser

  `BrowserPool.browser/1` without a `browser_name`, as `Playwright.Case` calls it, launches the
  module's browser, upstream's `browserName`: the `browser_name` of the module's `use`
  (`use Playwright.Case, browser_name: :webkit`), else its project's (`parameters/1`), else the
  config's if it sets one. Else their `default_browser_type`, in the same order, upstream's
  worker option `defaultBrowserType`, which a device has (`Playwright.device("iPhone 13")` is
  WebKit's) and upstream's `browserName` defaults to; else `:chromium`. The module's
  `launch_options` (its `use`'s, else its project's, else the config's, each as a whole) and
  `connect_options` are that call's defaults too, upstream's `launchOptions` and
  `connectOptions`: a project with `launch_options: [channel: "chrome"]` gets a worker of its
  own. So are its `headless` and `channel`, upstream's options of their own, set over the launch
  options' when given (`headless: false` launches headed whatever `launch_options` say); unset,
  they are the launch options' (`headless` `true` when those have none). These six are the
  worker's, as upstream's: the module's (its `use`, then all of its
  `@moduletag Test.use(...)`s merged, the later per option, upstream's top-level `test.use`, for
  every test of the module, also those above such a line) or its project's. Its other options
  don't reach a test above the line, as ExUnit gives a test the `@moduletag`s set before it:
  under `@moduletag Test.use(Playwright.device("iPhone 13"))`, such a test gets the device's
  `default_browser_type` but not its viewport or user agent, so put the line above the tests.
  In a `@describetag` or a `@tag` of a test of the `test` macro they raise when the module compiles, as upstream's `test.use` in a describe
  when the file loads, a device's `default_browser_type` too; other tests (a doctest, a bare
  `ExUnit.Case.test`) get the module's worker regardless. For a browser or a device per run,
  make each a project (`parameters/1`) in the module's `parameterize:`.

  Where each option can be set:

  | Option | Config | Project (`parameters/1`) | Module (`use`, then its `@moduletag use/1`s, merged) | Describe, test (`@describetag`, `@tag use/1`) |
  |---|---|---|---|---|
  | the context options, `context_options`, `action_timeout`, `navigation_timeout` | yes | yes | yes | yes |
  | `trace`, `screenshot`, `video` | yes | yes | yes | yes (an addition: upstream's are the worker's; they work fully per test, as the recorder records per test and touches no browser) |
  | `browser_name`, `headless`, `channel`, `launch_options`, `connect_options` | yes | yes | yes | raises when the module compiles a `test` under it, as Playwright Test's `test.use` in a describe |
  | `default_browser_type` (a device's) | picks the browser | picks the browser | picks the browser | raises, as the browser keys |
  | `test_id_attribute` | yes | no | no | no (a deviation: upstream's is an option of every level, global to a worker, which runs one test at a time; here it is global to the VM, which the tests running at once share) |
  | `output_dir`, `preserve_output`, `workers`, `snapshot_dir`, `snapshot_path_template`, `driver`, `on_start` | yes | no | no | no |

  ## Contexts of `setup_all`

  `use Playwright.Test` adds a `setup_all` (where the `use` is, so before the module's own) that
  registers the module's `setup_all` process: every context and request context it creates, or
  a process with it in `$callers` creates, gets the context defaults, the config's
  context options (so `base_url`), the project's and the module's (its `use` and `@moduletag`,
  see "Context defaults"), merged as a test's, and the timeouts of those same layers (see
  "Timeouts"): a context's `action_timeout` and `navigation_timeout`, a request context's
  `timeout:` the `action_timeout` (`0`, no limit, for `:infinity`) and no navigation timeout. Not
  the video, as upstream's comes with the `context` fixture.

  `info/0` there returns the module's `file`, `timeout` and `use` (`Playwright.Case` reads the
  `browser_name` from it): see `info/0`, also for reading the config outside these scopes.

  Only processes with `$callers` count: a `Task`, the client's callback processes (route
  handlers, listeners, exposed bindings registered in `setup_all` carry its `$callers`, see
  "Route handlers and listeners" in the Testing with ExUnit guide), or a process that sets them
  itself (`Process.put(:"$callers", callers)`). A `spawn`, a `GenServer` or `Agent` start, and
  `start_supervised` don't set them, so their contexts get no defaults. Deviation: a long-lived
  process or handler of `setup_all`'s with them gets the module's defaults for every context it
  creates later, during a test too, unrecorded. Upstream's `runBeforeCreateBrowserContext`
  resolves the current test, so such a context gets that test's options and is recorded in it.

  Not ported yet: a `setup_all` context isn't recorded per test (its actions aren't in a test's
  trace, and it gets no screenshots or `error-context.md`), where upstream's `ArtifactsRecorder`
  records every open context per test, `beforeAll` ones included: create the context per test,
  as `Playwright.Case` does. And after a failed test, `setup_all` state (its pages too) carries
  on, where upstream starts a fresh worker: bound calls on shared pages with `action_timeout`.

  ## Timeouts

  As in Playwright Test, a test's contexts have no action or navigation timeout by default: the
  test's timeout bounds them. `action_timeout` and `navigation_timeout` (the config's, or an
  option of any level over it; upstream's
  `actionTimeout`, `navigationTimeout`; milliseconds, `:infinity` by default) set each context's
  `Playwright.BrowserContext.set_default_timeout/2` and `set_default_navigation_timeout/2`
  (`navigation_timeout` alone governs navigations), and the action timeout is a request
  context's `timeout`, when the call gives none. `0` is no limit too, not an immediate failure,
  as `timeout: 0` is everywhere in Playwright (see [API conventions](api-conventions.md)):
  write `:infinity` to say so.

  Shortly before ExUnit's timeout (1 s before, at most 5% of the timeout), the test's open
  contexts are closed with upstream's reason, "Test timeout of 60000ms exceeded.": a call that
  hangs until then fails with that message and its call log, after the close kept the artifacts.
  A `Playwright.Browser.new_context/2`, `Playwright.Browser.new_page/2` or
  `Playwright.BrowserType.launch_persistent_context/3` after that closes its context at the end
  of its creation and fails with that message
  (`connect_over_cdp`'s default context is left to the external browser).
  A test stuck elsewhere (`Process.sleep/1`, a `receive`) still fails with ExUnit's
  `ExUnit.TimeoutError`. So can a hung call under heavy load, when the close doesn't finish
  before ExUnit's kill: the console then has no call log, but the trace keeps the hung call with
  its log, and `error-context.md` says the test process was killed.
  The timeout is ExUnit's: the `@tag timeout:` (`:infinity` for none) or `mix test --timeout`;
  `mix test --trace` has none. As ExUnit's (and upstream's, which counts `beforeEach` hooks), the
  timeout counts the test's `setup` callbacks: the clock starts at the module's first one, also
  one defined before `use Playwright.Test` or in its case template.
  What ExUnit does before them (`@tag :tmp_dir`'s cleanup, `capture_log`) is not counted, and
  comes out of the margin.

  A module's `setup_all` callbacks get the same timeout, the module's (`@moduletag timeout:`, else
  ExUnit's `timeout`: `ExUnit.start(timeout:)` or `mix test --timeout`), as upstream's `beforeAll`
  hook gets the test timeout: past it, the `setup_all` fails with upstream's message with
  `beforeAll` renamed, `"setup_all" hook timeout of 60000ms exceeded.`, and the stack it was at.
  ExUnit has no timeout there, so the runner exits the `setup_all` process, which fails the
  module as a crash does; its `on_exit` callbacks still run. The failure is ExUnit's for an exit
  (`** (EXIT from #PID<...>)`), with the stack unpruned, and a hung call fails without its call
  log: unlike a test's, its contexts aren't closed with a reason before the exit. Its pooled
  browsers are reset at the module's end instead, as a failed test's, which closes its contexts:
  a failed `setup_all`'s are, as upstream stops a worker whose job failed. A `setup_all` process
  that traps exits is killed 1 s after the timeout instead: it fails with `:killed`, without the
  message. One timeout counts all of the module's `setup_all` callbacks, where upstream counts
  each hook on its own. `BrowserPool.browser/1` (the wait for a worker, its start) is not counted,
  as upstream's queue has no timeout and its worker fixtures have a timeout of their own: there,
  nothing bounds them. Its contexts get the `action_timeout` and
  `navigation_timeout` of the config, the project and the module (`:infinity` by default, not the client's 30 s), as upstream's `beforeAll`
  contexts get `actionTimeout || 0`.

  ## Snapshots

  In a test, `Playwright.Expect.to_have_screenshot/2` and
  `Playwright.Expect.to_match_aria_snapshot/3` take upstream's `name:` and resolve it as
  `testInfo` does, by upstream's default templates:

    * screenshots: `{snapshotDir}/{testFileDir}/{testFileName}-snapshots/{arg}{-snapshotSuffix}{ext}`,
      `test/checkout_test.exs-snapshots/home-darwin.png` for `name: "home.png"` in
      `test/checkout_test.exs`.
    * aria snapshots: `{snapshotDir}/{testFileDir}/{testFileName}-snapshots/{arg}{ext}`.

  Without a name, a snapshot is named after the test and its count in the test:
  `pays-1-<platform>.png` for a screenshot, `pays-1.aria.yml` for an aria snapshot.
  A name is sanitized for the file system, a list of path segments is not. `snapshot_dir` is
  `test/` by default; `snapshot_path_template` (or the matcher's `path_template` in the config's
  `expect`, `expect: [to_have_screenshot: [path_template: ...]]`) takes upstream's tokens: `{testDir}`, `{snapshotDir}`,
  `{testFileDir}`, `{testFileName}`, `{testFileBaseName}`, `{testFilePath}`, `{testName}`,
  `{arg}`, `{ext}`, `{platform}` and `{snapshotSuffix}` (the platform, as upstream's);
  `{projectName}` is the `name` of the module's project (`parameters/1`), empty without one. `snapshot_path/2`
  returns a name's path. A failed comparison writes its `-actual`, `-expected`, `-previous` and
  `-diff` images to the test's output dir.

  A snapshot the matcher writes (a missing one, under the default `update_snapshots`) fails the
  test at the end of its body, as upstream's soft error: the rest of the body runs, and ExUnit
  reports all of the test's errors, also when another failure follows. `path:` in place of
  `name:` is the snapshot file itself, also outside a test, where a written snapshot is printed.

  ## Steps

  `step/3` is upstream's `test.step`: `Playwright.Test.step "log in" do ... end`, or
  `step(title, fun, options)` for wrappers, with upstream's `box`, `location`, `params` and
  `subtitle` (`step_skip/3` is `test.step.skip`). Each matcher call in a test is a step too
  (`category: 'expect'`), and a soft one's failure (`Playwright.Expect.soft/1`, upstream's
  `expect.soft`) fails the test at the end of its body, as a written snapshot does. So is each
  driver call (`pw:api`, titled as upstream's: `Click getByRole('button')`), in the step or
  `Playwright.Tracing.group/3` it runs in; a matcher's driver call is its step. The trace's
  `test.trace` entry (upstream's `TestTracing`) has the steps, nested by the step they run in,
  and the test's errors, so `trace: :on` gives a `trace.zip` also for a test without contexts.
  `attach/2` adds a `test.attach` step with the attachment (the trace's `attachments: false`
  leaves the attachments out). Not ported: the test's stdout and stderr in the trace, hooks and
  fixtures as steps, the step's `TestStepInfo` (the body takes no argument, so no
  `step.attach`) and its `timeout` (the test's timeout bounds a step).

  A step also works in the module's `setup_all` (and processes with it in `$callers`), as
  upstream's in a `beforeAll` hook: it returns its body's value, nests, and raises its error on,
  a boxed step's where its helper is called. Deviation: it is recorded nowhere (no trace, no
  video overlay), also in a long-lived process or handler of `setup_all`'s during a test, where
  upstream records a `beforeAll` step in the first test (its trace's "Before Hooks") and a
  handler's in the current test: ExUnit runs `setup_all` before any test, and hooks aren't
  steps here.

  ## Assertions

  `use Playwright.Test` imports `Playwright.Test.Assertions`' `assert/1,2` and `refute/1,2` in
  place of `ExUnit.Assertions`' (it imports that module again without them). Each is ExUnit's, also a
  step of the running test, as upstream's `expect(value).toBe(...)` is: `category: 'expect'`,
  titled `Expect "assert"` or `Expect "refute"`, with the expression as its subtitle and its
  `expression` param, located at the call. Its `expected` param, as upstream's
  `toEqual(expected)`'s, is the right side ExUnit's expansion binds (`left == right` and the other
  operators, `pattern = right`, `match?(pattern, right)`; a failed one's from its error), when it
  is JS-truthy (`if (args[0])`: not `nil`, `:null`, `false`, `0`, `0.0` or `""`), previewed as upstream's
  `generatePreview` but cut to 100 list elements and 1000 characters (`…`), as upstream's isn't
  (Elixir only: bound trace size); a truthy `assert x` has none. A message (`assert x, "msg"`)
  is the title, as upstream's `expect(value, message)`.

  A passed one expands to ExUnit's `assert` as it is, then records its step, so it binds as
  ExUnit's (`assert {:ok, user} = create()`, `assert (n = count()) > 0`), and its driver calls
  come before it, as upstream's. A failed one raises ExUnit's error, with its message and
  stacktrace; only a function that ends in an assertion keeps its frame in the stacktrace, as
  the assertion is no longer its tail call (as JS keeps every frame). A failed `assert/1` or
  `refute/1` is recorded once, with that error, where it ends: in a `Playwright.Expect.to_pass/2`
  attempt, else at the end of the test's body, as a step of the test's (not of the `step/3` it
  failed in, which fails with the same error). `assert/2` and `refute/2` are functions in
  ExUnit, so only their call is wrapped in a `try`, which records the failure there, in its
  step, also when the test rescues it.
  Outside a test, and in the module's `setup_all` (as a step there), nothing is recorded. The
  other assertions (`assert_receive`, `assert_raise`, ...) are ExUnit's, no steps.

  They are on by default. `use Playwright.Test, assert_steps: false` keeps ExUnit's own
  `assert` and `refute` (its plain `import ExUnit.Assertions`) and records none in its tests,
  passed or failed, a helper module's either; `config :playwright, :test, assert_steps: false` makes that the default,
  which a module's `assert_steps: true` overrides. As it decides the import, it is read when the
  module compiles: set it in `config/config.exs` or `config/test.exs`, not `config/runtime.exs`
  (Mix recompiles the modules when it changes). The option takes a literal boolean.

  Limits:

    * A passed assertion is recorded only where the import is: a helper module opts in with
      `import Playwright.Test.Assertions`, and, if it imports `ExUnit.Assertions` too,
      `import ExUnit.Assertions, except: [assert: 1, assert: 2, refute: 1, refute: 2]`. A library
      with its own `assert/2` excludes the arities it defines (`except: [assert: 2]`); its own
      `refute/2` also takes the `refute(value, expr: ...)` that ExUnit's `refute match?` calls
      (see `Playwright.Test.Assertions`). A failed `assert/1` or `refute/1` is recorded wherever it was
      written.
    * A test module that imports `ExUnit.Assertions` again after `use Playwright.Test` fails to
      compile, with an ambiguous call of `assert`: drop that import, or add the same `except:`.
    * A case template passes the import on with `use Playwright.Test` in its `using`; the one in
      its body (see "Registration") doesn't.
    * A failed `assert/1` or `refute/1` is a step of the test's, not nested in the `step/3` it
      failed in. One that the test rescues itself (a retry loop without steps) leaves no step,
      and so does one in the test's body under `mix test --breakpoints`, which runs the body
      without the `test` macro's `catch`. One rescued and raised again with `raise error` (not
      `reraise`) is located at that `raise`.
    * A failed `assert/1` or `refute/1` in a process of its own (a `Task`, a listener, a route
      handler) or in a `setup` callback leaves no step: the test body's catch doesn't see it.
    * Each attempt of `Playwright.Expect.poll/3` is its assertion's own steps, under the poll's
      step (as upstream's attempts are its matcher's); a poll with a message has the matcher's,
      titled by it, as upstream's. An attempt without one of these `assert`s (`assert_receive`,
      a raise of its own) leaves no step when it passes, the matcher's when it fails.
    * A failed assertion's expression shows a capture's argument as ExUnit's error has it
      (`_& == 2` for `&assert(&1 == 2)`); a passed one's is `&1 == 2`. On Elixir 1.18 both show
      the argument as `capture` (`capture == 2`).

  ## Config

      config :playwright, :test,
        browser_name: :chromium,      # BrowserPool: :chromium | :firefox | :webkit, or "chromium", ...
        headless: nil,                # BrowserPool: over launch_options' (nil: launch_options' headless, else true)
        channel: nil,                 # BrowserPool: over launch_options' (nil: launch_options' channel)
        launch_options: [],           # BrowserPool: Playwright.BrowserType.launch/2
        connect_options: nil,         # BrowserPool: [ws_endpoint: _, ...] to connect instead of launching
        driver: [],                   # BrowserPool: [env: _], Playwright.Supervisor's (the driver is config :playwright, :driver's)
        on_start: nil,                # BrowserPool
        workers: max(div(System.schedulers_online(), 2), 1),
        context_options: [],          # Playwright.Browser.new_context/2's options, as upstream's contextOptions
        # base_url: "http://localhost:4000", locale: "de-DE", ...: a context option, unset by default
        default_browser_type: nil,    # a device's: the browser, without a browser_name
        action_timeout: :infinity,    # ms, each context's default (and navigation_timeout's); :infinity or 0: none
        navigation_timeout: :infinity,
        trace: :off,                  # :off | :on | :retain_on_failure | :on_first_retry | ..., or [mode: _, ...]
        screenshot: :off,             # :off | :on | :only_on_failure | :on_first_failure, or [mode: _, ...]
        video: :off,                  # as trace, or [mode: _, size: _]
        output_dir: "test-results",
        preserve_output: :always,     # :always | :failures_only | :never, or "failures-only", ..., see Artifacts
        snapshot_dir: nil,            # upstream's testDir: test/
        snapshot_path_template: nil,  # upstream's defaults, see Snapshots
        test_id_attribute: "data-testid",
        report_slow_tests: [max: 5, threshold: 300_000], # Playwright.Test.GitHubFormatter's, ms; false: none
        assert_steps: true,           # assert/refute as steps, at compile time (see Assertions)
        expect: [],                   # the matchers': [timeout: 5000, to_have_screenshot: [...], ...], see Playwright.Expect
        update_snapshots: :default,   # :all | :changed | :missing | :none | :default, see Snapshots
        ignore_snapshots: false       # skip the snapshot matchers

  `expect`, `update_snapshots` and `ignore_snapshots` are the matchers' (see the configuration
  in `Playwright.Expect`), which read them also without `Playwright.Test`.

  Each context option (`base_url`, `locale`, `viewport`, `storage_state`, ...) is a config key of
  its own, over the `context_options` bag, as under every other level, and in `config/0` only
  when set. A test reads the resolved values with `info().use`.

  The artifact modes are `off` by default and `output_dir` is `test-results`, as upstream's.
  `workers` is half the schedulers, as upstream's default `workers` is half the cores (`'50%'`).
  `test_id_attribute` is upstream's `testIdAttribute`, set on each pooled driver: the client's
  value is global to the VM, so set it here, not per module. `config/0` returns the config
  resolved. An unknown key raises at application start (and when the runner reads a config
  changed since), and so does a bad value of the keys upstream checks: `preserve_output`,
  `output_dir`, `browser_name`, `report_slow_tests`, `update_snapshots`, `ignore_snapshots`,
  `expect`'s `to_have_screenshot` `type` and the context options (as
  `Browser.new_context/2` checks them), and of `workers` (a positive integer: upstream's also
  takes `"50%"` or a numeric string, which aren't supported), `on_start` and Elixir's
  `assert_steps` (a boolean). `browser_name` and `preserve_output` take an atom (`:webkit`,
  `:failures_only`) or upstream's string (`"webkit"`, `"failures-only"`): an unknown atom raises
  as any bad value, an unknown string with upstream's error. Other values pass as given, as
  upstream's: an unknown artifact mode records nothing. An unknown key in `expect`, or a bad
  `expect`, `update_snapshots` or `ignore_snapshots` set after start, raises when a matcher or
  `config/0` next reads it.
  """

  alias Playwright.Runtime.Zones
  alias Playwright.Test.ErrorContext
  alias Playwright.Test.Options
  alias Playwright.Test.Pool
  alias Playwright.Test.Recorder
  alias Playwright.Test.Results
  alias Playwright.Test.TestInfo
  alias Playwright.Test.TestTracing

  require Logger

  # Set while `__passed__/0` raises the errors `TestInfo` recorded (and traced) already.
  @reraised {__MODULE__, :reraised}
  # When the test's first `setup` callback ran (`__started__/1`), in its process.
  @started {__MODULE__, :started}
  @assertion_titles Map.new(
                      [:assert, :refute],
                      &{&1, "Expect #{Playwright.Isomorphic.StringUtils.escape_with_quotes(to_string(&1), "\"")}"}
                    )
  # `info/0`'s fields of the registration.
  @info_keys [:test_pid, :file, :test_name, :output_dir, :retry]

  defmacro __using__(opts) do
    macros = __CALLER__.macros

    cond do
      # A test module, also when `use Playwright.Test` came before (from a template's `using`):
      # its import replaced ExUnit.Case's `test`.
      {:test, 3} in Keyword.get(macros, ExUnit.Case, []) or {:test, 3} in Keyword.get(macros, __MODULE__, []) ->
        {assert_steps, opts} = assert_steps!(opts, __CALLER__)
        # At expansion, for a later `use` in the module (`assert_steps!/2`) and `__before_compile__/1`.
        Module.put_attribute(__CALLER__.module, :playwright_assert_steps, assert_steps)

        imports =
          if assert_steps do
            quote do
              # Replaces `use ExUnit.Case`'s import: `assert` and `refute` are `Playwright.Test.Assertions`'.
              import ExUnit.Assertions, except: [assert: 1, assert: 2, refute: 1, refute: 2]
              import Playwright.Test.Assertions
              import Playwright.Test, only: [test: 1, test: 2, test: 3]
            end
          else
            quote do
              # Also after an earlier `use`'s import of them (a case template's `using`).
              import Playwright.Test.Assertions, only: []
              import ExUnit.Assertions
              import Playwright.Test, only: [test: 1, test: 2, test: 3]
            end
          end

        quote do
          import ExUnit.Case, only: [describe: 2]
          unquote(imports)
          require Playwright.Test

          if Playwright.Test.__use__(__MODULE__, unquote(opts)) do
            Playwright.Test.__clock__(__MODULE__)
            setup_all({Playwright.Test, :__setup_all__})
            setup({Playwright.Test, :__setup__})
          end
        end

      # The body of a case template: its `setup` callbacks run before those of its `using`.
      {:using, 1} in Keyword.get(macros, ExUnit.CaseTemplate, []) ->
        quote do
          Playwright.Test.__template_use__(unquote(opts), __ENV__)

          if Playwright.Test.__use__(__MODULE__, []) do
            Playwright.Test.__clock__(__MODULE__)
            setup_all({Playwright.Test, :__setup_all__})
            setup({Playwright.Test, :__setup__})
          end
        end

      true ->
        raise CompileError,
          file: __CALLER__.file,
          line: __CALLER__.line,
          description: "use Playwright.Test must come after use ExUnit.Case (or in a case template's body or using)"
    end
  end

  @doc false
  # A `use Playwright.Test` in a case template's body takes no options (but ExUnit.Case's, which
  # it ignores as the module's does): the test may be registered by another `setup` before the
  # body's, which would drop them. In `using` they merge with the module's `use`s at compile time.
  def __template_use__(opts, env) do
    case Options.without_ex_unit_keys(opts) do
      [] ->
        :ok

      opts ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "use Playwright.Test in a case template's body takes no options, got: #{inspect(opts)}; " <>
              "put them in the template's `using` block (`use Playwright.Test, #{inspect(opts)}`), " <>
              "where they merge with the module's own `use`s"
    end
  end

  @doc false
  # Validates the options of a `use Playwright.Test` and merges them over the module's earlier
  # ones (a template's `using` and the module itself may both bring it), the later `use` winning
  # per key, as `ExUnit.Case.__register__/2` merges `use ExUnit.Case`'s. `true` on the module's
  # first `use`, which sets it up.
  def __use__(module, opts) do
    options = Options.use_options(opts)

    case Module.get_attribute(module, :playwright_test) do
      nil ->
        Module.put_attribute(module, :playwright_test, options)
        Module.put_attribute(module, :before_compile, __MODULE__)
        true

      past ->
        Module.put_attribute(module, :playwright_test, Options.merge(past, options))
        false
    end
  end

  # Elixir only: whether `assert` and `refute` are steps (see "Assertions"), at compile time, as
  # it decides the import: the literal `assert_steps:` of `opts` (taken out of them), else an
  # earlier `use`'s in the module, else `config :playwright, :test`'s, read with `Application.compile_env/4`, so Mix recompiles the
  # module when it changes.
  defp assert_steps!(opts, caller) do
    {given, opts} = if Keyword.keyword?(opts), do: Keyword.pop(opts, :assert_steps), else: {nil, opts}

    cond do
      is_boolean(given) ->
        {given, opts}

      given != nil ->
        raise ArgumentError,
              "use Playwright.Test: invalid value #{Macro.to_string(given)} for assert_steps, expected a literal boolean"

      # An earlier `use`'s (a case template's `using`), as the other options merge.
      is_boolean(earlier = Module.get_attribute(caller.module, :playwright_assert_steps)) ->
        {earlier, opts}

      true ->
        # A `nil` key is unset: its default, as `config/0` reads it.
        configured = Application.compile_env(caller, :playwright, [:test, :assert_steps], nil)
        configured = if configured == nil, do: true, else: configured
        {Options.validate_key!(:assert_steps, configured, "config :playwright, :test"), opts}
    end
  end

  @doc false
  # The module's merged `use` options, for its registration (`__register__/1`): a function, so the
  # test's context stays the test author's. And the timeout of its `setup_all` callbacks
  # (`Playwright.Test.SetupAllTimeout`), around all of them: this hook runs after ExUnit's, which
  # compiled them into `__ex_unit__/2`.
  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :playwright_test)
    assert_steps = Module.get_attribute(env.module, :playwright_assert_steps, true)

    # Without ExUnit's `__ex_unit__/2` (its internals changed), no `setup_all` timeout: said at
    # compile time.
    setup_all_timeout =
      if Module.defines?(env.module, {:__ex_unit__, 2}) do
        quote do
          defoverridable __ex_unit__: 2

          @doc false
          def __ex_unit__(:setup_all, context),
            do: Playwright.Test.SetupAllTimeout.run(context, fn -> super(:setup_all, context) end)

          def __ex_unit__(kind, context), do: super(kind, context)
        end
      else
        IO.warn(
          "use Playwright.Test found no __ex_unit__/2 in #{inspect(env.module)}: ExUnit's internals " <>
            "changed, so its setup_all timeout is off",
          Macro.Env.stacktrace(env)
        )

        nil
      end

    quote do
      @doc false
      def __playwright_test__(:options), do: unquote(Macro.escape(options))
      def __playwright_test__(:file), do: unquote(env.file)
      def __playwright_test__(:assert_steps), do: unquote(assert_steps)

      unquote(setup_all_timeout)
    end
  end

  @doc """
  `ExUnit.Case.test/3`, with the end of the body marked: the test passed if its process then
  exits as ExUnit ends a test, and fails there with the errors its matchers recorded (see
  "Snapshots" in the moduledoc). A `catch` notes an error for `error-context.md` and re-raises it
  unchanged, so ExUnit reports the failure as without this macro (with the recorded errors
  before it, if any).
  """
  defmacro test(message, var \\ quote(do: _), contents) do
    block =
      case contents do
        [do: block] -> block
        # `rescue`, `catch`, `after`, `else`: what escapes them reaches our `catch`.
        contents -> quote(do: try(unquote(contents)))
      end

    passed = quote(do: Playwright.Test.__passed__())

    # Flat, so `mix test --breakpoints` (`IEx.Pry.annotate_quoted/3`) breaks before each
    # expression (not before the mark, which has no line).
    block =
      case block do
        {:__block__, meta, exprs} -> {:__block__, meta, exprs ++ [passed]}
        expr -> {:__block__, [], [expr, passed]}
      end

    failed =
      quote do
        kind, reason ->
          {kind, reason, stacktrace} = Playwright.Test.__failed__(kind, reason, __STACKTRACE__)
          :erlang.raise(kind, reason, stacktrace)
      end

    # ExUnit's breakpoints break the `catch` clauses (they are annotated as a block).
    contents =
      if Application.get_env(:ex_unit, :breakpoints, false),
        do: [do: block],
        else: [do: block, catch: failed]

    quote do
      Playwright.Test.__worker_tags__!(__MODULE__)
      @tag "playwright.test": :marked
      ExUnit.Case.test(unquote(message), unquote(var), unquote(contents))
    end
  end

  @doc "`ExUnit.Case.test/1`: a test that fails as not implemented."
  defmacro test(message) do
    quote do
      Playwright.Test.__worker_tags__!(__MODULE__)
      @tag "playwright.test": :marked
      ExUnit.Case.test(unquote(message))
    end
  end

  @doc false
  # The step of an `assert` or `refute` (`kind`) of `code` with `message`: passed, or failed
  # with `error` (`{kind, reason, stacktrace}`), with its `expected` (`Playwright.Test.Assertions`). The shape of
  # `Playwright.Matchers.Expect.call_matcher_as_step/6`'s: none outside a test, and none in the
  # module's `setup_all`, where `step/3` records nowhere, nor in a test of a module with
  # `assert_steps: false` (a helper's assertion there).
  def __assertion__(kind, code, message, error, expected) do
    with %{} = test_info <- current_test_info(),
         true <- Map.get(test_info, :assert_steps, true) do
      stack = if error, do: elem(error, 2), else: TestInfo.capture_raw_stack()
      add_assertion_step(test_info, kind, code, message, stack, error, expected)
    end

    :ok
  end

  # The running test: in a matcher's callback (a `to_pass` or `poll` attempt) the one the matcher
  # call found (`Playwright.Matchers.Expect.expect_config/1`'s), else looked up.
  defp current_test_info do
    case Zones.data(:expectTestInfo) do
      {test_info} -> test_info
      nil -> TestInfo.current()
    end
  end

  @doc false
  # Elixir only: the step of a failed `assert/1` or `refute/1`, which ExUnit's macro raises with
  # no `try` around it: recorded where the error ends, the catch of the test's body
  # (`__failed__/3`) or of a `to_pass` attempt (the `toPass` step's), so once, at that level (not
  # in the step it failed in, which fails with it). Its `ExUnit.AssertionError` has the expression,
  # its stacktrace the location, its `right` the `expected`; also when a helper module without
  # the import asserted. `assert/2`'s error has no expression: its own `try` recorded it.
  # `assert_receive` and the others aren't steps. Returns whether it is such an error.
  def __assertion_error__(test_info, error)

  def __assertion_error__(
        test_info,
        {:error, %ExUnit.AssertionError{expr: {kind, _, [expr]}} = reason, stacktrace} = error
      )
      when kind in [:assert, :refute] and is_map(test_info) do
    # None in a module with `assert_steps: false`.
    if Map.get(test_info, :assert_steps, true),
      do:
        add_assertion_step(
          test_info,
          kind,
          Playwright.Test.Assertions.__code_string__(expr),
          nil,
          stacktrace,
          error,
          expected(expr, reason)
        )

    true
  end

  def __assertion_error__(_test_info, _error), do: false

  # ExUnit's operators that fail for both sides being exactly equal (its `translate_assertion/3`).
  @equality_operators [:<, :>, :!==, :!=, :<=, :>=, :===, :==, :=~]

  # A failed assertion's `expected`: its error's `right`, or of a comparison ExUnit failed for
  # both sides being exactly equal (`assert a != b`, no `right`), its `left`; else none.
  defp expected(expr, %{left: left, right: right}) do
    no_value = ExUnit.AssertionError.no_value()

    cond do
      right != no_value -> right
      match?({operator, _, [_, _]} when operator in @equality_operators, expr) and left != no_value -> left
      true -> nil
    end
  end

  # `callMatcherAsStep`'s step: its title is the message, else `Expect "assert"` (its
  # `escapeWithQuotes` at compile time, which costs more at run time than the step).
  defp add_assertion_step(test_info, kind, code, message, stacktrace, error, expected) do
    title = if is_binary(message) and message != "", do: message, else: @assertion_titles[kind]
    params = %{expression: code}
    # `if (args[0]) params.expected = args[0]`, its preview bounded (`TestTracing.bounded_preview/1`).
    params =
      if Playwright.Client.ClientHelper.truthy(expected),
        do: Map.put(params, :expected, TestTracing.bounded_preview(expected)),
        else: params

    step =
      TestInfo._add_step(test_info, %{
        category: "expect",
        title: title,
        subtitle: code,
        stack: TestInfo.stack_frames(TestInfo.filtered_stack_trace(stacktrace)),
        params: params
      })

    TestInfo.step_complete(step, if(error, do: %{error: error}, else: %{}))
  end

  @doc false
  # When a test registers, its describe's and its own tags have no worker option of `use/1`, as
  # upstream's `test.use` in a describe raises when it loads; the module's `@moduletag` may.
  def __worker_tags__!(module) do
    # ExUnit's `@describetag` outside a describe (`@ex_unit_describe` unset) applies to nothing.
    if Module.get_attribute(module, :ex_unit_describe),
      do: Options.worker_tags!(Module.get_attribute(module, :describetag) || [], "a describe group")

    Options.worker_tags!(Module.get_attribute(module, :tag) || [], "a test")
  end

  # The end of the body: the test fails with the errors its matchers recorded (upstream's
  # `testInfo.errors`), raised as ExUnit reports them. They are reported here, not by
  # `__failed__/3`, which `--breakpoints` leaves out.
  @doc false
  def __passed__ do
    case TestInfo.finish(self()) do
      [] ->
        Results.notify({:passed, self()})
        finished_test_function(false)

      errors ->
        notify_failed(errors)
        finished_test_function(true)
        Process.put(@reraised, true)

        case errors do
          [{kind, reason, stacktrace}] -> :erlang.raise(kind, reason, stacktrace)
          errors -> raise ExUnit.MultiError, errors: errors
        end
    end
  end

  # Returns the error to raise: the test's recorded errors before this one, all reported, or
  # this one as it is.
  @doc false
  def __failed__(kind, reason, stacktrace) do
    # `__passed__/0` raised the recorded errors and reported them already.
    if Process.delete(@reraised) do
      {kind, reason, stacktrace}
    else
      # Elixir only: a failed `assert/1`'s step (`__assertion_error__/2`).
      __assertion_error__(TestInfo.current(), {kind, reason, stacktrace})
      # The worker's `_failWithError` of the body's error: its trace event (`appendForError`).
      TestInfo.trace_errors(self(), errors(kind, reason, stacktrace))

      error =
        case TestInfo.finish(self()) do
          [] -> {kind, reason, stacktrace}
          errors -> {:error, %ExUnit.MultiError{errors: errors ++ errors(kind, reason, stacktrace)}, stacktrace}
        end

      notify_failed(errors(error))
      finished_test_function(true)
      error
    end
  end

  defp notify_failed(errors) do
    for {kind, reason, stacktrace} <- errors,
        do: Results.notify({:failed, self(), {kind, Exception.normalize(kind, reason, stacktrace), stacktrace}})
  end

  # Each error of an `ExUnit.MultiError` (upstream's `_failWithError` visits an error's `errors`).
  defp errors({kind, reason, stacktrace}), do: errors(kind, reason, stacktrace)
  defp errors(:error, %ExUnit.MultiError{errors: errors}, _stacktrace), do: errors
  defp errors(kind, reason, stacktrace), do: [{kind, reason, stacktrace}]

  # `didFinishTestFunction`: screenshots of the open pages, before the `on_exit` callbacks.
  defp finished_test_function(failed?) do
    with %{screenshot: [{:mode, mode} | _], retry: retry} <- Recorder.registration(self()),
         true <- Recorder.should_capture_upon_finish(mode, failed?, retry),
         recorder when is_pid(recorder) <- Recorder.lookup(self()),
         do: Recorder.capture(recorder, failed?)

    :ok
  catch
    # The recorder is gone: the test's own result and failure stand.
    :exit, _ -> :ok
  end

  @doc false
  # Elixir only: `__started__/1` as the module's first `setup` callback, before those defined
  # before the `use` (and, in a test module, before its case template's), for the test's
  # deadline (`__register__/1`). ExUnit's timeout counts the setup callbacks, as upstream's test
  # timeout counts its `beforeEach` hooks and fixtures. ExUnit has no public way in: its
  # callbacks are `@ex_unit_setup`, newest first, so the last runs first.
  def __clock__(module) do
    case Module.get_attribute(module, :ex_unit_setup) do
      setup when is_list(setup) -> Module.put_attribute(module, :ex_unit_setup, setup ++ [{__MODULE__, :__started__}])
      _ -> :ok
    end
  end

  @doc false
  # The test's first `setup` callback (`__clock__/1`): when ExUnit's clock started, as near as a
  # callback gets.
  def __started__(_context) do
    if !Process.get(@started), do: Process.put(@started, System.monotonic_time(:millisecond))
    :ok
  end

  @doc false
  # The `setup_all` of `use Playwright.Test`: registers the module's `setup_all` process, so the
  # contexts it (or a process with it in `$callers`) creates get the context defaults and
  # timeouts, as upstream's `beforeAll` gets its `all-hooks-included` fixtures.
  def __setup_all__(context) do
    Pool.ensure_started()

    # Once: a case template's body and its `using` may both bring it.
    if !match?({:module, _}, Results.scope(self())) do
      check_registered!(
        self(),
        "this module's setup_all fetched a browser (`BrowserPool.browser/1`) or created a context before " <>
          "`use Playwright.Test` registered it (a case template's own `setup_all` runs before the `use` in " <>
          "its `using`, and a module's `setup_all` before its `use Playwright.Test` runs first): a browser " <>
          "gets none of the module's worker options, a context none of its defaults. Add `use " <>
          "Playwright.Test` as the first line of the case template's body, or move the `setup_all` after " <>
          "the module's `use Playwright.Test`"
      )

      config = Options.config()
      {parameters, tags} = TestInfo.module_sources(context)
      use_options = compiled(context[:module], :options, %{})
      layers = Options.layers(parameters, use_options, tags)

      # `info/0`'s fields that apply to the module (`setup_all_info/1`).
      module =
        config
        |> context_defaults(layers, module_worker(context[:module], use_options, tags))
        |> Map.merge(%{file: compiled(context[:module], :file, nil), timeout: Options.ex_unit_timeout(context)})
        # Also its steps' `testInfo` (`step_test_info!/0`): never started, so not running.
        |> Map.merge(%{test_pid: self(), step_id_prefix: "setup_all", project_name: TestInfo.project_name(parameters)})
        |> Map.put(:project, Options.project(parameters))
        |> Map.put(:use_modes, Options.artifacts(config, layers))

      Results.register_module(self(), module)
    end

    :ok
  end

  # Raises `message` if `pid` created a context or called `BrowserPool.browser/1` before its
  # registration (`Playwright.Test.Results.note_unregistered/1`).
  defp check_registered!(pid, message) do
    case :ets.take(Results.table(), {:unregistered, pid}) do
      [] -> :ok
      [_noted] -> raise "use Playwright.Test: " <> message
    end
  end

  @doc false
  # The per-test `setup` of `use Playwright.Test`: registers the test, once (a case
  # template's body and its `using` may both bring it).
  def __setup__(%{test_pid: test_pid} = context) do
    Pool.ensure_started()

    if !Recorder.registration(test_pid) do
      check_registered!(
        test_pid,
        "this test fetched a browser (`BrowserPool.browser/1`) or created a context before `use " <>
          "Playwright.Test` registered it (a case template's `setup` runs before the `use` in its " <>
          "`using`): a browser gets none of the module's worker options, a context none of its defaults " <>
          "or recording. Add `use Playwright.Test` as the first line of the case template's body"
      )

      test = __register__(context)
      timeout = test.test_timeout
      # Each `on_exit` callback gets the test's timeout: half of it for the artifacts.
      budget = if is_integer(timeout), do: div(timeout, 2), else: :infinity
      ExUnit.Callbacks.on_exit(fn -> __finish__(test.test_pid, budget) end)
    end

    :ok
  end

  @doc false
  # The registration of the test of `context` (its `test_pid`), without its `on_exit`, with the
  # `use` options of its module.
  def __register__(context) do
    # Read and validated once.
    config = Options.config()
    {parameters, tags} = TestInfo.test_sources(context)
    test_info = TestInfo.new(context, config.output_dir, parameters)
    use_options = compiled(context[:module], :options, %{})
    layers = Options.layers(parameters, use_options, tags)
    # As given, for `info/0`'s `use`.
    use_modes = Options.artifacts(config, layers)
    modes = use_modes
    # Upstream's `testTracing.startIfNeeded` and `_contextFactory`'s `captureVideo`, by the retry.
    modes = %{
      modes
      | trace: TestTracing.start_if_needed(modes.trace, test_info.retry),
        video: Recorder.capture_video(modes.video, test_info.retry)
    }

    file = context.file
    # The `test` macro's tag, in the namespace of `use/1`'s keys: not a tag of the user's.
    marked? = context[:"playwright.test"] == :marked
    timeout = Options.ex_unit_timeout(context)

    test =
      test_info
      |> Map.merge(modes)
      |> Map.merge(%{
        title: "#{Path.relative_to_cwd(file)}:#{context[:line]} › #{TestInfo.test_name(context)}",
        title_path: TestInfo.title_path(context),
        location: {file, context[:line]},
        test_timeout: timeout,
        deadline: if(is_integer(timeout), do: started(context) + timeout),
        preserve_output: Options.preserve_output(config),
        tmp: Path.join(System.tmp_dir!(), "playwright-test-#{System.unique_integer([:positive])}")
      })
      |> Map.merge(context_defaults(config, layers, module_worker(context[:module], use_options, %{})))
      |> Map.put(:use_modes, use_modes)
      |> Map.put(:project, Options.project(parameters))
      # Elixir only: the module's `assert_steps` (`__assertion_error__/2`).
      |> Map.put(:assert_steps, compiled(context[:module], :assert_steps, config.assert_steps))

    TestInfo.remove_output_dirs(test)
    # The failure of a marked test that raised nothing in its body.
    failure = if context[:not_implemented], do: "Not implemented", else: Results.outside()
    Results.watch(test.test_pid, marked? && failure)
    :ets.insert(Results.table(), {{:test, test.test_pid}, test})
    if marked?, do: TestInfo.start(test)
    # The steps of `test.trace` go to the recorder.
    if modes.trace[:mode] != :off, do: Results.recorder(test.test_pid)
    test
  end

  # What a test's or a module's `setup_all`'s contexts get: the `context_options` and timeouts
  # of `config` and of its `layers` (`Playwright.Test.Options.layers/3`). And the worker options
  # of its `BrowserPool.browser/1` calls: its project's and the `module`'s (`module_worker/3`),
  # the same for the module's `setup_all` and each of its tests.
  defp context_defaults(config, layers, module) do
    %{
      context_options: Options.context_options(config, layers),
      timeouts: Options.timeouts(config, layers),
      worker: Options.worker(config, layers.project, module)
    }
  end

  # The module's worker options: its `use`, then its `@moduletag`s, merged, the later per option
  # (`ExUnit.TestModule`'s `tags`), never a describe's or a test's tags, as upstream's top-level `test.use` applies to the
  # whole file. `tags` without ExUnit's `__ex_unit__/0`.
  defp module_worker(module, use_options, tags) do
    tags = if module && function_exported?(module, :__ex_unit__, 0), do: module.__ex_unit__().tags, else: tags
    Options.module_worker(use_options, tags)
  end

  # What the module's `use Playwright.Test` compiled in (`__before_compile__/1`): its merged
  # `:options` and its `:file` (absolute, as a test's `file`). None for a `setup_all` run by hand.
  defp compiled(module, key, default) do
    if module && function_exported?(module, :__playwright_test__, 1),
      do: module.__playwright_test__(key),
      else: default
  end

  # ExUnit's clock starts as it spawns the test process: the test's first `setup` callback
  # (`__started__/1`) notes the time. What ExUnit runs before the callbacks (`@tag :tmp_dir`'s
  # cleanup, `capture_log`'s handler) is not counted: it comes out of the margin before the
  # deadline (`Recorder.test_timeout_margin/1`). Now, for a registration from elsewhere.
  defp started(context) do
    (self() == context.test_pid && Process.get(@started)) || System.monotonic_time(:millisecond)
  end

  @doc false
  # The test's end, its first `on_exit`, so it runs last: its artifacts by its result, within
  # `budget` ms, then the release of its pooled drivers. ExUnit kills a callback past the test's
  # timeout, before its `after`: the pool then releases them as this process exits
  # (`Results.finishing/1`).
  def __finish__(test_pid, budget) do
    deadline = if is_integer(budget), do: System.monotonic_time(:millisecond) + budget, else: :infinity
    Results.finishing(test_pid)
    {verdict, _failures} = result = Results.result(test_pid, budget)
    {test, recorder} = Results.take(test_pid)
    if !test, do: raise("Playwright.Test: the test's registration is gone (the pool restarted since)")
    # For `info/1` in the `on_exit` callbacks that run after this one.
    Results.keep_info(test_pid, Map.merge(info_of(test), result_info(test_pid, result, recorder)))

    trace =
      case finish_artifacts(test, recorder, result, deadline) do
        # Past the budget its contexts may be left open in a pooled browser: its workers reset, as a
        # failed test's.
        :abandoned ->
          Pool.fail(test_pid)
          nil

        trace ->
          trace
      end

    # The list reporter's `npx playwright show-trace <path>`, after the failures as its summary
    # has it: ExUnit prints this test's failure only after its `on_exit` callbacks.
    if verdict == :failed and trace,
      do:
        Pool.print_after_suite(
          "Trace of #{inspect(test.test_name)}: mix playwright.cli show-trace #{Path.relative_to_cwd(trace)}"
        )

    if !preserve_output?(test.preserve_output, verdict), do: File.rm_rf(test.output_dir)
  rescue
    exception -> Logger.warning("Playwright.Test could not finish the test: " <> Exception.message(exception))
  after
    Pool.release(test_pid)
    Results.forget(test_pid)
  end

  # The trace, if the test recorded one.
  defp finish_artifacts(_test, recorder, result, deadline) when recorder != nil,
    do: Recorder.finish(recorder, result, remaining(deadline))

  defp finish_artifacts(test, nil, {:failed, failures}, _deadline) do
    ErrorContext.write(test, failures)
    nil
  end

  defp finish_artifacts(_test, nil, _result, _deadline), do: nil

  # workerMain.ts's `preserveOutput`, by the result the artifacts went by (a doctest's is a failure).
  defp preserve_output?(:always, _verdict), do: true
  defp preserve_output?(:failures_only, verdict), do: verdict != :passed
  defp preserve_output?(:never, _verdict), do: false

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  The running test of the calling process or a process in its `$callers` (a `Task`), as
  upstream's `test.info()`: `test_pid`, `file` (absolute), `test_name` (without the macro's
  `test ` prefix), `output_dir` (absolute, with its `-retry1` suffix under `mix test --failed`,
  see "Artifacts" in the moduledoc), `retry` (upstream's `testInfo.retry`: 0, or 1
  under `mix test --failed`) and `timeout` (upstream's `testInfo.timeout`: ExUnit's timeout of the test in
  ms, the `@tag timeout:` or `mix test --timeout`, `:infinity` for none, as under `mix test
  --trace`) and `deadline` (upstream's internal `testInfo._deadline()`: monotonic milliseconds
  (compare with `System.monotonic_time(:millisecond)`) by which the test must be done: after
  it, the test's contexts are closed and Playwright calls fail; `:infinity` without a test
  timeout; see "Timeouts"), from the test's setup to the end of its body. `use` is the test's
  options as resolved from every level (the config's, its project's, its module's, its
  describe's and its own), what upstream's option fixtures give a fixture: a map of the context
  options every context of the test starts from (`base_url`, `locale`, `extra_http_headers`,
  ...; those set, and Playwright Test's defaults), `action_timeout`, `navigation_timeout`,
  `trace`, `screenshot`, `video`, and the worker options of its `BrowserPool.browser/1` calls
  (`browser_name`, `headless`, `channel`, `launch_options`, `connect_options`). A library that passes options in a
  call merges into it, as the call's replace the resolved ones as a whole:
  `Browser.new_context!(browser, extra_http_headers: Map.merge(Test.info().use[:extra_http_headers]
  || %{}, headers))`. A library that waits or
  retries on its own (a server-side backstop) should stop by `deadline`, as the matchers
  stop 250 ms before it, as upstream's stop 250 ms before its test deadline.

  `project` is upstream's `testInfo.project`, a `Playwright.Test.Project`: the module's
  (`parameters/1` in its `parameterize:`), else the default project. Its `name` is `nil` for the
  default project and an unnamed one (upstream's `""`). Its `use` is upstream's `project.use`:
  the options set in the config, the project's over them per option, by the names `use/1` takes
  and `info().use` has (`locale`, `base_url`, `trace`, `browser_name`, a device's
  `default_browser_type`, ...; the config's `test_id_attribute` too), without Playwright Test's
  defaults or the module's, a describe's or a test's options. `context_options` and
  `launch_options` are each one option, as given (upstream's `contextOptions` and
  `launchOptions` objects): a `nil` key and a device's keys stay. Its other fields (`outputDir`,
  `retries`, ...) aren't ported.

  In the module's `setup_all` (and processes with it in `$callers`), it returns the fields that
  apply to the module, with the same meaning: `file`, `timeout` (ExUnit's timeout of the module,
  `@moduletag timeout:` or ExUnit's, the one "Timeouts" in the moduledoc applies to its
  `setup_all` callbacks), `project` (the module run's, as upstream's worker's in `beforeAll`) and
  `use`, the module's options as resolved from the config, its
  project and the module itself (its `use` and `@moduletag`): a describe's and a test's options
  never reach `setup_all`. The test's fields (`test_pid`, `test_name`, `output_dir`, `retry`,
  `deadline`) are absent. Deviations: upstream runs `beforeAll` hooks with the
  first test's `testInfo`, which ExUnit's `setup_all`, run before any test, has none of; and a
  long-lived process or handler of `setup_all`'s (with it in `$callers`) gets the module's fields
  during a test too, as its contexts get the module's defaults (see "Contexts of `setup_all`"),
  until the runner cleans up after it, where upstream's `test.info()` is the current test's. A
  `setup_all` that runs before `use Playwright.Test` registers the module (a case template's
  own, or one above the module's `use`) isn't registered: there it raises.

  A library that also runs outside these scopes reads the config there:

      alias Playwright.Test
      use = if Test.in_registered_scope?(), do: Test.info().use, else: Test.config()

  `config/0` has another shape: the config alone, with the context options set as keys of their
  own (none of Playwright Test's defaults, nor those only in its `context_options` bag) and its
  config-only keys (`workers`, `output_dir`, ...). Read the keys both have with Access,
  `use[:base_url]` (`nil` when unset), not `use.base_url`, which raises for an unset key.

  Raises elsewhere (see `in_registered_scope?/0`), and in `on_exit` callbacks (ExUnit runs them
  in a process of their own, without `$callers`, `setup_all`'s too): there, use `info/1` for a
  test.

      Playwright.Test.info().test_pid
  """
  @spec info() ::
          %{
            test_pid: pid(),
            file: Path.t(),
            test_name: String.t(),
            output_dir: Path.t(),
            retry: non_neg_integer(),
            timeout: timeout(),
            deadline: integer() | :infinity,
            project: Playwright.Test.Project.t(),
            use: map()
          }
          | %{file: Path.t(), timeout: timeout(), project: Playwright.Test.Project.t(), use: map()}
  def info do
    case Recorder.scope() do
      {:test, test} ->
        info_of(test)

      {:module, module} ->
        setup_all_info(module)

      nil ->
        # Upstream's `test.info()` text (`testType.ts`), and its module's setup_all (an addition).
        raise "Playwright.Test.info/0 can only be called while test or its module's setup_all is running"
    end
  end

  # `info/0` in a module's `setup_all`: its fields that apply to the module.
  defp setup_all_info(module) do
    module
    |> Map.take([:file, :timeout])
    |> Map.put(:project, Options.info_project(module.project))
    |> Map.put(:use, Options.resolved(module))
  end

  # `info/0` of a registration: its `@info_keys`, `timeout` (upstream's `testInfo.timeout`) and
  # `deadline` (`TestInfo._deadline/1`, upstream's `testInfo._deadline()`: the contexts' close).
  defp info_of(test) do
    test
    |> Map.take(@info_keys)
    |> Map.merge(%{
      timeout: test.test_timeout,
      deadline: TestInfo._deadline(test).deadline,
      project: Options.info_project(test.project),
      use: Options.resolved(test)
    })
  end

  @doc """
  Whether `info/0` works in the calling process: a registered test or module `setup_all`, or a
  process with either in its `$callers`. `info/0` has `test_pid` only in a test. See `info/0` for
  reading the config elsewhere.
  """
  @spec in_registered_scope?() :: boolean()
  def in_registered_scope?, do: Recorder.scope() != nil

  @doc """
  `info/0` of the test `test_pid` (the context's `test_pid`), from any process, from its setup to
  the end of its `on_exit` callbacks. Once the test's process has exited, so in `on_exit`, it has
  upstream's result fields too, as `testInfo` has in teardown:

    * `status` - `:passed`, `:failed`, `:timed_out` (past ExUnit's timeout), or `nil`
      for a test of another macro (a doctest).
    * `errors` - upstream's `TestInfoError`s: `%{message: _, stack: _}` of an exception,
      `%{value: _}` of an exit or throw.
    * `expected_status` - `:passed` (there is no `test.fail()`).
    * `duration` - ms from the test's setup to its process's exit.

  A failure in an `on_exit` callback doesn't change them.

      setup %{test_pid: test_pid} do
        on_exit(fn ->
          if Playwright.Test.info(test_pid).status != :passed, do: ...
        end)
      end
  """
  @spec info(pid()) :: map()
  def info(test_pid) when is_pid(test_pid) do
    case Recorder.registration(test_pid) do
      nil ->
        case Results.started?() && :ets.lookup(Results.table(), {:info, test_pid}) do
          [{_key, info}] -> info
          _ -> raise "Playwright.Test.info/1: no test running or in its on_exit, got: #{inspect(test_pid)}"
        end

      test ->
        info = info_of(test)

        if Process.alive?(test_pid),
          do: info,
          else: Map.merge(info, result_info(test_pid, Results.result(test_pid, 5000), Recorder.lookup(test_pid)))
    end
  end

  # `testInfo.status`, `errors`, `expectedStatus`, `duration` of a result (`Results.result/2`).
  # Past the timeout: killed, or failed after the recorder closed its contexts.
  defp result_info(test_pid, {verdict, failures}, recorder) do
    status =
      if verdict == :failed and (Results.killed() in failures or Recorder.timed_out?(recorder)),
        do: :timed_out,
        else: verdict

    errors =
      Enum.map(failures, fn
        message when is_binary(message) -> %{message: message}
        error -> TestInfo.test_info_error(error)
      end)

    %{status: status, errors: errors, expected_status: :passed, duration: Results.duration(test_pid)}
  end

  @doc """
  Options for a module's `@moduletag`, a `describe` block or a test: upstream's `test.use`. It
  takes the options of `use Playwright.Test` (the context options, `context_options`,
  `action_timeout`, `navigation_timeout`, `trace`, `screenshot`, `video`, and in `@moduletag`
  the worker's), as a keyword list or a map, validates them as it does, and returns a keyword
  list for an ExUnit tag. A device in `@moduletag` too; in a describe's or a test's tag only
  without its `default_browser_type`.

      # test.describe(() => { test.use({ timezoneId: 'Europe/Berlin' }) ... })
      describe "in Berlin" do
        @describetag Test.use(timezone_id: "Europe/Berlin")
        ...
      end

      # One test. Upstream nests a describe around it; ExUnit's can't nest.
      @tag Test.use(trace: :on)
      test "pays", %{page: page} do
        ...
      end

      # A device's emulation without its browser (a device in a test's or a describe's tag
      # raises, as its `default_browser_type` is the worker's: make each device a project).
      @tag Test.use(Keyword.delete(Playwright.device("iPhone 13"), :default_browser_type))

  Each option gets a private key of its own (`:"playwright.use.trace"`,
  `:"playwright.use.context.locale"`), so ExUnit, which merges a test's `@moduletag`,
  `@describetag` and `@tag` per key, layers them per option, the test's over the describe's
  over the module's: a describe's `timezone_id` and a test's `trace` both apply, as do several
  calls on one test, and an option given as `nil` resets it to the project's, the config's or
  the default. A plain tag named like an option (`@tag trace: :on`) sets nothing.

  An unknown option raises `ArgumentError`, when the test module compiles. So do
  `browser_name`, `default_browser_type` (a device's), `headless`, `channel`, `launch_options` and
  `connect_options` in a `@describetag` or a `@tag`, when the module compiles a test of the `test` macro under it,
  with upstream's message ("Cannot use({
  browser_name }) in a describe group, because it forces a new worker.\nMake it top-level in the
  test file or put in the configuration file.", "in a test" for a `@tag`): they are the
  worker's (a test the check doesn't see gets the module's worker regardless). They are options
  of the module's `use`, its `@moduletag` and `parameters/1`. For a
  project in `parameterize:`, which takes maps, see `parameters/1`. See "Context defaults",
  "Browser" and "Artifacts" in the moduledoc for the layers.
  """
  @spec use(keyword() | map()) :: keyword()
  def use(opts), do: Options.use(opts)

  @doc """
  A project for `parameterize:`, upstream's `projects: [{ name, use: { ... } }]`: `name:` (a
  string, upstream's `project.name`), `use/1`'s options and the worker's (`browser_name`,
  `default_browser_type`, `headless`, `channel`, `launch_options`, `connect_options`), validated
  as it does. A map of
  one private key, `:"playwright.project"`, whose value is a `Playwright.Test.Project`, which
  ExUnit takes there (a tag takes `use/1`'s keyword list).

      use Playwright.Case,
        async: true,
        parameterize:
          for device <- ["Desktop Chrome", "Desktop Firefox", "Desktop Safari"],
              do: Playwright.Test.parameters([name: device] ++ Playwright.device(device))

  The project's options are under the module's `use` and over the config's, for every context
  of the module's run, `setup_all`'s included. Its browser is its `browser_name`, else the
  config's, else its `default_browser_type` (a device's), see "Browser" in the moduledoc. A failed
  test prints the project as its name (`Parameters: %{"playwright.project":
  #Playwright.Test.Project<"Desktop Safari">}`, `[Desktop Safari] ›` in
  `Playwright.Test.GitHubFormatter`); the name is also the snapshot templates' `{projectName}`.
  An unnamed project, as upstream's, has no label: it prints as its options, so name each one.
  For parameters of your own next to it: `Map.put(Test.parameters(...), :role, :admin)`.
  """
  @spec parameters(keyword() | map()) :: %{optional(atom()) => Playwright.Test.Project.t()}
  def parameters(opts), do: Options.parameters(opts)

  @doc """
  The resolved `config :playwright, :test` (see "Config" in the moduledoc), for libraries
  that build on the runner: a map of the listed keys, each with its default filled in and its
  value validated, as the runner reads it, and the context options that are set. The recording
  modes are keyword lists with `:mode` first (`trace: [mode: :off, snapshots: true, ...]`), a
  context option is as configured (none of Playwright Test's context defaults; one set only in
  `context_options` is there only), and an unset `action_timeout` or `navigation_timeout` is
  `:infinity`. A test's resolved options, over every level, are `info().use`. `expect: %{timeout: ms}`
  is the matchers' timeout of the config's `expect` (5000 by default, `0` for none), and
  `update_snapshots` an atom. Works outside a test too (at startup, in a module
  without `use Playwright.Test`); raises `ArgumentError` for an invalid config.

      Playwright.Test.config().workers
  """
  @spec config() :: map()
  def config do
    config = Options.config()
    # Validated as the registration converts them for `Playwright.Browser.new_context/2`.
    Options.context_options(config)
    expect_config = Playwright.Matchers.Expect.app_env_expect_config()

    Map.merge(config, %{
      expect: %{timeout: Playwright.Matchers.Expect.config_timeout()},
      update_snapshots: String.to_existing_atom(expect_config.updateSnapshots),
      ignore_snapshots: expect_config.ignoreSnapshots
    })
  end

  @doc """
  The path of `path_segments` (a string or a list of them) in the test's output dir (see
  "Artifacts" in the moduledoc), as upstream's `testInfo.outputPath(...pathSegments)`: creates the
  dir, and raises for a path outside it. Files written
  there stay when the test passes, under the default `preserve_output`.
  """
  @spec output_path(String.t() | [String.t()]) :: Path.t()
  def output_path(path_segments) when is_binary(path_segments) or is_list(path_segments) do
    this = running_test!("output_path/1")
    output_path = TestInfo._get_output_path(this, List.wrap(path_segments))
    File.mkdir_p!(this.output_dir)
    output_path
  end

  @doc """
  Upstream's `testInfo.attach(name, options)`: attaches a file or a binary to the running test,
  as a `test.attach` step of its trace, which shows it. Options:

    * `:path` - a file, copied to `attachments/<name>-<hash><ext>` in the test's output dir,
      which keeps it also when the test passes.
    * `:body` - the content itself.
    * `:content_type` - by default the path's MIME type, or `text/plain` for a UTF-8 `body`
      (`application/octet-stream` otherwise).

  One of `path` and `body`, or neither for an attachment of just a name. Raises outside a test.

      Playwright.Test.attach("screenshot", body: Page.screenshot!(page), content_type: "image/png")
  """
  @spec attach(String.t(), keyword()) :: :ok
  def attach(name, options \\ []) when is_binary(name) do
    options =
      Playwright.Application.options!("Playwright.Test.attach/2", options, [
        :path,
        :body,
        :content_type
      ])

    test_info = running_test!("attach/2", &TestInfo.current/0)
    TestInfo.attach(test_info, name, %{path: options[:path], body: options[:body], contentType: options[:content_type]})
  end

  @doc """
  The snapshot path of `name` for the running test, as upstream's `testInfo.snapshotPath`:
  where `Playwright.Expect.to_have_screenshot/2` (`kind: :screenshot`) and
  `Playwright.Expect.to_match_aria_snapshot/3` (`kind: :aria`) with `name:` read and write it
  (see "Snapshots" in the moduledoc). `name` is a string or a list of path segments
  (`["home", "hero.png"]`, upstream's `snapshotPath(...name)`), which are not sanitized. Option
  `:kind`: `:snapshot` (default, upstream's), `:screenshot` or `:aria`.
  """
  @spec snapshot_path(String.t() | [String.t()], keyword()) :: Path.t()
  def snapshot_path(name, options \\ []) when is_binary(name) or is_list(name) do
    options = Playwright.Application.options!("Playwright.Test.snapshot_path/2", options, [:kind])
    kind = Keyword.get(options, :kind, :snapshot)

    TestInfo.snapshot_path(running_test!("snapshot_path/2"), name, to_string(kind))
  end

  # The running test's registration (as `info/0` finds it), for a function of the test only: it
  # raises in `setup_all`, which has no output dir or snapshot names.
  defp running_test!(function, lookup \\ &Recorder.registration/0) do
    # Upstream's `test.info()` text (`testType.ts`), for the function of `testInfo` called.
    lookup.() || raise "Playwright.Test.#{function} can only be called while test is running"
  end

  @doc """
  Upstream's `test.step(title, body, options)`: runs the body as a step of the running test
  and returns its value, also from a process with the test in its `$callers` (a `Task`); steps
  nest. A step's error is raised on after the step records it. In the module's `setup_all`
  (and processes with it in `$callers`) it runs too, recorded nowhere (see "Steps" in the
  moduledoc); elsewhere it raises.

      step "log in" do
        ...
      end

      step "log in", box: true do
        ...
      end

      step("log in", fn -> ... end, box: true)

  Options:

    * `:box` - the step is located at the call of the function the step is in (a helper's
      caller), unless `:location` is given, and an error inside it is reported there: its
      stacktrace starts at that call, instead of the frames inside it. The steps inside keep
      their own locations. A boxed step outside a helper (in the test's body) has no location of
      its own; pass `location:`.
    * `:location` - `%{file: _, line: _, column: _}` of the step in the trace. The `do` form
      passes its own, unless boxed.
    * `:params`, `:subtitle` - shown with the step in the trace.

  The body runs in the calling process. Upstream's `timeout` is not supported (it raises an
  `ArgumentError`): a process can't be interrupted, and the test's timeout bounds the step.

  The step, the matchers in it and the test's errors are in the test's trace (`test.trace` in
  `trace.zip`). A step in a `Task` has no parent step: the `Task` doesn't carry the zone.
  """
  defmacro step(title, body_or_options, options \\ []), do: step_ast(:pass, title, body_or_options, options, __CALLER__)

  @doc """
  Upstream's `test.step.skip(title, body, options)`: a step that doesn't run its body, marked
  `skip` in the trace. Returns `nil`. The forms and options are `step/3`'s.
  """
  defmacro step_skip(title, body_or_options, options \\ []),
    do: step_ast(:skip, title, body_or_options, options, __CALLER__)

  # `step "title" do ... end` (with options before the `do`), or `step(title, fun, options)`.
  defp step_ast(expectation, title, body_or_options, options, caller) do
    location = Macro.escape(%{file: caller.file, line: caller.line, column: 0})
    call_site = Macro.escape(%{file: caller.file, line: caller.line})

    {body, options} =
      cond do
        do_block?(body_or_options) and options == [] ->
          {step_fn(body_or_options), [location: location]}

        # A boxed step is located where its helper is called (`boxedStack`), as upstream's
        # without `location`.
        do_block?(options) ->
          {step_fn(options),
           quote do
             options = unquote(body_or_options)
             if options[:box], do: options, else: Keyword.put_new(options, :location, unquote(location))
           end}

        true ->
          {body_or_options, options}
      end

    quote do
      Playwright.Test._step(unquote(expectation), unquote(title), unquote(body), unquote(options), unquote(call_site))
    end
  end

  defp do_block?(ast), do: is_list(ast) and Keyword.keyword?(ast) and Keyword.has_key?(ast, :do)

  # `rescue`, `catch`, `after`, `else` as in a `def`. Elixir only: the `try` keeps the body's last
  # call from being a tail call, so the body's frame stays in its calls' stacks (the client's
  # location of a call, `Playwright.Client.ClientStackTrace`) as JS keeps every frame.
  defp step_fn(do: block), do: quote(do: fn -> try(do: unquote(block), after: nil) end)
  defp step_fn(contents), do: quote(do: fn -> try(unquote(contents)) end)

  @doc false
  # `TestTypeImpl._step`: `expectation` is `:pass` (`test.step`) or `:skip` (`test.step.skip`).
  # Elixir only: `call_site` (`%{file: _, line: _}`, the macros pass it, else `location`'s) is
  # where the step is called, for the boxed stack to start after it.
  def _step(expectation, title, body, options \\ [], call_site \\ nil) when is_function(body, 0) do
    # deviation: no `timeout` (`raceAgainstDeadline` below).
    if Keyword.keyword?(options) and Keyword.has_key?(options, :timeout),
      do:
        raise(
          ArgumentError,
          "Playwright.Test.step/3: unsupported option timeout (a step body can't be interrupted " <>
            "in its own process; the test's timeout bounds it)"
        )

    options =
      Playwright.Application.options!("Playwright.Test.step/3", options, [
        :box,
        :location,
        :params,
        :subtitle
      ])

    options = Map.new(options)
    call_site = call_site || (options[:location] && Map.take(options.location, [:file, :line]))
    test_info = step_test_info!()
    Recorder.on_user_step(test_info.test_pid, {:begin, title})

    step =
      TestInfo._add_step(test_info, %{
        category: "test.step",
        title: title,
        subtitle: options[:subtitle],
        stack: if(options[:location], do: [options.location]),
        box: options[:box],
        params: options[:params],
        callSite: call_site
      })

    Zones.with(:stepZone, step, fn ->
      try do
        # A process can't be interrupted, so the body runs inline: a race would run it in another
        # process (its own `self()` and mailbox), on past the timeout.
        # result = await raceAgainstDeadline(async () => {  -- not ported: step timeout
        result = TestInfo._run_step_body(step, expectation == :skip, body, List.first(step.stack))
        # } catch (e) { if (result?.timedOut) testInfo._failWithError(e); throw e; }  -- not ported: step timeout
        # }, options.timeout ? monotonicTime() + options.timeout : 0);  -- not ported: step timeout
        # if (result.timedOut) throw new TimeoutError(...);  -- not ported: step timeout
        TestInfo.step_complete(step, %{})
        result
      catch
        kind, reason ->
          TestInfo.step_complete(step, %{error: {kind, reason, __STACKTRACE__}})
          # deviation: Elixir errors are immutable, so none carries its step (`stepSymbol`) for
          # `_failWithError` to report a boxed step's stack: the step raises it with that stack,
          # which ExUnit reports.
          :erlang.raise(kind, reason, step.boxedStack || __STACKTRACE__)
      after
        # finally { await testInfo._onUserStepEnd?.(); }
        Recorder.on_user_step(test_info.test_pid, :end)
      end
    end)
  end

  # `currentTestInfo()`. deviation: in a module's `setup_all` (or a process with it in
  # `$callers`), its registration (`__setup_all__/1`), as upstream's `beforeAll` runs with the
  # first test's and ExUnit's `setup_all` before any test. It isn't a running test's
  # (`TestInfo.start/1`), so its steps nest and box, but `TestInfo.put_row/3` drops their rows,
  # and it has no recorder (no trace) nor a test's registration (`Recorder.on_user_step/2`).
  defp step_test_info! do
    TestInfo.current() || setup_all_scope() || raise("test.step() can only be called from a test")
  end

  defp setup_all_scope do
    case Recorder.scope() do
      {:module, module} -> module
      _test_or_nil -> nil
    end
  end
end
