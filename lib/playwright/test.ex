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
        context_options: [base_url: "http://localhost:4000"]

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
  imports only a `test` macro, which hands the test to `ExUnit.Case.test/3` with the body's end
  marked, so the test's `on_exit` learns whether it passed. And it adds a `setup` that
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
  context that a test process creates before its registration (a template's `setup` with no
  `use` in the body) makes the registration raise,
  with that fix. It registers the module's `setup_all` process too, as upstream runs its
  `beforeAll` hooks with its `all-hooks-included` fixtures: see "Contexts of `setup_all`". A
  `setup_all` runs in that process, not a test's, so one that creates a context before the
  registration (a template's own `setup_all`, or one above the module's `use`) makes the
  module's `setup_all` raise, with the fix, and fails all its tests. A context created outside
  both (in an `on_exit` callback, in a module without `use Playwright.Test`, in a process with
  neither in its `$callers`, on a driver you started yourself) gets no defaults and no recording.

  The rest is called qualified, as upstream's `test.info()` and `test.step()`: `info/0`
  (`info/1` in `on_exit`, with the test's result), `output_path/1`, `attach/2`, `snapshot_path/2`, `step/2,3` and `step_skip/2,3`. They work in the test's
  process and in processes with it in `$callers` (a `Task`, and the client's callback
  processes, see "Route handlers and listeners" in the Testing with ExUnit guide); outside a
  test they raise.

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
      open when their context closes (`timeout: 5000, caret: :initial`, as upstream).
    * `video.webm`, `video-1.webm`, ... - every page's video. A context created with its own
      `record_video` keeps it, and its video is copied here too.
    * `error-context.md` - a failed test's errors, source and an aria snapshot (`mode: :ai`) of
      the first page of the first context closed after the failure (upstream's `didFinishTest`
      and `buildErrorContext`), whatever the modes.

  The modes are config, the module's `use` options over it, and tags over those (a test's
  `@tag` over its `@describetag` over the module's `@moduletag`): `trace` and `video` `:off`
  (default), `:on`, `:retain_on_failure` or a retry mode, `screenshot` `:off`, `:on`,
  `:only_on_failure` or `:on_first_failure`, and `true` (`:on`) or `false` (`:off`). Each is
  also the `:mode` of a keyword list (or map) of options, as upstream's object forms: `trace:
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
  modes are worker-scoped options there), with the values the config takes; an unknown option or
  an invalid value raises at compile time. A module's `use`s merge per key, the later winning.
  ExUnit.Case's keys (`:async`, ...) are ignored, so a template forwards its options from `using
  opts` as is: `use Playwright.Test, unquote(opts)`, as `Playwright.Case` does. A template
  with options of its own pops them first (`{sandbox, opts} = Keyword.pop(opts, :sandbox)`),
  as they raise here. The tags
  take the same values, so `trace`, `screenshot` and `video` are reserved tags: a `@tag
  :screenshot` label turns screenshots on, and an invalid value raises at registration, unless
  the module has `use Playwright.Test, tags: false` (default `true`): then tags don't set the
  modes.

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
  (`info/0`'s `retry`, 1 after the first run), and writes to `<dir>-retry1` (`-retry2` on the
  next `--failed`, ...), next to the dirs of its earlier runs. So with `trace: :on_first_retry`,
  `mix test || { [ $? -eq 2 ] && mix test --failed; }` traces the failures' rerun and keeps the
  first run's files (exit status 2 means tests failed; anything else isn't retried). A run
  without `--failed` deletes the test's `-retryN` dirs too, where
  upstream deletes all of `output_dir` at the start of a run: here the dirs of tests that didn't
  run stay. Config `preserve_output` is upstream's `preserveOutput`: `:always` (default) keeps
  the files at the end of each test, `:failures_only` only a failed test's, `:never` none. The
  retry is counted from the test's dirs on disk, so with `:never` (no dirs left) each
  `--failed` run is retry 1 again.

  ## Context defaults

  Every context and request context a test (or its module's `setup_all`) creates on a
  `BrowserPool` browser (`Playwright.Browser.new_context/2`,
  `Playwright.BrowserType.launch_persistent_context/3`, `Playwright.APIRequest.new_context/2`) gets Playwright Test's context defaults (`locale:
  "en-US"`, a 1280x720 viewport, `color_scheme: :light`, ...), then the config's
  `context_options` over them, for each option the call doesn't give, as upstream's
  `_combinedContextOptions`. An option given as `nil` keeps the client's default; `viewport:
  :null` is none. An option replaces the default as a whole (`extra_http_headers` too, as
  upstream's shallow spread).

  ## Contexts of `setup_all`

  `use Playwright.Test` adds a `setup_all` (where the `use` is, so before the module's own) that
  registers the module's `setup_all` process: every context and request context it creates, or
  a process with it in `$callers` creates, gets the context defaults and the config's
  `context_options` (so `base_url`), merged as a test's, and the config's timeouts (see
  "Timeouts"): a context's `action_timeout` and `navigation_timeout`, a request context's
  `timeout:` the `action_timeout` (`0`, no limit, for `:infinity`) and no navigation timeout. Not
  the video, as upstream's comes with the `context` fixture.

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
  test's timeout bounds them. Config `action_timeout` and `navigation_timeout` (upstream's
  `actionTimeout`, `navigationTimeout`; milliseconds, `:infinity` by default) set each context's
  `Playwright.BrowserContext.set_default_timeout/2` and `set_default_navigation_timeout/2`
  (`navigation_timeout` alone governs navigations), and the action timeout is a request
  context's `timeout`, when the call gives none. `0` is no limit too, not an immediate failure,
  as `timeout: 0` is everywhere in Playwright (see [API conventions](api-conventions.md)):
  write `:infinity` to say so.

  Shortly before ExUnit's timeout (1 s before, at most 5% of the timeout), the test's open
  contexts are closed with upstream's reason, "Test timeout of 60000ms exceeded.": a call that
  hangs until then fails with that message and its call log, after the close kept the artifacts.
  A test stuck elsewhere (`Process.sleep/1`, a `receive`) still fails with ExUnit's
  `ExUnit.TimeoutError`. The timeout is ExUnit's: the `@tag timeout:` (`:infinity` for none) or
  `mix test --timeout`; `mix test --trace` has none. As ExUnit's (and upstream's, which counts
  `beforeEach` hooks), the timeout counts the test's `setup` callbacks: the clock starts at the
  module's first one, also one defined before `use Playwright.Test` or in its case template.
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
  nothing bounds them. Its contexts get the config's `action_timeout` and
  `navigation_timeout` (`:infinity` by default, not the client's 30 s), as upstream's `beforeAll`
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
  `test/` by default; `snapshot_path_template` (or the matcher's `pathTemplate` in `config
  :playwright, :expect`) takes upstream's tokens: `{testDir}`, `{snapshotDir}`,
  `{testFileDir}`, `{testFileName}`, `{testFileBaseName}`, `{testFilePath}`, `{testName}`,
  `{arg}`, `{ext}`, `{platform}` and `{snapshotSuffix}` (the platform, as upstream's);
  `{projectName}` is accepted for upstream templates and is always empty. `snapshot_path/2`
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

  ## Config

      config :playwright, :test,
        browser_name: :chromium,      # BrowserPool: :chromium | :firefox | :webkit
        launch_options: [],           # BrowserPool: Playwright.BrowserType.launch/2
        connect_options: nil,         # BrowserPool: [ws_endpoint: _, ...] to connect instead of launching
        driver: [],                   # BrowserPool: Playwright.Supervisor's :env, :executable, :node, :cache_dir
        on_start: nil,                # BrowserPool
        workers: max(div(System.schedulers_online(), 2), 1),
        context_options: [],          # Playwright.Browser.new_context/2, over the defaults
        action_timeout: :infinity,    # ms, each context's default (and navigation_timeout's); :infinity or 0: none
        navigation_timeout: :infinity,
        trace: :off,                  # :off | :on | :retain_on_failure | :on_first_retry | ..., or [mode: _, ...]
        screenshot: :off,             # :off | :on | :only_on_failure | :on_first_failure, or [mode: _, ...]
        video: :off,                  # as trace, or [mode: _, size: _]
        output_dir: "test-results",
        preserve_output: :always,     # :always | :failures_only | :never, see Artifacts
        snapshot_dir: nil,            # upstream's testDir: test/
        snapshot_path_template: nil,  # upstream's defaults, see Snapshots
        test_id_attribute: "data-testid"

  The artifact modes are `off` by default and `output_dir` is `test-results`, as upstream's.
  `workers` is half the schedulers, as upstream's default `workers` is half the cores (`'50%'`).
  `test_id_attribute` is upstream's `testIdAttribute`, set on each pooled driver: the client's
  value is global to the VM, so set it here, not per module. `config/0` returns the config
  resolved. An unknown key or a bad value raises at application start (and when the runner
  reads a config changed since).
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
  # `info/0`'s fields of the registration.
  @info_keys [:test_pid, :file, :test_name, :output_dir, :retry]

  defmacro __using__(opts) do
    macros = __CALLER__.macros

    cond do
      # A test module, also when `use Playwright.Test` came before (from a template's `using`):
      # its import replaced ExUnit.Case's `test`.
      {:test, 3} in Keyword.get(macros, ExUnit.Case, []) or {:test, 3} in Keyword.get(macros, __MODULE__, []) ->
        quote do
          import ExUnit.Case, only: [describe: 2]
          import Playwright.Test, only: [test: 1, test: 2, test: 3]
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
        Module.put_attribute(module, :playwright_test, Map.merge(past, options))
        false
    end
  end

  @doc false
  # The module's merged `use` options, for its registration (`__register__/1`): a function, so the
  # test's context stays the test author's. And the timeout of its `setup_all` callbacks
  # (`Playwright.Test.SetupAllTimeout`), around all of them: this hook runs after ExUnit's, which
  # compiled them into `__ex_unit__/2`.
  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :playwright_test)

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
      @tag playwright_test: :marked
      ExUnit.Case.test(unquote(message), unquote(var), unquote(contents))
    end
  end

  @doc "`ExUnit.Case.test/1`: a test that fails as not implemented."
  defmacro test(message) do
    quote do
      @tag playwright_test: :marked
      ExUnit.Case.test(unquote(message))
    end
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
  def __setup_all__(_context) do
    Pool.ensure_started()

    # Once: a case template's body and its `using` may both bring it.
    if !match?({:module, _}, Results.scope(self())) do
      check_registered!(
        self(),
        "this module's setup_all created a context before `use Playwright.Test` registered it (a case " <>
          "template's own `setup_all` runs before the `use` in its `using`, and a module's `setup_all` " <>
          "before its `use Playwright.Test` runs first), so the context got no context defaults: " <>
          "add `use Playwright.Test` as the first line of the case template's body, or move the " <>
          "`setup_all` after the module's `use Playwright.Test`"
      )

      Results.register_module(self(), context_defaults(Options.config()))
    end

    :ok
  end

  # Raises `message` if `pid` created a context before its registration
  # (`Playwright.Test.Results.note_unregistered/1`).
  defp check_registered!(pid, message) do
    if :ets.take(Results.table(), {:unregistered, pid}) != [], do: raise(ArgumentError, message)
  end

  @doc false
  # The per-test `setup` of `use Playwright.Test`: registers the test, once (a case
  # template's body and its `using` may both bring it).
  def __setup__(%{test_pid: test_pid} = context) do
    Pool.ensure_started()

    if !Recorder.registration(test_pid) do
      check_registered!(
        test_pid,
        "this test created a context before `use Playwright.Test` registered it (a case template's " <>
          "`setup` runs before the `use` in its `using`), so the context has no defaults and no " <>
          "recording: add `use Playwright.Test` as the first line of the case template's body"
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
    test_info = TestInfo.new(context, config.output_dir)
    modes = Options.artifacts(context, config, use_options(context[:module]))
    # Upstream's `testTracing.startIfNeeded` and `_contextFactory`'s `captureVideo`, by the retry.
    modes = %{
      modes
      | trace: TestTracing.start_if_needed(modes.trace, test_info.retry),
        video: Recorder.capture_video(modes.video, test_info.retry)
    }

    file = context.file
    marked? = context[:playwright_test] == :marked
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
      |> Map.merge(context_defaults(config))

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

  # What a test's or a module's `setup_all`'s contexts get from `config`.
  defp context_defaults(config),
    do: %{context_options: Options.context_options(config), timeouts: Options.timeouts(config)}

  # The merged options of a module's `use Playwright.Test` (`__before_compile__/1`).
  defp use_options(module) do
    if module && function_exported?(module, :__playwright_test__, 1),
      do: module.__playwright_test__(:options),
      else: %{}
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
    if !test, do: raise("its registration is gone (the pool restarted since)")
    # For `info/1` in the `on_exit` callbacks that run after this one.
    Results.keep_info(test_pid, Map.merge(info_of(test), result_info(test_pid, result, recorder)))

    trace =
      case finish_artifacts(test, recorder, result, deadline) do
        # Past the budget its contexts may be left open in a pooled browser: its seats reset, as a
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
  `test ` prefix), `output_dir` (absolute, with its `-retryN` suffix under `mix test --failed`,
  see "Artifacts" in the moduledoc), `retry` (upstream's `testInfo.retry`: 0, or N in a
  `-retryN` run) and `timeout` (upstream's `testInfo.timeout`: ExUnit's timeout of the test in
  ms, the `@tag timeout:` or `mix test --timeout`, `:infinity` for none, as under `mix test
  --trace`), `deadline` (the `System.monotonic_time(:millisecond)` at which ExUnit's timeout
  kills the test, counted from its first setup callback as ExUnit counts, `:infinity` for none)
  and `close_deadline` (when the runner closes the test's contexts, `min(1000, timeout / 20)` ms
  before `deadline`, see "Timeouts": upstream's internal `testInfo._deadline()`, where its
  timeout fails the test), from the test's setup to the end of its body. A library that waits or
  retries on its own (a server-side backstop) should stop by `close_deadline`, as the matchers
  stop 250 ms before it, as upstream's stop 250 ms before its test deadline. Raises outside a
  test (see `in_registered_test?/0`), and in `on_exit` callbacks (ExUnit runs them in a process
  of their own): there, use `info/1`.

      Playwright.Test.info().test_pid
  """
  @spec info() :: %{
          test_pid: pid(),
          file: Path.t(),
          test_name: String.t(),
          output_dir: Path.t(),
          retry: non_neg_integer(),
          timeout: timeout(),
          deadline: integer() | :infinity,
          close_deadline: integer() | :infinity
        }
  def info do
    case Recorder.registration() do
      nil ->
        raise "Playwright.Test.info() can only be called while a test is running: in a test of a module with " <>
                "`use Playwright.Test` (its process, or one with it in $callers)"

      test ->
        info_of(test)
    end
  end

  # `info/0` of a registration: its `@info_keys`, `timeout` (upstream's `testInfo.timeout`),
  # `deadline` (ExUnit's) and `close_deadline` (`TestInfo._deadline/1`, the contexts' close).
  defp info_of(test) do
    test
    |> Map.take(@info_keys)
    |> Map.merge(%{
      timeout: test.test_timeout,
      deadline: test.deadline || :infinity,
      close_deadline: TestInfo._deadline(test).deadline
    })
  end

  @doc """
  Whether the calling process runs a registered test, as `info/0` finds it: the test's process,
  or a process with it in `$callers` (a `Task`), of a module with `use Playwright.Test`, from
  the test's setup to the end of its body. For a library that also runs outside such tests.

      if Playwright.Test.in_registered_test?(), do: Playwright.Test.info().deadline, else: :infinity
  """
  @spec in_registered_test?() :: boolean()
  def in_registered_test?, do: Recorder.registration() != nil

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
          _ -> raise ArgumentError, "Playwright.Test.info/1: no test #{inspect(test_pid)} running or in its on_exit"
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
  The resolved `config :playwright, :test` (see "Config" in the moduledoc), for libraries
  that build on the runner: a map of every key, with its default filled in and its value
  validated, as the runner reads it. The recording modes are keyword lists with `:mode` first
  (`trace: [mode: :off, snapshots: true, ...]`), `context_options` are as configured (without
  Playwright Test's context defaults), and an unset `action_timeout` or `navigation_timeout` is
  `:infinity`. `expect: %{timeout: ms}` is the matchers' timeout of `config :playwright,
  :expect` (5000 by default, `0` for none). Works outside a test too (at startup, in a module
  without `use Playwright.Test`); raises `ArgumentError` for an invalid config.

      Playwright.Test.config().workers
  """
  @spec config() :: map()
  def config do
    config = Options.config()
    # Validated as the registration converts them for `Playwright.Browser.new_context/2`.
    Options.context_options(config)
    Map.put(config, :expect, %{timeout: Playwright.Matchers.Expect.config_timeout()})
  end

  @doc """
  The path of `name` in the test's output dir (see "Artifacts" in the moduledoc), as upstream's
  `testInfo.outputPath`: creates the dir, and raises for a `name` outside it. Files written
  there stay when the test passes, under the default `preserve_output`.
  """
  @spec output_path(String.t()) :: Path.t()
  def output_path(name) when is_binary(name) do
    %{output_dir: dir} = info()

    case Path.safe_relative(name) do
      {:ok, relative} ->
        File.mkdir_p!(dir)
        Path.join(dir, relative)

      :error ->
        raise ArgumentError, "output_path is not allowed outside of the output dir, got: #{inspect(name)}"
    end
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
    options = Keyword.validate!(options, [:path, :body, :content_type])
    test_info = TestInfo.current() || raise "Playwright.Test.attach/2 can only be called while a test is running"
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
    {kind, options} = Keyword.pop(options, :kind, :snapshot)
    if options != [], do: raise(ArgumentError, "unknown options #{inspect(Keyword.keys(options))}, expected [:kind]")
    %{test_pid: test_pid} = info()
    TestInfo.snapshot_path(Recorder.registration(test_pid), name, to_string(kind))
  end

  @doc """
  Upstream's `test.step(title, body, options)`: runs the body as a step of the running test
  and returns its value, also from a process with the test in its `$callers` (a `Task`); steps
  nest. A step's error is raised on after the step records it. Outside a test it raises.

      step "log in" do
        ...
      end

      step "log in", box: true do
        ...
      end

      step("log in", fn -> ... end, box: true)

  Options:

    * `:box` - an error inside the step is reported outside it: its stacktrace starts at the
      call of the function the step is in (a helper's caller), instead of the frames inside it.
    * `:location` - `%{file: _, line: _, column: _}` of the step in the trace. The `do` form
      passes its own.
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

        do_block?(options) ->
          {step_fn(options), quote(do: Keyword.put_new(unquote(body_or_options), :location, unquote(location)))}

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
    if Keyword.has_key?(options, :timeout),
      do:
        raise(
          ArgumentError,
          "step timeout is not supported: a step body can't be interrupted in its own process; the test's timeout bounds it"
        )

    options = Map.new(Keyword.validate!(options, [:box, :location, :params, :subtitle]))
    call_site = call_site || (options[:location] && Map.take(options.location, [:file, :line]))
    test_info = TestInfo.current()
    if !test_info, do: raise("test.step() can only be called from a test")
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
end
