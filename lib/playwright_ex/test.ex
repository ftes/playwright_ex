defmodule PlaywrightEx.Test do
  @moduledoc """
  ExUnit setup fragments for browser tests: a browser per module, a context and page per test,
  and traces, screenshots and videos of failures.

      # test/test_helper.exs
      ExUnit.start(formatters: [ExUnit.CLIFormatter, PlaywrightEx.Test.Formatter])

      # config/test.exs
      config :playwright_ex, :test, trace: :retain_on_failure, screenshot: :only_on_failure

      defmodule MyApp.CheckoutTest do
        use ExUnit.Case, async: true
        import PlaywrightEx.Test

        setup_all :browser
        setup [:new_context, :new_page]

        test "pays", %{page: page} do
          ...
        end
      end

  Not a port of Playwright Test: these follow the runners of the official non-JS clients
  (pytest-playwright, Playwright.NUnit, Java's `@UsePlaywright`) on ExUnit, with Playwright
  Test's names and defaults where they exist (`packages/playwright/src/index.ts`).

  Each fragment reads the context map and returns new keys, `browser/1` → `%{browser: _}` →
  `new_context/1` → `%{context: _}` → `new_page/1` → `%{page: _}`, so any of them can be
  replaced by your own code: a `setup_all` that returns `%{browser: _}` of a browser you
  connected to works with `new_context/1`. Called with the context map, a fragment takes its
  options from `config :playwright_ex, :test`; called with options, they are merged over the
  config (`launch_options`, `context_options` and `driver` one level deep). Unknown options and
  bad values raise `ArgumentError`.

  ## Browsers

  `browser/1` returns a browser that modules with the same `browser_name` and `launch_options`
  share, launched on first use and again if it is lost. Modules with the same `driver` and
  `on_start` share a driver, which hosts every browser type, as upstream runs them all on one
  Playwright: a test records the contexts of all of its browsers. Contexts isolate tests, so a
  shared browser is safe across `async: true` modules. A module that changes the state of the
  whole driver or browser (registers selectors, closes the browser, launches its own) takes
  `isolate: true` in `setup_all`: a driver of its own for its lifetime, with the browsers its
  `browser/2` calls launch, as Playwright Test's workers have, discarded if a test failed. At most `max_isolated` modules
  have one at once, the others wait. Every driver is stopped after the suite
  (`ExUnit.after_suite/1`), so none outlives `mix test`.

  ## Artifacts

  `record_artifacts/2` records every context the test creates: with `new_context/2`, with
  `PlaywrightEx.Browser.new_context/2` in the test or in a `Task` of it, and with
  `new_context/2` from any other process given the test's context map (a GenServer that
  creates contexts for the test). Each test writes to its own dir under `output_dir`, named as
  upstream's `testInfo.outputDir` (`checkout-pays-1a2b3` for the test "pays" in
  `test/checkout_test.exs`, the suffix a hash of the module and its `parameterize:` parameters):

    * `trace.zip` - one trace of all its contexts (`mix playwright_ex.cli show-trace <path>`),
      recorded with screenshots, snapshots and sources (upstream's default trace options).
    * `test-finished-N.png`, or `test-failed-N.png` for `only_on_failure` - a screenshot of
      every page open when its context closes (`timeout: 5000, caret: :initial`, as upstream).
    * `video.webm`, `video-1.webm`, ... - every page's video. A context created with its own
      `record_video` keeps it, and its video is copied here too.

  An artifact step that fails is logged, and the test's own result stands. The `on` modes keep
  everything; `retain_on_failure` and `only_on_failure` record every test, and
  `PlaywrightEx.Test.Formatter` deletes the files of the tests that pass. A trace slows every
  test: `trace: :on` set when `TRACE=1`, with `mix test || TRACE=1 mix test --failed` in CI,
  traces only the failures' reruns (upstream's `on-first-retry`). Nothing is deleted at the
  start of a run or a test (files are overwritten by name), so the rerun keeps the first run's
  artifacts, and `output_dir` accumulates across local runs: delete it yourself (CI starts
  clean).

  ExUnit puts a `parameterize:` module's parameter values in the context, not the map, so the
  fragments tell the parameter sets apart by those keys: run them before a setup that rebinds
  a parameter key. If two sets look the same, the second test records into a dir of its own
  (logged), and its files are not pruned.

  ## Config

      config :playwright_ex, :test,
        browser_name: :chromium,      # :chromium | :firefox | :webkit
        launch_options: [],           # PlaywrightEx.BrowserType.launch/2
        driver: [],                   # PlaywrightEx.Supervisor: :env, :executable, :node, :cache_dir
        on_start: nil,
        isolate: false,
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

  @doc """
  A browser for the module, for `setup_all`: returns `playwright`, `browser_name` and `browser`.

  Takes the context map (`setup_all :browser`, options from the config) or options, also as
  `browser(context, options)`:

    * `:browser_name` - `:chromium` (default), `:firefox` or `:webkit`.
    * `:launch_options` - for `PlaywrightEx.BrowserType.launch/2`, as is.
    * `:driver` - options of the driver's `PlaywrightEx.Supervisor`: `:env`, `:executable`,
      `:node`, `:cache_dir`.
    * `:on_start` - a function of the Playwright (`PlaywrightEx.Playwright`) or `{m, f, args}`
      (called with the Playwright first), run once on each new driver before its browser
      launches: `&MyApp.Selectors.register/1`. Part of the key that modules share a browser
      by, so pass a capture, not a closure.
    * `:isolate` - `true` gives the module a driver and browser of its own (see the moduledoc).
      Needs the context map, `browser(context, isolate: true)`, and `PlaywrightEx.Test.Formatter`.

  A second call returns another browser: a second user on Firefox is
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
    module = context[:module]

    if opts.isolate do
      if !module, do: raise(ArgumentError, "isolate: true needs the module: call browser(context, isolate: true)")

      if context[:test],
        do: raise(ArgumentError, "isolate: true is for the module: call browser(context, isolate: true) in setup_all")

      Options.require_formatter!("isolate: true")
    end

    # A `parameterize:` module runs once per parameter map, maybe at once: each is an owner.
    owner = module && {module, Recorder.parameters(module, context)}
    %{playwright: playwright, browser: browser} = Pool.browser(opts, owner)
    %{playwright: playwright, browser_name: opts.browser_name, browser: browser}
  end

  @doc """
  Records the artifacts of every context the test creates, for `setup`; see the moduledoc.

  Takes the test's context map (`module`, `test`, `file`; `browser` or `playwright` to record
  plain `PlaywrightEx.Browser.new_context/2` calls) and the options, merged over the config:

    * `:trace` - `:off` (default), `:on` or `:retain_on_failure`.
    * `:screenshot` - `:off` (default), `:on` or `:only_on_failure`.
    * `:video` - `:off` (default), `:on` or `:retain_on_failure`.

  With all three `:off` it does nothing. `new_context/2` calls it with the config if the test
  hasn't. `retain_on_failure` and `only_on_failure` need `PlaywrightEx.Test.Formatter`.
  """
  @spec record_artifacts(map(), keyword()) :: :ok
  def record_artifacts(context, options \\ []) when is_map(context) do
    opts = Options.artifacts(options)
    for key <- [:module, :test, :file], do: fetch!(context, key)
    if Process.get(@recording), do: raise(ArgumentError, "record_artifacts was called already for this test")

    Process.put(@recording, true)

    if opts.trace != :off or opts.screenshot != :off or opts.video != :off, do: start_recording(context, opts)
    :ok
  end

  defp start_recording(context, opts) do
    if :retain_on_failure in [opts.trace, opts.video] or opts.screenshot == :only_on_failure,
      do: Options.require_formatter!("retain_on_failure and only_on_failure")

    # Not emptied: files are overwritten by name, so a rerun keeps the first run's other files.
    dir = Recorder.output_dir(context)
    title = "#{Path.relative_to_cwd(context.file)}:#{context[:line]} › #{Recorder.test_name(context)}"
    {_key, recorder} = Recorder.start(Recorder.key(context), self(), Map.merge(opts, %{dir: dir, title: title}))
    # Each `on_exit` callback gets the test's timeout: half of it for the artifacts.
    budget =
      with timeout when is_integer(timeout) <- context[:timeout] || ExUnit.configuration()[:timeout],
           do: div(timeout, 2)

    ExUnit.Callbacks.on_exit(fn -> Recorder.finish(recorder, budget) end)

    owner = context[:browser] || context[:playwright]
    if owner, do: Recorder.ensure_listener(recorder, Heap.get(owner, :_instrumentation))
  end

  @doc """
  A context of `context.browser` for the test, for `setup`: returns `context`.

  Option: `:context_options` for `PlaywrightEx.Browser.new_context/2`, as is (merged over the
  config's). Starts `record_artifacts/2` with the config if the test hasn't. Called from the
  test process it closes the context after the test; another process closes its own.

  The context map needs `browser` and the test's `module` and `test` (and `file`, to start the
  recording). It is what it records the context under, from any process: a GenServer that
  creates contexts for a test passes the test's whole context map (with its `test_pid`, it finds
  the test's recording), after the test's `setup` has called `record_artifacts/2`.
  """
  @spec new_context(map(), keyword()) :: %{context: BrowserContext.t()}
  def new_context(context, options \\ []) when is_map(context) do
    opts = Options.context(options)
    browser = fetch!(context, :browser)
    for key <- [:module, :test], do: fetch!(context, key)
    key = Recorder.key_of(context)
    test_process? = context[:test_pid] == self()
    if test_process? and Process.get(@recording) == nil, do: record_artifacts(context)

    recorder = Recorder.lookup(key)
    if recorder, do: Recorder.ensure_listener(recorder, Heap.get(browser, :_instrumentation))

    browser_context = Recorder.with_identity(key, fn -> Browser.new_context!(browser, opts.context_options) end)

    if test_process?,
      do: ExUnit.Callbacks.on_exit(fn -> BrowserContext.close(browser_context, reason: "Test ended.") end)

    %{context: browser_context}
  end

  @doc "A page of `context.context`, for `setup`: returns `page`."
  @spec new_page(map()) :: %{page: PlaywrightEx.Page.t()}
  def new_page(context) when is_map(context), do: %{page: BrowserContext.new_page!(fetch!(context, :context))}

  defp fetch!(context, key) do
    case context do
      %{^key => value} when value != nil -> value
      _ -> raise ArgumentError, "expected #{inspect(key)} in the context map, got keys: #{inspect(Map.keys(context))}"
    end
  end
end
