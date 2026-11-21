defmodule Playwright.Test.BrowserPool do
  @moduledoc """
  Browsers for tests, on drivers the pool starts and stops after the suite: Playwright Test's
  worker-scoped `browser` and `playwright` fixtures, and its worker model. Contexts and pages
  come from the plain API (`Playwright.Browser.new_context!/2`,
  `Playwright.BrowserContext.new_page!/1`), and a test of `use Playwright.Test` records the
  contexts it creates on a pooled browser and gives them Playwright Test's defaults.

      setup_all do
        %{browser: BrowserPool.browser()}
      end

      setup %{browser: browser} do
        context = Browser.new_context!(browser)
        %{context: context, page: BrowserContext.new_page!(context)}
      end

  `browser/1` takes these options, merged over `config :playwright, :test` (`launch_options`
  and `driver` one level deep). In a module of `use Playwright.Test`, the module's
  `browser_name`, `headless`, `channel`, `launch_options` and `connect_options` (its `use` options and its project's,
  see "Browser" in `Playwright.Test`) are between the two, each replacing the config's as a
  whole (`launch_options` too, as upstream's fixture); the call's `launch_options` merge over
  them one key at a time:

    * `:browser_name` - `:chromium` (default), `:firefox` or `:webkit` (or its string); without one anywhere,
      that of the module's device.
    * `:headless`, `:channel` - Playwright Test's options of their own, set over the launch
      options' when given; unset (`nil`, default), the launch options' (`headless` `true` when
      they have none).
    * `:launch_options` - for `Playwright.BrowserType.launch/2`, with `headless` and `channel`
      over them (upstream's `_browserOptions`).
    * `:connect_options` - Playwright Test's `connectOptions`: `:ws_endpoint` (required) and
      the options of `Playwright.BrowserType.connect/3` (`:headers`, `:expose_network`,
      `:timeout`, `:slow_mo`). The browser is then connected to that Playwright server instead
      of launched, with the launch options (`headless` and `channel` over them) sent in the
      `x-playwright-launch-options` header (the
      call's `headers` win). `nil` (default) launches.
    * `:driver` - `[env: _]`, the driver's environment (`Playwright.Supervisor`'s `:env`). The
      driver itself is `config :playwright, :driver`'s, as `mix playwright.install` installs it.
    * `:on_start` - a function of the Playwright (`Playwright`) or `{m, f, args}`
      (called with the Playwright first), run once on each new driver before its browser
      launches: `&MyApp.Selectors.register/1`. Part of the worker's key, so pass a capture, not
      a closure. The worker's `headless` and `channel` are passed to the launch explicitly, over
      any default launch options an `on_start` sets.

  A worker is one driver and one browser, keyed by all of the options, as upstream's worker hash
  covers its project's options. A connected browser runs on the server, its driver here:
  `on_start` runs on the driver before the connect, and its contexts get the defaults and are
  recorded, as a launched browser's. Unknown options and bad values raise `ArgumentError`.

  ## Workers

  A worker is a process that runs one driver and its browser at a time, of one set of options,
  held by the scope that calls `browser/1`. Called in `setup_all`, the
  module holds it until it ends, as upstream runs a file in one worker; a test's own calls then
  go to its module's hold. In `setup` or a test of a module that holds none (or a `Task` of the
  test, through `$callers`), the test holds it until it ends. The scope's further calls with the
  same options return the same browser; other options take another worker. At the end of the scope
  (the last step of a registered test's `on_exit`; for another scope, an `on_exit` its first call
  registers), its workers go back, their drivers warm for the next caller of the options, unless it
  failed: then the drivers stop, as upstream replaces a worker after a failure. A module fails
  when its `setup_all` failed (raised, past its timeout, killed or taken down by a linked process;
  only with `use Playwright.Test`, which registers and wraps it: a plain ExUnit module's
  `setup_all` counts as passed, as an unregistered test does), when a test of it failed, or when a
  test's artifacts took longer than their half of its timeout (its contexts may be left open). An
  `on_exit` of `setup_all` that fails doesn't reset them, where upstream stops a worker whose
  `afterAll` failed. Only registered tests have results: register tests with `use Playwright.Test`
  to get Playwright Test's discard-after-failure; a scope with no known result (no registered
  test, a doctest) counts as passed. A lost browser is launched (or connected) again by the scope's
  next call.

  At most `workers` workers are held at once (config, default half the schedulers, as Playwright
  Test's `workers`); other scopes wait, first come first served, within ExUnit's test timeout
  (not counted in `setup_all`'s). A scope that waits costs nothing, so ExUnit's `max_cases` can stay
  above `workers`. A scope that holds a worker takes its further options over `workers`, so it
  never waits while others wait for it; those workers stop at its end. A scope gets an idle
  worker of its options, else a new one, else the longest idle worker of other options, whose
  driver its `browser/1` restarts, as upstream restarts a worker of another hash: in a run that mixes
  options, each switch costs a driver start (about 110 ms) and a browser launch.

  The test id attribute of `get_by_test_id` is global to the VM (upstream's to the worker
  process), so only a suite-wide one is safe: config `test_id_attribute`, which each pooled
  driver gets.

  With `connect_options`, each driver connects once, and the server launches a browser per
  connection, so each worker has a browser of its own, as each Playwright Test worker does.

  A driver you start yourself (`start_supervised!({Playwright.Supervisor, name: MyDriver})`,
  then `Playwright.chromium/1` and `Playwright.BrowserType.launch!/2` or
  `connect!/3`) has no cap, no reuse, no context defaults and no recording.
  """

  alias Playwright.Browser
  alias Playwright.Test.Options
  alias Playwright.Test.Pool
  alias Playwright.Test.Recorder
  alias Playwright.Test.Results

  @doc """
  The browser of `opts` held by the calling scope (see the moduledoc): a registered test (the
  caller or a process in its `$callers`; its module's, if the module holds one), else the
  calling process, a `setup_all`'s. Raises outside ExUnit's processes. A call before `use
  Playwright.Test` registered its test or `setup_all` (a case template's own `setup`) gets none of
  the module's options, so the registration raises.
  """
  @spec browser(keyword()) :: Browser.t()
  def browser(opts \\ []) do
    # For `Recorder.worker_options/0`'s note of an unregistered caller.
    Pool.ensure_started()
    # Under them, the worker options of the module's run (upstream's `browserName`, `headless`,
    # `channel`, `launchOptions`, `connectOptions`), over the config's.
    opts = Options.pool(opts, Recorder.worker_options())

    case Recorder.registration() do
      %{test_pid: test_pid} ->
        Pool.browser(opts, {:test, test_pid}).browser

      nil ->
        scope = self()

        try do
          ExUnit.Callbacks.on_exit({__MODULE__, :release}, fn -> Pool.release(scope) end)
        rescue
          ArgumentError ->
            reraise RuntimeError,
                    "Playwright.Test.BrowserPool.browser/1: no test or setup_all to hold the browser, expected a " <>
                      "call from a test (its process or a process with it in $callers, with `use Playwright.Test`) " <>
                      "or a setup_all, which release it at their end, got: #{inspect(scope)}",
                    __STACKTRACE__
        end

        Pool.browser(opts, {:process, scope}).browser
    end
  end

  @doc """
  The Playwright (`Playwright`) of a pooled browser's driver: its `selectors`,
  `request` and other browser types. Raises for a browser the pool didn't launch.
  """
  @spec playwright(Browser.t()) :: Playwright.t()
  def playwright(%Browser{conn: conn} = browser) do
    # The driver's row of the browser's connection (`Playwright.Test.Pool.Worker`).
    case Results.started?() && :ets.lookup(Results.table(), {:driver, conn}) do
      [{_key, playwright}] ->
        playwright

      _ ->
        raise ArgumentError, "Playwright.Test.BrowserPool.playwright/1: not a pooled browser, got: #{inspect(browser)}"
    end
  end
end
