defmodule PlaywrightEx.Test.BrowserPool do
  @moduledoc """
  Browsers for tests, launched on first use on drivers the pool starts and stops after the
  suite: Playwright Test's worker-scoped `browser` and `playwright` fixtures. Contexts and pages
  come from the plain API (`PlaywrightEx.Browser.new_context!/2`,
  `PlaywrightEx.BrowserContext.new_page!/1`), and a test of `use PlaywrightEx.Test` records the
  contexts it creates on a pooled browser and gives them Playwright Test's defaults.

      setup do
        context = Browser.new_context!(BrowserPool.shared())
        %{context: context, page: BrowserContext.new_page!(context)}
      end

  Both functions take the same options, merged over `config :playwright_ex, :test`
  (`launch_options` and `driver` one level deep):

    * `:browser_name` - `:chromium` (default), `:firefox` or `:webkit`.
    * `:launch_options` - for `PlaywrightEx.BrowserType.launch/2`, as is.
    * `:driver` - options of the driver's `PlaywrightEx.Supervisor`: `:env`, `:executable`,
      `:node`, `:cache_dir`.
    * `:on_start` - a function of the Playwright (`PlaywrightEx.Playwright`) or `{m, f, args}`
      (called with the Playwright first), run once on each new driver before its browser
      launches: `&MyApp.Selectors.register/1`. Part of the driver's key, so pass a capture, not
      a closure.

  A driver hosts a browser per `browser_name` and `launch_options`, so the browser's key is all
  of the options and the driver's key `driver` and `on_start`. Unknown options and bad values
  raise `ArgumentError`.

  ## Shared and exclusive

  `shared/1` returns the browser of its key, used by every caller at once, as the one
  connection serves any number of processes: contexts isolate tests. It is never evicted and
  never waits, and a lost browser is launched again by the next call.

  > #### Firefox: use `exclusive` {: .warning}
  >
  > Firefox dispatches input for all of a browser's pages in one queue, so a shared Firefox
  > browser slows down as concurrent tests grow, until they time out. On Firefox, use
  > `exclusive/1`: one browser per worker, as Playwright Test always does.

  `exclusive/1` is upstream's worker: a driver and browser held by the scope that calls it, for
  a module that changes the driver or browser for others (registers selectors, sets the test id
  attribute, closes or traces the browser). Called in `setup_all`, the module holds it until it
  ends; in `setup` or a test (or a `Task` of the test, through `$callers`), the test holds it
  until it ends. A test's own call is a separate lease from its module's. The scope's further
  calls with the same options return the same browser; another driver key gets another driver.
  At the end of the scope (the last step of a registered test's `on_exit`; for another scope,
  an `on_exit` its first call registers), a scope that passed gives its driver back, warm, to
  the next caller of its key, and one that failed stops it. A module passes when a test of it
  ran and all of them passed, which needs `use PlaywrightEx.Test`.

  At most `workers` exclusive drivers run at once (config, default half the schedulers, as
  Playwright Test's `workers`); others wait, first come first served, within ExUnit's test
  timeout (`setup_all` has none), and a wait of 10 s logs the holders. A scope that holds one
  takes its further driver keys over `workers`, so it never waits while others wait for it. At
  the cap, a key with no free driver stops the longest idle free driver of another key.

  A driver you start yourself (`start_supervised!({PlaywrightEx.Supervisor, name: MyDriver})`,
  then `PlaywrightEx.Playwright.chromium/1` and `PlaywrightEx.BrowserType.launch!/2`) has no cap,
  no reuse, no context defaults and no recording.
  """

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Pool.Slot
  alias PlaywrightEx.Test.Recorder

  @doc """
  The shared browser of `opts` (see the moduledoc): one driver and browser per key, launched on
  first use and again if lost, outside `workers`.
  """
  @spec shared(keyword()) :: Browser.t()
  def shared(opts \\ []), do: Pool.shared(Options.pool(opts)).browser

  @doc """
  An exclusive browser of `opts` held by the calling scope (see the moduledoc): a registered
  test (the caller or a process in its `$callers`), else the calling process, a `setup_all`'s.
  Raises outside ExUnit's processes.
  """
  @spec exclusive(keyword()) :: Browser.t()
  def exclusive(opts \\ []) do
    opts = Options.pool(opts)

    case Recorder.registration() do
      %{test_pid: test_pid, test_name: name, file: file} ->
        Pool.exclusive(opts, {:test, test_pid}, "the test #{inspect(name)} (#{Path.relative_to_cwd(file)})").browser

      nil ->
        scope = self()

        try do
          ExUnit.Callbacks.on_exit({__MODULE__, :release}, fn -> Pool.release(scope) end)
        rescue
          ArgumentError ->
            reraise ArgumentError,
                    "BrowserPool.exclusive/1 is held by a test (its process or a process with it in $callers, " <>
                      "with `use PlaywrightEx.Test`) or by setup_all, and released at their end; got a call " <>
                      "from #{inspect(scope)}",
                    __STACKTRACE__
        end

        Pool.exclusive(opts, {:process, scope}, holder()).browser
    end
  end

  @doc """
  The Playwright (`PlaywrightEx.Playwright`) of a pooled browser's driver: its `selectors`,
  `request` and other browser types. Raises for a browser the pool didn't launch.
  """
  @spec playwright(Browser.t()) :: PlaywrightEx.Playwright.t()
  def playwright(%Browser{conn: conn} = browser) do
    Slot.playwright(conn) ||
      raise ArgumentError, "not a browser of PlaywrightEx.Test.BrowserPool: #{inspect(browser)}"
  end

  # A `setup_all`'s module, by its callback's frame, for the wait warning.
  defp holder do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

    Enum.find_value(stacktrace, inspect(self()), fn {module, fun, _arity, _location} ->
      if String.starts_with?(Atom.to_string(fun), "__ex_unit_setup_all"), do: "setup_all of #{inspect(module)}"
    end)
  end
end
