defmodule PlaywrightEx.Test do
  @moduledoc """
  ExUnit setup fragments for browser tests: a shared browser, a context and page per test, and
  traces, screenshots and videos of failures.

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
  bad values raise `ArgumentError`. In a `parameterize:` module, call the fragments before any
  setup that rebinds a parameter key.

  ## Browsers

  `browser/1` returns a shared browser per `browser_name` and `launch_options`, on a driver
  shared per `driver` and `on_start`, launched on first use and again if lost. A module that
  changes the driver or browser for everyone takes `isolate: true`: a driver of its own, held
  until the module finishes, discarded if a test fails, at most `max_isolated` at once. Firefox
  serializes input (mouse, keyboard) across all pages of a browser, so concurrent modules on a
  shared Firefox slow each other down: use `isolate: true` when the run is Firefox, or `use
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
      recorded with screenshots, snapshots and sources (upstream's default trace options).
    * `test-finished-N.png`, or `test-failed-N.png` for `only_on_failure` - a screenshot of
      every page open when its context closes (`timeout: 5000, caret: :initial`, as upstream).
    * `video.webm`, `video-1.webm`, ... - every page's video. A context created with its own
      `record_video` keeps it, and its video is copied here too.
    * `error-context.md` - a failed test's errors, source and an aria snapshot (`mode: :ai`) of
      the first page of its first closed context, always on with the formatter unless
      `PLAYWRIGHT_NO_COPY_PROMPT` is set (upstream's `didFinishTest` and `buildErrorContext`,
      `packages/playwright/src/index.ts:767-838`, `errorContext.ts`). As `on_exit` doesn't know the
      result, every test takes the snapshot.

  A failing artifact step is logged; the test's result stands. The `*_on_failure` modes record
  every test, and `PlaywrightEx.Test.Formatter` deletes the files of passing ones (not those you
  write to `output_path/2`). Nothing is deleted at the start of a run, so `mix test || TRACE=1
  mix test --failed` (with `trace: :on` under `TRACE`) keeps the first run's files. Delete
  `output_dir` yourself.

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
    * `:isolate` - `true` gives the module a driver and browser of its own (see the moduledoc).
      An argument, not config: needs the context map, `browser(context, isolate: true)`, and
      `PlaywrightEx.Test.Formatter`. Called in a test, it checks out the module's driver as
      `setup_all` would: the module's other tests get the same one.

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
    module = context[:module]

    if opts.isolate do
      if !module, do: raise(ArgumentError, "isolate: true needs the module: call browser(context, isolate: true)")

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

  With all three `:off` it only takes the snapshot of `error-context.md` (see the moduledoc). `new_context/2` calls it with the config if the test
  hasn't. `retain_on_failure` and `only_on_failure` need `PlaywrightEx.Test.Formatter`.
  """
  @spec record_artifacts(map(), keyword()) :: :ok
  def record_artifacts(context, options \\ []) when is_map(context) do
    opts = Options.artifacts(options)
    for key <- [:module, :test, :file], do: fetch!(context, key)
    if Process.get(@recording), do: raise(ArgumentError, "record_artifacts was called already for this test")

    Process.put(@recording, true)

    opts = Map.put(opts, :error_context, Options.error_context?())

    if opts.trace != :off or opts.screenshot != :off or opts.video != :off or opts.error_context,
      do: start_recording(context, opts)

    :ok
  end

  defp start_recording(context, opts) do
    if :retain_on_failure in [opts.trace, opts.video] or opts.screenshot == :only_on_failure,
      do: Options.require_formatter!("retain_on_failure and only_on_failure")

    # Not emptied: files are overwritten by name, so a rerun keeps the first run's other files.
    dir = Recorder.output_dir(context)
    title = "#{Path.relative_to_cwd(context.file)}:#{context[:line]} › #{Recorder.test_name(context)}"

    recorder =
      Recorder.start(
        self(),
        Map.merge(opts, %{
          dir: dir,
          title: title,
          test_key: Recorder.test_key(context),
          title_path: Recorder.title_path(context),
          location: {context.file, context[:line]}
        })
      )

    # Each `on_exit` callback gets the test's timeout: half of it for the artifacts.
    budget =
      with timeout when is_integer(timeout) <- context[:timeout] || ExUnit.configuration()[:timeout],
           do: div(timeout, 2)

    ExUnit.Callbacks.on_exit(fn -> Recorder.finish(recorder, budget) end)

    channel = context[:browser] || context[:playwright]
    if channel, do: Recorder.ensure_listener(recorder, Heap.get(channel, :_instrumentation))
  end

  @doc """
  A context of `context.browser` for the test, for `setup`: returns `context`.

  Option: `:context_options` for `PlaywrightEx.Browser.new_context/2`, as is (merged over the
  config's). Starts `record_artifacts/2` with the config if the test hasn't. Called from the
  test process it closes the context after the test; another process closes its own.

  The context map needs `browser`. Its `test_pid` picks the recording, so a process that creates
  contexts for a test (a GenServer) passes the test's whole context map, once the test's `setup`
  has called `record_artifacts/2`.
  """
  @spec new_context(map(), keyword()) :: %{context: BrowserContext.t()}
  def new_context(context, options \\ []) when is_map(context) do
    opts = Options.context(options)
    browser = fetch!(context, :browser)
    test_pid = context[:test_pid]
    test_process? = test_pid == self()
    if test_process? and Process.get(@recording) == nil, do: record_artifacts(context)

    recorder = test_pid && Recorder.lookup(test_pid)
    if recorder, do: Recorder.ensure_listener(recorder, Heap.get(browser, :_instrumentation))

    browser_context = Recorder.with_identity(test_pid, fn -> Browser.new_context!(browser, opts.context_options) end)

    if test_process?,
      do: ExUnit.Callbacks.on_exit(fn -> BrowserContext.close(browser_context, reason: "Test ended.") end)

    %{context: browser_context}
  end

  @doc """
  The path of `name` in the test's output dir (see the moduledoc), as upstream's
  `testInfo.outputPath`: creates the dir, and raises for a `name` outside it. The context map
  needs `module`, `test` and `file`. The formatter deletes no files you write there.
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

  defp fetch!(context, key) do
    case context do
      %{^key => value} when value != nil -> value
      _ -> raise ArgumentError, "expected #{inspect(key)} in the context map, got keys: #{inspect(Map.keys(context))}"
    end
  end
end
