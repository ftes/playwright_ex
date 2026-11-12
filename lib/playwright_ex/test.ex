defmodule PlaywrightEx.Test do
  @moduledoc """
  ExUnit setup fragments for browser tests: a shared browser, a context and page per test, and
  traces, screenshots and videos of failures.

      # config/test.exs
      config :playwright_ex, :test, trace: :retain_on_failure, screenshot: :only_on_failure

      defmodule MyApp.CheckoutTest do
        use ExUnit.Case, async: true
        use PlaywrightEx.Test

        setup_all :browser
        setup [:new_context, :new_page]

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

  `use PlaywrightEx.Test` comes after `use ExUnit.Case` (or in a case template's `using`). It
  imports the fragments and a `test` macro that hands the test to `ExUnit.Case.test/3` with the
  body's end marked, so the module's `on_exit` callbacks learn whether the test passed: the
  artifacts of passing tests are dropped, and a module's isolated driver is checked in only if a
  test of it ran and all passed. Tests of other macros (doctests, a `property`) count as failed
  for their artifacts, and a failure only in an `on_exit` callback counts as passed. Its
  `setup_all` registers the module's end first, so it runs after the module's other `setup_all`
  `on_exit` callbacks, except those of a case template's `setup_all` before it: clean up what
  you made on an isolated driver in a test's `on_exit`.

  Each fragment reads the context map and returns new keys, `browser/1` → `%{browser: _}` →
  `new_context/1` → `%{context: _}` → `new_page/1` → `%{page: _}`, so any of them can be
  replaced by your own code: a `setup_all` that returns `%{browser: _}` of a browser you
  connected to works with `new_context/1`. Called with the context map, a fragment takes its
  options from `config :playwright_ex, :test`; called with options, they are merged over the
  config (`launch_options`, `context_options` and `driver` one level deep). Unknown options and
  bad values raise `ArgumentError`. In a `parameterize:` module, call the fragments before any
  setup that rebinds a parameter key.

  ## Browsers

  `browser/1` returns a shared browser per `browser_name` and `launch_options`, on a driver
  shared per `driver` and `on_start`, launched on first use and again if lost. A module that
  changes the driver or browser for everyone takes `isolate: true`: a driver of its own, taken on
  the module's first `browser(context, isolate: true)` (in `setup_all`, a test, or a process
  given the test's context map), as upstream's worker-scoped `browser` fixture is lazy. The
  module holds it until its end; it is checked in for the next module if a test of it ran and
  all passed, else discarded. At most `workers` isolated drivers run at once, as upstream's
  worker processes (all exclusive): with every one in use, a module waits, unless it holds a
  driver already.

  Firefox serializes input (mouse, keyboard) across all pages of a browser, so concurrent modules
  on a shared Firefox slow each other down: use `isolate: true` when the run is Firefox, or `use
  ExUnit.Case, group: :firefox` for a few Firefox modules (a group's modules never run at once).
  Every driver stops after the suite.

  ## Artifacts

  `record_artifacts/2` records every context the test creates: with `new_context/2`, with
  `PlaywrightEx.Browser.new_context/2` in the test or in a `Task` of it, and with
  `new_context/2` from any other process given the test's context map (a GenServer that
  creates contexts for the test). Each test writes to its own dir under `output_dir`, named as
  upstream's `testInfo.outputDir` (`checkout-pays-1a2b3` for the test "pays" in
  `test/checkout_test.exs`, the suffix a hash of the module and its `parameterize:` parameters):

    * `trace.zip` - one trace of all its contexts (`mix playwright_ex.cli show-trace <path>`),
      recorded with screenshots, snapshots and sources unless the trace's options say otherwise.
    * `test-finished-N.png`, or `test-failed-N.png` for a failed test - a screenshot of every
      page open at the end of the test's body (before its `on_exit` callbacks), then of those
      open when their context closes (`timeout: 5000, caret: :initial`, as upstream).
    * `video.webm`, `video-1.webm`, ... - every page's video. A context created with its own
      `record_video` keeps it, and its video is copied here too.
    * `error-context.md` - a failed test's errors, source and an aria snapshot (`mode: :ai`) of
      the first page of the first context closed after the failure (upstream's `didFinishTest`
      and `buildErrorContext`).

  Each mode is also the `:mode` of a keyword list (or map) of options, as upstream's object
  forms: `trace: [mode: :on, snapshots: false]`, `screenshot: [mode: :on, full_page: true]`,
  `video: [mode: :on, size: %{width: 640, height: 480}]`. `:mode` is required. The trace's
  `:snapshots` (a boolean or `%{dom: _, aria: _, screen: _}`), `:screenshots` and `:sources` are
  `PlaywrightEx.Tracing.start/2`'s, `true` by default; the screenshot's `:full_page` and
  `:omit_background` are `PlaywrightEx.Page.screenshot/2`'s; the video's `:size` is
  `record_video`'s.

  The `*_on_failure` modes record every test and keep the files of failed ones, as upstream
  (files you write to `output_path/2` stay). A failing artifact step is logged; the test's
  result stands. Nothing is deleted at the start of a run, so `mix test || TRACE=1 mix test
  --failed` (with `trace: :on` under `TRACE`) keeps the first run's files. Delete `output_dir`
  yourself.

  A trace of your own (`PlaywrightEx.Tracing.start/2` with `sources: true`) on a shared driver
  also gets concurrent tests' stacks and sources: the driver adds every call's stack to each
  trace on the connection. `record_artifacts/2` filters its own; yours needs `isolate: true`.

  ## Snapshots

  In a test (its process, or a process with it in `$callers`), `PlaywrightEx.Expect.to_have_screenshot/2`
  and `PlaywrightEx.Expect.to_match_aria_snapshot/3` take upstream's `name:` and resolve it as
  `testInfo` does, by upstream's default templates:

    * screenshots: `{snapshotDir}/{testFileDir}/{testFileName}-snapshots/{arg}{-projectName}{-snapshotSuffix}{ext}`,
      `test/checkout_test.exs-snapshots/home-darwin.png` for `name: "home.png"` in
      `test/checkout_test.exs`.
    * aria snapshots: `{snapshotDir}/{testFileDir}/{testFileName}-snapshots/{arg}{ext}`.

  Without a name, a snapshot is named after the test and its count in the test:
  `pays-1-<platform>.png` for a screenshot, `pays-1.aria.yml` for an aria snapshot.
  A name is sanitized for the file system, a list of path segments is not. `snapshot_dir` is
  `test/` by default; `snapshot_path_template` (or the matcher's `pathTemplate` in `config
  :playwright_ex, :expect`) takes upstream's tokens: `{testDir}`, `{snapshotDir}`,
  `{testFileDir}`, `{testFileName}`, `{testFileBaseName}`, `{testFilePath}`, `{testName}`,
  `{arg}`, `{ext}`, `{platform}`, `{snapshotSuffix}` (the platform, as upstream's) and
  `{projectName}`, which is empty: there are no projects. `snapshot_path/3` returns a name's path.
  A failed comparison writes its `-actual`, `-expected`, `-previous` and `-diff` images to the
  test's output dir.

  A snapshot the matcher writes (a missing one, under the default `update_snapshots`) fails the
  test at the end of its body, as upstream's soft error: the rest of the body runs, and ExUnit
  reports all of the test's errors, also when another failure follows. `path:` in place of
  `name:` is the snapshot file itself, also outside a test, where a written snapshot is printed.

  ## Steps

  `step/3` is upstream's `test.step`: `step "log in" do ... end`, or `step(title, fun,
  options)` for wrappers, with upstream's `box`, `location`, `timeout`, `params` and `subtitle`
  (`step_skip/3` is `test.step.skip`). Each matcher call in a test is a step too
  (`category: 'expect'`), and a soft one's failure (`PlaywrightEx.Expect.soft/1`, upstream's
  `expect.soft`) fails the test at the end of its body, as a written snapshot does. The trace's
  `test.trace` entry (upstream's `TestTracing`) has the steps, nested by the step they run in,
  and the test's errors, so `trace: :on` gives a `trace.zip` also for a test without contexts. Not ported: the test's stdout and stderr in
  the trace, steps of the driver calls (`pw:api`: the calls stay top-level in the trace, a
  matcher's `Frame.expect` call apart from its step), hooks and fixtures as steps, attachments
  and the step's `TestStepInfo` (the body takes no argument).

  ## Config

      config :playwright_ex, :test,
        browser_name: :chromium,      # :chromium | :firefox | :webkit
        launch_options: [],           # PlaywrightEx.BrowserType.launch/2
        driver: [],                   # PlaywrightEx.Supervisor: :env, :executable, :node, :cache_dir
        on_start: nil,
        context_options: [],          # PlaywrightEx.Browser.new_context/2
        trace: :off,                  # :off | :on | :retain_on_failure, or [mode: _, ...]
        screenshot: :off,             # :off | :on | :only_on_failure, or [mode: _, ...]
        video: :off,                  # :off | :on | :retain_on_failure, or [mode: _, size: _]
        output_dir: "test-results",
        workers: max(div(System.schedulers_online(), 2), 1),
        snapshot_dir: nil,            # upstream's testDir: test/
        snapshot_path_template: nil   # upstream's defaults, see Snapshots

  The artifact modes are `off` by default and `output_dir` is `test-results`, as upstream's.
  `workers` is half the schedulers, as upstream's default `workers` is half the cores (`'50%'`).
  """

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.TestInfo

  # `{recorder, screenshot mode}`, once the test process called `record_artifacts/2`.
  @recording {__MODULE__, :recording}
  # The module's token in its `setup_all` process, for fragments that run before ours.
  @token {__MODULE__, :module}
  # Set while `__passed__/0` raises the errors `TestInfo` recorded (and traced) already.
  @reraised {__MODULE__, :reraised}

  defmacro __using__(opts) do
    if opts != [] do
      raise ArgumentError,
            "use PlaywrightEx.Test takes no options, got: #{Macro.to_string(opts)}; " <>
              "pass them to browser/2, new_context/2 or record_artifacts/2"
    end

    if __CALLER__.module && Module.has_attribute?(__CALLER__.module, :playwright_ex_test) do
      :ok
    else
      if {:test, 3} not in Keyword.get(__CALLER__.macros, ExUnit.Case, []) do
        raise CompileError,
          file: __CALLER__.file,
          line: __CALLER__.line,
          description: "use PlaywrightEx.Test must come after use ExUnit.Case (or in a case template's using)"
      end

      quote do
        @playwright_ex_test true
        import ExUnit.Case, only: [describe: 2]

        import PlaywrightEx.Test,
          only: [
            test: 1,
            test: 2,
            test: 3,
            browser: 1,
            browser: 2,
            record_artifacts: 1,
            record_artifacts: 2,
            new_context: 1,
            new_context: 2,
            new_page: 1,
            output_path: 2,
            snapshot_path: 2,
            snapshot_path: 3,
            step: 2,
            step: 3,
            step_skip: 2,
            step_skip: 3
          ]

        @doc false
        def __playwright_ex_test__, do: true

        setup_all {PlaywrightEx.Test, :__setup_all__}
        setup {PlaywrightEx.Test, :__setup__}
      end
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

  @doc false
  def __setup_all__(context), do: %{playwright_ex_module: token!(context, "use PlaywrightEx.Test")}

  @doc false
  def __setup__(context) do
    watch(context)
    if context[:playwright_ex] == :marked, do: TestInfo.start(context)
    :ok
  end

  # The end of the body: the test fails with the errors its matchers recorded (upstream's
  # `testInfo.errors`), raised as ExUnit reports them. They are reported here, not by
  # `__failed__/3`, which `--breakpoints` leaves out.
  @doc false
  def __passed__ do
    case TestInfo.finish(self()) do
      [] ->
        Pool.notify({:passed, self()})
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
        do: Pool.notify({:failed, self(), {kind, Exception.normalize(kind, reason, stacktrace), stacktrace}})
  end

  # Each error of an `ExUnit.MultiError` (upstream's `_failWithError` visits an error's `errors`).
  defp errors({kind, reason, stacktrace}), do: errors(kind, reason, stacktrace)
  defp errors(:error, %ExUnit.MultiError{errors: errors}, _stacktrace), do: errors
  defp errors(kind, reason, stacktrace), do: [{kind, reason, stacktrace}]

  # `didFinishTestFunction`: screenshots of the open pages, before the `on_exit` callbacks.
  defp finished_test_function(failed?) do
    with {recorder, mode} <- Process.get(@recording),
         true <- mode == :on or (mode == :only_on_failure and failed?),
         do: Recorder.capture(recorder, failed?)

    :ok
  catch
    # The recorder is gone: the test's own result and failure stand.
    :exit, _ -> :ok
  end

  @doc """
  A browser for the module, for `setup_all` or a test: returns `playwright`, `browser_name` and
  `browser`.

  Takes the context map (`setup_all :browser`, options from the config) or options, also as
  `browser(context, options)`:

    * `:browser_name` - `:chromium` (default), `:firefox` or `:webkit`.
    * `:launch_options` - for `PlaywrightEx.BrowserType.launch/2`, as is.
    * `:driver` - options of the driver's `PlaywrightEx.Supervisor`: `:env`, `:executable`,
      `:node`, `:cache_dir`.
    * `:on_start` - a function of the Playwright (`PlaywrightEx.Playwright`) or `{m, f, args}`
      (called with the Playwright first), run once on each new driver before its browser
      launches: `&MyApp.Selectors.register/1`. Part of the driver's key, so pass a capture, not
      a closure.
    * `:isolate` - `true` gives the module a driver of its own per `driver` and `on_start`, held
      until the module ends (see the moduledoc); other browsers launch on it. An argument, not
      config: needs the context map, `browser(context, isolate: true)`.

  A second call with other options returns another browser: a second user on Firefox is
  `%{browser: firefox} = browser(browser_name: :firefox)`.
  """
  @spec browser(map() | keyword()) :: %{playwright: struct(), browser_name: atom(), browser: Browser.t()}
  def browser(context_or_options)
  def browser(context) when is_map(context), do: browser(context, [])
  def browser(options) when is_list(options), do: browser(%{}, options)

  @doc "`browser/1` with the context map and options."
  @spec browser(map(), keyword()) :: %{playwright: struct(), browser_name: atom(), browser: Browser.t()}
  def browser(context, options) when is_map(context) and is_list(options) do
    opts = Options.browser(options)

    token =
      cond do
        opts.isolate -> token!(context, "browser(context, isolate: true)")
        context[:module] -> token!(context, "browser/1")
        true -> nil
      end

    %{playwright: playwright, browser: browser} = Pool.browser(opts, token)
    %{playwright: playwright, browser_name: opts.browser_name, browser: browser}
  end

  @doc """
  Records the artifacts of every context the test creates, for `setup`; see the moduledoc.

  Takes the test's context map (`module`, `test`, `file`; `browser` or `playwright` to record
  plain `PlaywrightEx.Browser.new_context/2` calls) and the options, merged over the config:

    * `:trace` - `:off` (default), `:on` or `:retain_on_failure`, or
      `[mode: _, snapshots: _, screenshots: _, sources: _]`.
    * `:screenshot` - `:off` (default), `:on` or `:only_on_failure`, or
      `[mode: _, full_page: _, omit_background: _]`.
    * `:video` - `:off` (default), `:on` or `:retain_on_failure`, or `[mode: _, size: _]`.

  Each of them replaces the config's value as a whole (`launch_options` and the other option
  lists merge one level deep). With all three `:off` it only writes `error-context.md` of a
  failure. `new_context/2` calls it
  with the config if the test hasn't.
  """
  @spec record_artifacts(map(), keyword()) :: :ok
  def record_artifacts(context, options \\ []) when is_map(context) do
    opts = Options.artifacts(options)
    for key <- [:module, :test], do: fetch!(context, key)
    file = fetch!(context, :file)
    watch(context)
    if Process.get(@recording), do: raise(ArgumentError, "record_artifacts was called already for this test")

    # Not emptied: files are overwritten by name, so a rerun keeps the first run's other files.
    dir = Recorder.output_dir(context)
    title = "#{Path.relative_to_cwd(file)}:#{context[:line]} › #{Recorder.test_name(context)}"

    recorder =
      Recorder.start(
        self(),
        Map.merge(opts, %{
          dir: dir,
          title: title,
          title_path: Recorder.title_path(context),
          location: {file, context[:line]},
          test_timeout: test_timeout(context)
        })
      )

    # Each `on_exit` callback gets the test's timeout: half of it for the artifacts.
    budget =
      with timeout when is_integer(timeout) <- test_timeout(context),
           do: div(timeout, 2)

    ExUnit.Callbacks.on_exit(fn -> Recorder.finish(recorder, budget) end)
    Process.put(@recording, {recorder, opts.screenshot[:mode]})

    channel = context[:browser] || context[:playwright]
    if channel, do: Recorder.ensure_listener(recorder, Heap.get(channel, :_instrumentation))
    :ok
  end

  @doc """
  A context of `context.browser` for the test, for `setup`: returns `context`.

  Option: `:context_options` for `PlaywrightEx.Browser.new_context/2`, as is (merged over the
  config's). Starts `record_artifacts/2` with the config if the test hasn't, which closes the
  context after the test.

  The context map needs `browser`. Its `test_pid` picks the recording, so a process that creates
  contexts for a test (a GenServer) passes the test's whole context map, once the test's `setup`
  has called `record_artifacts/2`. Without `test_pid` (in `setup_all`, as upstream's `newContext`
  in `beforeAll`) nothing records or closes the context: close it yourself.
  """
  @spec new_context(map(), keyword()) :: %{context: BrowserContext.t()}
  def new_context(context, options \\ []) when is_map(context) do
    opts = Options.context(options)
    browser = fetch!(context, :browser)

    case context[:test_pid] do
      nil ->
        %{context: Browser.new_context!(browser, opts.context_options)}

      test_pid ->
        token!(context, "new_context/2")
        if test_pid == self() and Process.get(@recording) == nil, do: record_artifacts(context)
        recorder = Recorder.lookup(test_pid)
        if recorder, do: Recorder.ensure_listener(recorder, Heap.get(browser, :_instrumentation))
        %{context: Recorder.with_identity(test_pid, fn -> Browser.new_context!(browser, opts.context_options) end)}
    end
  end

  @doc """
  The path of `name` in the test's output dir (see the moduledoc), as upstream's
  `testInfo.outputPath`: creates the dir, and raises for a `name` outside it. The context map
  needs `module`, `test` and `file`. Files written there stay when the test passes.
  """
  @spec output_path(map(), Path.t()) :: Path.t()
  def output_path(context, name) when is_map(context) do
    for key <- [:module, :test, :file], do: fetch!(context, key)

    case Path.safe_relative(name) do
      {:ok, relative} ->
        dir = Recorder.output_dir(context)
        File.mkdir_p!(dir)
        Path.join(dir, relative)

      :error ->
        raise ArgumentError, "output_path is not allowed outside of the output dir, got: #{inspect(name)}"
    end
  end

  @doc """
  The snapshot path of `name` for the test, as upstream's `testInfo.snapshotPath`: where
  `PlaywrightEx.Expect.to_have_screenshot/2` (`kind: :screenshot`) and
  `PlaywrightEx.Expect.to_match_aria_snapshot/3` (`kind: :aria`) with `name:` read and write it
  (see "Snapshots" in the moduledoc). `name` is a string, or a list of path segments. Option
  `:kind`: `:snapshot` (default, upstream's), `:screenshot` or `:aria`. The context map needs
  `module`, `test`, `file` and `test_pid`.
  """
  @spec snapshot_path(map(), String.t() | [String.t()], keyword()) :: Path.t()
  def snapshot_path(context, name, options \\ []) when is_map(context) do
    for key <- [:module, :test, :file, :test_pid], do: fetch!(context, key)
    {kind, options} = Keyword.pop(options, :kind, :snapshot)
    if options != [], do: raise(ArgumentError, "unknown options #{inspect(Keyword.keys(options))}, expected [:kind]")
    TestInfo.snapshot_path(TestInfo.new(context), name, to_string(kind))
  end

  @doc "A page of `context.context`, for `setup`: returns `page`."
  @spec new_page(map()) :: %{page: PlaywrightEx.Page.t()}
  def new_page(context) when is_map(context), do: %{page: BrowserContext.new_page!(fetch!(context, :context))}

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
    * `:timeout` - fails the step after this many milliseconds with a `PlaywrightEx.TimeoutError`
      (`:infinity`, the default, or `0` for none). The body then runs in a process of its own
      (with the test in its `$callers`), as a `Task`, so `assert_receive` and `ExUnit.Callbacks`
      don't work in it. After the timeout it keeps running, as upstream's, until the test ends.
    * `:params`, `:subtitle` - shown with the step in the trace.

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
    options = Map.new(Keyword.validate!(options, [:box, :location, :timeout, :params, :subtitle]))
    call_site = call_site || (options[:location] && Map.take(options.location, [:file, :line]))
    test_info = TestInfo.current()
    if !test_info, do: raise("test.step() can only be called from a test")
    # await testInfo._onUserStepBegin?.(title);  -- not ported: UI mode

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
        deadline =
          if options[:timeout] in [nil, 0, :infinity],
            do: 0,
            else: System.monotonic_time(:millisecond) + options.timeout

        result =
          race_against_deadline(&run_step_body(test_info, step, expectation, body, &1), deadline, test_info.test_pid)

        if result.timedOut,
          do: raise(PlaywrightEx.TimeoutError, message: "Step timeout of #{options.timeout}ms exceeded.")

        TestInfo.step_complete(step, %{})
        result.result
      catch
        kind, reason ->
          TestInfo.step_complete(step, %{error: {kind, reason, __STACKTRACE__}})
          # deviation: Elixir errors are immutable, so none carries its step (`stepSymbol`) for
          # `_failWithError` to report a boxed step's stack: the step raises it with that stack,
          # which ExUnit reports.
          :erlang.raise(kind, reason, step.boxedStack || __STACKTRACE__)
      end

      # finally { await testInfo._onUserStepEnd?.(); }  -- not ported: UI mode
    end)
  end

  # The race's body.
  defp run_step_body(test_info, step, expectation, body, timed_out?) do
    TestInfo._run_step_body(step, expectation == :skip, body, List.first(step.stack))
  catch
    kind, reason ->
      # If the step timed out, the test fixtures will tear down, which in turn
      # will abort unfinished actions in the step body. Record such errors here.
      if timed_out?.(), do: TestInfo._fail_with_error(test_info, {kind, reason, __STACKTRACE__})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # isomorphic/timeoutRunner.ts `raceAgainstDeadline`; `cb` gets whether the race timed out.
  # deviation: without a deadline the body runs in the calling process. With one it runs in a
  # process of its own (with the zone and the test in its `$callers`), as a process can't be
  # interrupted: past the deadline the race returns and the body runs on, as upstream's. It is
  # linked to the caller and to the test's process, so it ends with the test even when the
  # caller is a `Task` that outlives it.
  defp race_against_deadline(cb, 0, _test_pid), do: %{result: cb.(fn -> false end), timedOut: false}

  defp race_against_deadline(cb, deadline, test_pid) do
    zone = Zones.current_zone()
    callers = [self() | List.wrap(Process.get(:"$callers"))]
    timed_out = :atomics.new(1, [])
    # Dropped once the race is over.
    reply = :erlang.alias([:reply])

    spawn_link(fn ->
      Process.link(test_pid)
      Process.put(:"$callers", callers)
      Zones.restore(zone)

      result =
        try do
          {:ok, cb.(fn -> :atomics.get(timed_out, 1) == 1 end)}
        catch
          kind, reason -> {:error, kind, reason, __STACKTRACE__}
        end

      send(reply, {reply, result})
    end)

    receive do
      {^reply, {:ok, result}} -> %{result: result, timedOut: false}
      {^reply, {:error, kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        :atomics.put(timed_out, 1, 1)
        :erlang.unalias(reply)

        receive do
          {^reply, _result} -> :ok
        after
          0 -> :ok
        end

        %{timedOut: true}
    end
  end

  # The test's ExUnit timeout.
  defp test_timeout(context), do: context[:timeout] || ExUnit.configuration()[:timeout]

  # The test's result is the pool's: it monitors the test process.
  defp watch(context) do
    token = token!(context, "record_artifacts/2")
    # The failure of a marked test that raised nothing in its body.
    failure = if context[:not_implemented], do: "Not implemented", else: Pool.outside()
    marked? = context[:playwright_ex] == :marked
    Pool.watch(fetch!(context, :test_pid), token, marked? && failure)
  end

  # The module's token: in the context map from our `setup_all`, or from a fragment that runs in
  # the `setup_all` process before it, which starts the module (one per `setup_all`, so per
  # parameter set) and registers its end, the module's last `on_exit`.
  defp token!(context, what) do
    cond do
      token = context[:playwright_ex_module] ->
        token

      context[:test] == nil and uses?(context[:module]) ->
        Process.get(@token) || start_module()

      true ->
        raise ArgumentError,
              "#{what} needs a test module with `use PlaywrightEx.Test`: add it after `use ExUnit.Case` " <>
                "(or in your case template's `using`), and pass the test's context map"
    end
  end

  defp start_module do
    token = Pool.start_module()
    Process.put(@token, token)
    ExUnit.Callbacks.on_exit(fn -> Pool.module_finished(token) end)
    token
  end

  defp uses?(module), do: is_atom(module) and function_exported?(module, :__playwright_ex_test__, 0)

  defp fetch!(context, key) do
    case context do
      %{^key => value} when value != nil -> value
      _ -> raise ArgumentError, "expected #{inspect(key)} in the context map, got keys: #{inspect(Map.keys(context))}"
    end
  end
end
