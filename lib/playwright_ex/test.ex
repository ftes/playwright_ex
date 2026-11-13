defmodule PlaywrightEx.Test do
  @moduledoc """
  Playwright Test's per-test machinery on ExUnit: each test's result, its artifacts (traces,
  screenshots, videos, `error-context.md`), Playwright Test's context defaults, soft errors,
  snapshot and output paths, and steps. The browser comes from `PlaywrightEx.Test.BrowserPool`,
  contexts and pages from the plain API; `PlaywrightEx.Case` puts them together.

      # config/test.exs
      config :playwright_ex, :test,
        trace: if(System.get_env("TRACE"), do: :on, else: :off),
        screenshot: :only_on_failure,
        context_options: [base_url: "http://localhost:4000"]

      defmodule MyApp.CheckoutTest do
        use ExUnit.Case, async: true
        use PlaywrightEx.Test

        alias PlaywrightEx.{Browser, BrowserContext, Page}

        setup_all do
          %{browser: PlaywrightEx.Test.BrowserPool.browser()}
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

  `use PlaywrightEx.Test` comes after `use ExUnit.Case` (or in a case template's `using`). It
  imports only a `test` macro, which hands the test to `ExUnit.Case.test/3` with the body's end
  marked, so the test's `on_exit` learns whether it passed. And it adds a `setup` that
  registers each test: its recording modes, its output dir and an `on_exit` (the first, so it
  runs last) that keeps or drops the artifacts by the result, then releases the test's
  `BrowserPool.browser/1` drivers. Tests of other macros (doctests, a `property`) count as
  failed for their artifacts, and a failure only in an `on_exit` callback counts as passed.

  In a case template, `use PlaywrightEx.Test` may also be the first line of the template's
  body: a template's own `setup` callbacks run before those its `using` brings in, so the test
  is registered before them, and their contexts are recorded too. It does nothing more when
  `using` brings it again. A context that a test process creates before its registration (a
  template's `setup` with no `use` in the body) makes the registration raise, with that fix. A
  context created outside a test (in `setup_all`, in a module without `use PlaywrightEx.Test`,
  on a driver you started yourself) gets no defaults and no recording.

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
  `PlaywrightEx.APIRequest.new_context/2` left are disposed; a context closed earlier keeps its
  artifacts. Each test writes to its own dir under `output_dir`, named as upstream's
  `testInfo.outputDir` (`checkout-pays-1a2b3` for the test "pays" in `test/checkout_test.exs`,
  the suffix a hash of the module and its `parameterize:` parameters):

    * `trace.zip` - one trace of all its contexts, their `request`s and its request contexts
      (`PlaywrightEx.APIRequest.new_context/2`), recorded with screenshots, snapshots and
      sources unless the trace's options say otherwise. A failed test that keeps one prints
      `mix playwright_ex.cli show-trace <path>`.
    * `test-finished-N.png`, or `test-failed-N.png` for a failed test - a screenshot of every
      page open at the end of the test's body (before its `on_exit` callbacks), then of those
      open when their context closes (`timeout: 5000, caret: :initial`, as upstream).
    * `video.webm`, `video-1.webm`, ... - every page's video. A context created with its own
      `record_video` keeps it, and its video is copied here too.
    * `error-context.md` - a failed test's errors, source and an aria snapshot (`mode: :ai`) of
      the first page of the first context closed after the failure (upstream's `didFinishTest`
      and `buildErrorContext`), whatever the modes.

  The modes are config, and tags over it (a test's `@tag` over its `@describetag` over the
  module's `@moduletag` over the config): `trace` `:off` (default), `:on` or
  `:retain_on_failure`, `screenshot` `:off`, `:on` or `:only_on_failure`, `video` `:off`, `:on`
  or `:retain_on_failure`, and `true` (`:on`) or `false` (`:off`). Each is also the `:mode` of a
  keyword list (or map) of options, as upstream's object forms: `trace: [mode: :on, snapshots:
  false]`, `screenshot: [mode: :on, full_page: true]`, `video: [mode: :on, size: %{width: 640,
  height: 480}]`. The trace's `:snapshots` (a boolean or `%{dom: _, aria: _, screen: _}`),
  `:screenshots` and `:sources` are `PlaywrightEx.Tracing.start/2`'s, `true` by default, as is
  `:attachments` (those of `attach/2` in `trace.zip`); the
  screenshot's `:full_page` and `:omit_background` are `PlaywrightEx.Page.screenshot/2`'s; the
  video's `:size` and `:fps` are `record_video`'s, and its `:show` is upstream's map:
  `%{actions: _}` is `record_video`'s `showActions`, `%{test: %{level: _, position: _, fontSize:
  _}}` overlays the test's title and its steps' (`level` `"file"`, `"title"` or `"step"`) on
  each page of its contexts. So `trace`, `screenshot` and `video` are reserved tags: a
  `@tag :screenshot` label turns screenshots on, and an invalid value raises at registration.

  The `*_on_failure` modes record every test and keep the files of failed ones, as upstream
  (files you write to `output_path/1` stay). A failing artifact step is logged; the test's
  result stands. Nothing is deleted at the start of a run, so `mix test || TRACE=1 mix test
  --failed` (with `trace: :on` under `TRACE`) keeps the first run's files. Delete `output_dir`
  yourself. Playwright Test's retry modes (`on-first-retry`, ...) are not supported: ExUnit has
  no retries.

  ## Context defaults

  Every context and request context a test creates on a `BrowserPool` browser
  (`PlaywrightEx.Browser.new_context/2`, `PlaywrightEx.BrowserType.launch_persistent_context/3`,
  `PlaywrightEx.APIRequest.new_context/2`) gets Playwright Test's context defaults (`locale:
  "en-US"`, a 1280x720 viewport, `color_scheme: :light`, ...), then the config's
  `context_options` over them, for each option the call doesn't give, as upstream's
  `_combinedContextOptions`. An option given as `nil` keeps the client's default; `viewport:
  :null` is none. An option replaces the default as a whole (`extra_http_headers` too, as
  upstream's shallow spread).

  ## Timeouts

  As in Playwright Test, a test's contexts have no action or navigation timeout by default: the
  test's timeout bounds them. Config `action_timeout` and `navigation_timeout` (upstream's
  `actionTimeout`, `navigationTimeout`; milliseconds, `:infinity` by default) set each context's
  `PlaywrightEx.BrowserContext.set_default_timeout/2` and `set_default_navigation_timeout/2`
  (`navigation_timeout` alone governs navigations), and the action timeout is a request
  context's `timeout`, when the call gives none.

  Shortly before ExUnit's timeout (1 s before, at most 5% of the timeout), the test's open
  contexts are closed with upstream's reason, "Test timeout of 60000ms exceeded.": a call that
  hangs until then fails with that message and its call log, after the close kept the artifacts.
  A test stuck elsewhere (`Process.sleep/1`, a `receive`) still fails with ExUnit's
  `ExUnit.TimeoutError`. The timeout is ExUnit's: the `@tag timeout:` (`:infinity` for none) or
  `mix test --timeout`; `mix test --trace` has none. `setup_all` is not covered.

  ## Snapshots

  In a test, `PlaywrightEx.Expect.to_have_screenshot/2` and
  `PlaywrightEx.Expect.to_match_aria_snapshot/3` take upstream's `name:` and resolve it as
  `testInfo` does, by upstream's default templates:

    * screenshots: `{snapshotDir}/{testFileDir}/{testFileName}-snapshots/{arg}{-snapshotSuffix}{ext}`,
      `test/checkout_test.exs-snapshots/home-darwin.png` for `name: "home.png"` in
      `test/checkout_test.exs`.
    * aria snapshots: `{snapshotDir}/{testFileDir}/{testFileName}-snapshots/{arg}{ext}`.

  Without a name, a snapshot is named after the test and its count in the test:
  `pays-1-<platform>.png` for a screenshot, `pays-1.aria.yml` for an aria snapshot.
  A name is sanitized for the file system, a list of path segments is not. `snapshot_dir` is
  `test/` by default; `snapshot_path_template` (or the matcher's `pathTemplate` in `config
  :playwright_ex, :expect`) takes upstream's tokens: `{testDir}`, `{snapshotDir}`,
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

  `step/3` is upstream's `test.step`: `PlaywrightEx.Test.step "log in" do ... end`, or
  `step(title, fun, options)` for wrappers, with upstream's `box`, `location`, `params` and
  `subtitle` (`step_skip/3` is `test.step.skip`). Each matcher call in a test is a step too
  (`category: 'expect'`), and a soft one's failure (`PlaywrightEx.Expect.soft/1`, upstream's
  `expect.soft`) fails the test at the end of its body, as a written snapshot does. The trace's
  `test.trace` entry (upstream's `TestTracing`) has the steps, nested by the step they run in,
  and the test's errors, so `trace: :on` gives a `trace.zip` also for a test without contexts.
  `attach/2` adds a `test.attach` step with the attachment (the trace's `attachments: false`
  leaves the attachments out). Not ported: the test's stdout and stderr in the trace, steps of
  the driver calls (`pw:api`: the calls stay top-level in the trace, a matcher's `Frame.expect`
  call apart from its step), hooks and fixtures as steps, the step's `TestStepInfo` (the body
  takes no argument, so no `step.attach`) and its `timeout` (the test's timeout bounds a step).

  ## Config

      config :playwright_ex, :test,
        browser_name: :chromium,      # BrowserPool: :chromium | :firefox | :webkit
        launch_options: [],           # BrowserPool: PlaywrightEx.BrowserType.launch/2
        connect_options: nil,         # BrowserPool: [ws_endpoint: _, ...] to connect instead of launching
        driver: [],                   # BrowserPool: PlaywrightEx.Supervisor's :env, :executable, :node, :cache_dir
        on_start: nil,                # BrowserPool
        workers: max(div(System.schedulers_online(), 2), 1),
        context_options: [],          # PlaywrightEx.Browser.new_context/2, over the defaults
        action_timeout: :infinity,    # ms, each context's default (and navigation_timeout's)
        navigation_timeout: :infinity,
        trace: :off,                  # :off | :on | :retain_on_failure, or [mode: _, ...]
        screenshot: :off,             # :off | :on | :only_on_failure, or [mode: _, ...]
        video: :off,                  # :off | :on | :retain_on_failure, or [mode: _, size: _]
        output_dir: "test-results",
        snapshot_dir: nil,            # upstream's testDir: test/
        snapshot_path_template: nil,  # upstream's defaults, see Snapshots
        test_id_attribute: "data-testid"

  The artifact modes are `off` by default and `output_dir` is `test-results`, as upstream's.
  `workers` is half the schedulers, as upstream's default `workers` is half the cores (`'50%'`).
  `test_id_attribute` is upstream's `testIdAttribute`, set on each pooled driver: the client's
  value is global to the VM, so set it here, not per module. `config/0` returns the config
  resolved.
  """

  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.Results
  alias PlaywrightEx.Test.TestInfo

  require Logger

  # Set while `__passed__/0` raises the errors `TestInfo` recorded (and traced) already.
  @reraised {__MODULE__, :reraised}
  # `info/0`'s fields of the registration.
  @info_keys [:test_pid, :file, :test_name, :output_dir]

  defmacro __using__(opts) do
    if opts != [] do
      raise ArgumentError,
            "use PlaywrightEx.Test takes no options, got: #{Macro.to_string(opts)}; the recording modes are " <>
              "config and tags (`@tag trace: :on`), the browser's options BrowserPool's"
    end

    macros = __CALLER__.macros

    cond do
      # A test module, also when `use PlaywrightEx.Test` came before (from a template's `using`):
      # its import replaced ExUnit.Case's `test`.
      {:test, 3} in Keyword.get(macros, ExUnit.Case, []) or {:test, 3} in Keyword.get(macros, __MODULE__, []) ->
        quote do
          import ExUnit.Case, only: [describe: 2]
          import PlaywrightEx.Test, only: [test: 1, test: 2, test: 3]
          require PlaywrightEx.Test

          if PlaywrightEx.Test.__use__(__MODULE__), do: setup({PlaywrightEx.Test, :__setup__})
        end

      # The body of a case template: its `setup` callbacks run before those of its `using`.
      {:using, 1} in Keyword.get(macros, ExUnit.CaseTemplate, []) ->
        quote do
          if PlaywrightEx.Test.__use__(__MODULE__), do: setup({PlaywrightEx.Test, :__setup__})
        end

      true ->
        raise CompileError,
          file: __CALLER__.file,
          line: __CALLER__.line,
          description: "use PlaywrightEx.Test must come after use ExUnit.Case (or in a case template's body or using)"
    end
  end

  @doc false
  # `true` on a module's first `use PlaywrightEx.Test`, as `ExUnit.Case.__register__/2` sets up
  # a module once: a template's `using` and the module itself may both bring it.
  def __use__(module) do
    if Module.has_attribute?(module, :playwright_ex_test) do
      false
    else
      Module.put_attribute(module, :playwright_ex_test, true)
      true
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

    passed = quote(do: PlaywrightEx.Test.__passed__())

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
          {kind, reason, stacktrace} = PlaywrightEx.Test.__failed__(kind, reason, __STACKTRACE__)
          :erlang.raise(kind, reason, stacktrace)
      end

    # ExUnit's breakpoints break the `catch` clauses (they are annotated as a block).
    contents =
      if Application.get_env(:ex_unit, :breakpoints, false),
        do: [do: block],
        else: [do: block, catch: failed]

    quote do
      @tag playwright_ex: :marked
      ExUnit.Case.test(unquote(message), unquote(var), unquote(contents))
    end
  end

  @doc "`ExUnit.Case.test/1`: a test that fails as not implemented."
  defmacro test(message) do
    quote do
      @tag playwright_ex: :marked
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
    with %{screenshot: [{:mode, mode} | _]} <- Recorder.registration(self()),
         true <- mode == :on or (mode == :only_on_failure and failed?),
         recorder when is_pid(recorder) <- Recorder.lookup(self()),
         do: Recorder.capture(recorder, failed?)

    :ok
  catch
    # The recorder is gone: the test's own result and failure stand.
    :exit, _ -> :ok
  end

  @doc false
  # The per-test `setup` of `use PlaywrightEx.Test`: registers the test, once (a case
  # template's body and its `using` may both bring it).
  def __setup__(%{test_pid: test_pid} = context) do
    Pool.ensure_started()

    cond do
      Recorder.registration(test_pid) ->
        :ok

      :ets.take(Results.table(), {:unregistered, test_pid}) != [] ->
        raise ArgumentError,
              "this test created a context before `use PlaywrightEx.Test` registered it (a case template's " <>
                "`setup` runs before the `use` in its `using`), so the context has no defaults and no " <>
                "recording: add `use PlaywrightEx.Test` as the first line of the case template's body"

      true ->
        test = __register__(context)
        timeout = test.test_timeout
        # Each `on_exit` callback gets the test's timeout: half of it for the artifacts.
        budget = if is_integer(timeout), do: div(timeout, 2), else: :infinity
        ExUnit.Callbacks.on_exit(fn -> __finish__(test.test_pid, budget) end)
        :ok
    end
  end

  @doc false
  # The registration of the test of `context` (its `test_pid`), without its `on_exit`.
  def __register__(context) do
    modes = Options.artifacts(context)
    file = context.file
    marked? = context[:playwright_ex] == :marked
    timeout = test_timeout(context)

    test =
      context
      |> TestInfo.new()
      |> Map.merge(modes)
      |> Map.merge(%{
        title: "#{Path.relative_to_cwd(file)}:#{context[:line]} › #{TestInfo.test_name(context)}",
        title_path: TestInfo.title_path(context),
        location: {file, context[:line]},
        test_timeout: timeout,
        # ExUnit's clock started at the test process's spawn, just before this setup.
        deadline: if(is_integer(timeout), do: System.monotonic_time(:millisecond) + timeout),
        context_options: Options.context_options(),
        timeouts: Options.timeouts(),
        tmp: Path.join(System.tmp_dir!(), "playwright_ex-test-#{System.unique_integer([:positive])}")
      })

    # The failure of a marked test that raised nothing in its body.
    failure = if context[:not_implemented], do: "Not implemented", else: Results.outside()
    Results.watch(test.test_pid, marked? && failure)
    :ets.insert(Results.table(), {{:test, test.test_pid}, test})
    if marked?, do: TestInfo.start(test)
    # The steps of `test.trace` go to the recorder.
    if modes.trace[:mode] != :off, do: Results.recorder(test.test_pid)
    test
  end

  # ExUnit's `get_timeout/2`: none under `--trace`, else the test's `timeout` tag or the config's.
  defp test_timeout(context) do
    config = ExUnit.configuration()
    if config[:trace], do: :infinity, else: Map.get(context, :timeout, config[:timeout])
  end

  @doc false
  # The test's end, its first `on_exit`, so it runs last: its artifacts by its result, then the
  # release of its pooled drivers.
  def __finish__(test_pid, budget) do
    {verdict, failures} = result = Results.result(test_pid, budget)
    {test, recorder} = Results.take(test_pid)
    # For `info/1` in the `on_exit` callbacks that run after this one.
    Results.keep_info(test_pid, Map.merge(Map.take(test, @info_keys), result_info(test_pid, result, recorder)))

    trace =
      cond do
        recorder ->
          Recorder.finish(recorder, result, budget)

        verdict == :failed ->
          ErrorContext.write(test, failures)
          nil

        true ->
          nil
      end

    # The list reporter's `npx playwright show-trace <path>`.
    if verdict == :failed and trace,
      do:
        IO.puts(
          "\nTrace of #{inspect(test.test_name)}: mix playwright_ex.cli show-trace #{Path.relative_to_cwd(trace)}"
        )
  rescue
    exception -> Logger.warning("PlaywrightEx.Test could not finish the test: " <> Exception.message(exception))
  after
    Pool.release(test_pid)
    Results.forget(test_pid)
  end

  @doc """
  The running test of the calling process or a process in its `$callers` (a `Task`), as
  upstream's `test.info()`: `test_pid`, `file` (absolute), `test_name` (without the macro's
  `test ` prefix) and `output_dir` (absolute, see "Artifacts" in the moduledoc), from the
  test's setup to the end of its body. Raises outside a test, and in `on_exit` callbacks (ExUnit
  runs them in a process of their own): there, use `info/1`.

      PlaywrightEx.Test.info().test_pid
  """
  @spec info() :: %{test_pid: pid(), file: Path.t(), test_name: String.t(), output_dir: Path.t()}
  def info do
    case Recorder.registration() do
      nil ->
        raise "PlaywrightEx.Test.info() can only be called while a test is running: in a test of a module with " <>
                "`use PlaywrightEx.Test` (its process, or one with it in $callers)"

      test ->
        Map.take(test, @info_keys)
    end
  end

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
          if PlaywrightEx.Test.info(test_pid).status != :passed, do: ...
        end)
      end
  """
  @spec info(pid()) :: map()
  def info(test_pid) when is_pid(test_pid) do
    case Recorder.registration(test_pid) do
      nil ->
        case Results.started?() && :ets.lookup(Results.table(), {:info, test_pid}) do
          [{_key, info}] -> info
          _ -> raise ArgumentError, "PlaywrightEx.Test.info/1: no test #{inspect(test_pid)} running or in its on_exit"
        end

      test ->
        info = Map.take(test, @info_keys)

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
  The resolved `config :playwright_ex, :test` (see "Config" in the moduledoc), for libraries
  that build on the runner: a map of every key, with its default filled in and its value
  validated, as the runner reads it. The recording modes are keyword lists with `:mode` first
  (`trace: [mode: :off, snapshots: true, ...]`), `context_options` are as configured (without
  Playwright Test's context defaults), and an unset `action_timeout` or `navigation_timeout` is
  `:infinity`. `expect: %{timeout: ms}` is the matchers' timeout of `config :playwright_ex,
  :expect` (5000 by default, `0` for none). Works outside a test too (at startup, in a module
  without `use PlaywrightEx.Test`); raises `ArgumentError` for an invalid config.

      PlaywrightEx.Test.config().workers
  """
  @spec config() :: map()
  def config do
    config = Options.config()
    # Validated as the registration converts them for `PlaywrightEx.Browser.new_context/2`.
    Options.context_options()
    Map.put(config, :expect, %{timeout: PlaywrightEx.Matchers.Expect.config_timeout()})
  end

  @doc """
  The path of `name` in the test's output dir (see "Artifacts" in the moduledoc), as upstream's
  `testInfo.outputPath`: creates the dir, and raises for a `name` outside it. Files written
  there stay when the test passes.
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

      PlaywrightEx.Test.attach("screenshot", body: Page.screenshot!(page), content_type: "image/png")
  """
  @spec attach(String.t(), keyword()) :: :ok
  def attach(name, options \\ []) when is_binary(name) do
    options = Keyword.validate!(options, [:path, :body, :content_type])
    test_info = TestInfo.current() || raise "PlaywrightEx.Test.attach/2 can only be called while a test is running"
    TestInfo.attach(test_info, name, %{path: options[:path], body: options[:body], contentType: options[:content_type]})
  end

  @doc """
  The snapshot path of `name` for the running test, as upstream's `testInfo.snapshotPath`:
  where `PlaywrightEx.Expect.to_have_screenshot/2` (`kind: :screenshot`) and
  `PlaywrightEx.Expect.to_match_aria_snapshot/3` (`kind: :aria`) with `name:` read and write it
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
      PlaywrightEx.Test._step(unquote(expectation), unquote(title), unquote(body), unquote(options), unquote(call_site))
    end
  end

  defp do_block?(ast), do: is_list(ast) and Keyword.keyword?(ast) and Keyword.has_key?(ast, :do)

  # `rescue`, `catch`, `after`, `else` as in a `def`.
  defp step_fn(do: block), do: quote(do: fn -> unquote(block) end)
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
