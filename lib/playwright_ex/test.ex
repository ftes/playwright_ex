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

  Not a port of Playwright Test: these follow the runners of the official non-JS clients
  (pytest-playwright, Playwright.NUnit, Java's `@UsePlaywright`) on ExUnit, with Playwright
  Test's names and defaults where they exist (`packages/playwright/src/index.ts`).

  `use PlaywrightEx.Test` comes after `use ExUnit.Case` (or in a case template's `using`). It
  imports the fragments and a `test` macro that hands the test to `ExUnit.Case.test/3` with the
  body's end marked, so the module's `on_exit` callbacks learn whether the test passed: the
  artifacts of passing tests are dropped, and a failed module's isolated driver is discarded.
  Tests of other macros (doctests, a `property`) count as failed for their artifacts, and a
  failure only in an `on_exit` callback counts as passed.

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
  module holds it until its end, at most `max_isolated` at once, and it is discarded if a test
  failed. Firefox serializes input (mouse, keyboard) across all pages of a browser, so concurrent
  modules on a shared Firefox slow each other down: use `isolate: true` when the run is Firefox,
  or `use ExUnit.Case, group: :firefox` for a few Firefox modules (a group's modules never run at
  once). Every driver stops after the suite.

  ## Artifacts

  `record_artifacts/2` records every context the test creates: with `new_context/2`, with
  `PlaywrightEx.Browser.new_context/2` in the test or in a `Task` of it, and with
  `new_context/2` from any other process given the test's context map (a GenServer that
  creates contexts for the test). Each test writes to its own dir under `output_dir`, named as
  upstream's `testInfo.outputDir` (`checkout-pays-1a2b3` for the test "pays" in
  `test/checkout_test.exs`, the suffix a hash of the module and its `parameterize:` parameters):

    * `trace.zip` - one trace of all its contexts (`mix playwright_ex.cli show-trace <path>`),
      recorded with screenshots, snapshots and sources (upstream's default trace options).
    * `test-finished-N.png`, or `test-failed-N.png` for a failed test - a screenshot of every
      page open when its context closes (`timeout: 5000, caret: :initial`, as upstream).
    * `video.webm`, `video-1.webm`, ... - every page's video. A context created with its own
      `record_video` keeps it, and its video is copied here too.
    * `error-context.md` - a failed test's errors, source and an aria snapshot (`mode: :ai`) of
      the first page of the first context closed after the failure (upstream's `didFinishTest`
      and `buildErrorContext`).

  The `*_on_failure` modes record every test and keep the files of failed ones, as upstream
  (files you write to `output_path/2` stay). A failing artifact step is logged; the test's
  result stands. Nothing is deleted at the start of a run, so `mix test || TRACE=1 mix test
  --failed` (with `trace: :on` under `TRACE`) keeps the first run's files. Delete `output_dir`
  yourself.

  A trace of your own (`PlaywrightEx.Tracing.start/2` with `sources: true`) on a shared driver
  also gets concurrent tests' stacks and sources: the driver adds every call's stack to each
  trace on the connection. `record_artifacts/2` filters its own; yours needs `isolate: true`.

  ## Config

      config :playwright_ex, :test,
        browser_name: :chromium,      # :chromium | :firefox | :webkit
        launch_options: [],           # PlaywrightEx.BrowserType.launch/2
        driver: [],                   # PlaywrightEx.Supervisor: :env, :executable, :node, :cache_dir
        on_start: nil,
        context_options: [],          # PlaywrightEx.Browser.new_context/2
        trace: :off,                  # :off | :on | :retain_on_failure
        screenshot: :off,             # :off | :on | :only_on_failure
        video: :off,                  # :off | :on | :retain_on_failure
        output_dir: "test-results",
        max_isolated: max(div(System.schedulers_online(), 2), 1)

  The artifact modes are `off` by default and `output_dir` is `test-results`, as upstream's.
  `max_isolated` is half the schedulers, as upstream's default `workers` is half the cores.
  """

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder

  # Set once the test process called `record_artifacts/2`.
  @recording {__MODULE__, :recording}
  # The module's token in its `setup_all` process, for fragments that run before ours.
  @token {__MODULE__, :module}

  defmacro __using__(_opts) do
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
            output_path: 2
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
  exits as ExUnit ends a test. A `catch` notes an error for `error-context.md` and re-raises it
  unchanged, so ExUnit reports the failure as without this macro.
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
          PlaywrightEx.Test.__failed__(kind, reason, __STACKTRACE__)
          :erlang.raise(kind, reason, __STACKTRACE__)
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
    :ok
  end

  @doc false
  def __passed__, do: Pool.notify({:passed, self()})

  @doc false
  def __failed__(kind, reason, stacktrace),
    do: Pool.notify({:failed, self(), {kind, Exception.normalize(kind, reason, stacktrace), stacktrace}})

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

    * `:trace` - `:off` (default), `:on` or `:retain_on_failure`.
    * `:screenshot` - `:off` (default), `:on` or `:only_on_failure`.
    * `:video` - `:off` (default), `:on` or `:retain_on_failure`.

  With all three `:off` it only writes `error-context.md` of a failure. `new_context/2` calls it
  with the config if the test hasn't.
  """
  @spec record_artifacts(map(), keyword()) :: :ok
  def record_artifacts(context, options \\ []) when is_map(context) do
    opts = Options.artifacts(options)
    for key <- [:module, :test], do: fetch!(context, key)
    file = fetch!(context, :file)
    watch(context)
    if Process.get(@recording), do: raise(ArgumentError, "record_artifacts was called already for this test")

    Process.put(@recording, true)

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
          location: {file, context[:line]}
        })
      )

    # Each `on_exit` callback gets the test's timeout: half of it for the artifacts.
    budget =
      with timeout when is_integer(timeout) <- context[:timeout] || ExUnit.configuration()[:timeout],
           do: div(timeout, 2)

    ExUnit.Callbacks.on_exit(fn -> Recorder.finish(recorder, budget) end)

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
  has called `record_artifacts/2`.
  """
  @spec new_context(map(), keyword()) :: %{context: BrowserContext.t()}
  def new_context(context, options \\ []) when is_map(context) do
    opts = Options.context(options)
    browser = fetch!(context, :browser)
    token!(context, "new_context/2")
    test_pid = fetch!(context, :test_pid)
    if test_pid == self() and Process.get(@recording) == nil, do: record_artifacts(context)

    recorder = Recorder.lookup(test_pid)
    if recorder, do: Recorder.ensure_listener(recorder, Heap.get(browser, :_instrumentation))

    %{context: Recorder.with_identity(test_pid, fn -> Browser.new_context!(browser, opts.context_options) end)}
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

  @doc "A page of `context.context`, for `setup`: returns `page`."
  @spec new_page(map()) :: %{page: PlaywrightEx.Page.t()}
  def new_page(context) when is_map(context), do: %{page: BrowserContext.new_page!(fetch!(context, :context))}

  # The test's result is the pool's: it monitors the test process.
  defp watch(context) do
    token = token!(context, "record_artifacts/2")
    timeout = context[:timeout] || ExUnit.configuration()[:timeout]
    timeout_error = if is_integer(timeout), do: timeout_error(timeout, context[:test_type] || :test)
    # The failure of a marked test that raised nothing in its body.
    failure = if context[:not_implemented], do: "Not implemented", else: "setup failed"
    marked? = context[:playwright_ex] == :marked
    Pool.watch(fetch!(context, :test_pid), token, marked? && failure, timeout_error)
  end

  # How ExUnit reports a test it killed past its timeout.
  defp timeout_error(timeout, type), do: ExUnit.TimeoutError.exception(timeout: timeout, type: to_string(type))

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
