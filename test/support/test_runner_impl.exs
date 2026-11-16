# The child BEAM of `PlaywrightEx.Test.EndToEndTest`: a suite on `PlaywrightEx.Test`, run as
# `mix test` runs one (`ExUnit.run/0`, then halt).
#
# Runs as `elixir -pa <playwright_ex ebin> test_runner_impl.exs <mode> <output dir> <browser> [<go file>]`:
#
#   * `artifacts` - one passing and one failing test, `trace: :retain_on_failure, screenshot:
#     :only_on_failure`. It prints "(ready=>true)" in the passing test and waits there until the
#     go file exists.
#   * `modules` - pooled browsers (a module's of ten tests, a test's of two options, a
#     failing module's, `parameterize:`) and a module with none; prints the pool after the run:
#     `(report=>%{...})`.
#   * `max_failures` - `max_failures: 1`, a module holding a browser running when another
#     fails; prints the pool after the run.
#   * `pool_start` - `PlaywrightEx.Test.Pool.ensure_started/0` while the pool's name is
#     registered and its `init/1` still runs.
#   * `soft_errors` - tests whose matchers write missing snapshots (`snapshot_dir` next to the
#     output dir), one of them failing after that, one killed past its timeout.
#   * `steps` - a test failing in a boxed step, with no browser.
#   * `soft` - soft matchers (`Expect.soft/1`): failing ones, then the rest of the body, then a
#     hard failure; and a passing one.
#   * `timeouts` - tests past their timeout: one in a Playwright call, one in `Process.sleep`, one
#     in a Playwright call after a slow `setup` before `use PlaywrightEx.Test`.
#   * `trace` - `trace: true` (`mix test --trace`): a test past its `timeout` tag passes.
#   * `rerun` - one failing and one passing test (writing a file of its own), `preserve_output:
#     :failures_only`; with a further `failed` argument, only the failing one, as `mix test
#     --failed` runs it (`only_test_ids`).
#   * `retry_modes` - a test per retry mode (trace and video), failing on the first run (`retry`
#     0) or always; with a further `failed` argument, only those, as `mix test --failed` runs them.

# credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename

PlaywrightEx.ClientProcess.halt_on_stdin_eof()
Logger.configure(level: :info)

[mode, output_dir, browser_name | _] = System.argv()

Application.put_env(:playwright_ex, :test,
  browser_name: String.to_atom(browser_name),
  output_dir: output_dir,
  snapshot_dir: Path.join(Path.dirname(output_dir), "snapshots"),
  trace: :retain_on_failure,
  screenshot: :only_on_failure,
  preserve_output: if(mode == "rerun", do: :failures_only, else: :always),
  workers: 8
)

# The test build's .app lists the test-only deps: start the library's own tree.
:ok = Application.load(:playwright_ex)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = PlaywrightEx.Application.start(:normal, [])

max_failures = if mode == "max_failures", do: 1, else: :infinity
# `mix test --failed`'s filter.
only_test_ids =
  if Enum.at(System.argv(), 3) == "failed" do
    case mode do
      "rerun" ->
        MapSet.new([{RerunTest, :"test fails"}])

      "retry_modes" ->
        MapSet.new(
          ["first retry", "all retries", "first failure", "failure and retries"],
          &{RetryModesTest, :"test #{&1}"}
        )
    end
  end

ExUnit.start(
  autorun: false,
  max_cases: 8,
  max_failures: max_failures,
  trace: mode == "trace",
  only_test_ids: only_test_ids
)

# What the modules saw: `{label, scope, playwright}` (the scope: the pid that holds the lease).
:ets.new(:report, [:named_table, :public, :bag])

defmodule Report do
  def put(label, scope, browser),
    do: :ets.insert(:report, {label, scope, PlaywrightEx.Test.BrowserPool.playwright(browser)})

  # Polls until `label` is in the report.
  def await(label, attempts \\ 100) do
    cond do
      :ets.member(:report, label) -> :ok
      attempts == 0 -> raise "#{inspect(label)} not reported"
      true -> Process.sleep(50) && await(label, attempts - 1)
    end
  end

  # Prints the pool after the run, before it stops the drivers: `after_suite` callbacks run
  # newest first, and the pool registers its own when it starts (on first use).
  def after_suite, do: ExUnit.after_suite(&print/1)

  # The labels of the idle seats' warm drivers, how many scopes hold seats, and per label how
  # many scopes and drivers its tests saw.
  def print(_stats) do
    state = :sys.get_state(PlaywrightEx.Test.Pool)
    reported = :ets.tab2list(:report)
    # A driver's connection names it (every driver's Playwright has the same guid).
    label_of = Map.new(reported, fn {label, _scope, playwright} -> {playwright.conn, label} end)

    free =
      for {pid, %{scope: nil, key: key}} <- state.seats,
          key != nil,
          do: label_of[:sys.get_state(pid).playwright.conn]

    count = fn by ->
      reported |> Enum.group_by(&elem(&1, 0), by) |> Map.new(fn {l, xs} -> {l, length(Enum.uniq(xs))} end)
    end

    report = %{
      free: Enum.sort(free),
      leases: map_size(state.scopes),
      scopes: count.(&elem(&1, 1)),
      drivers: count.(&elem(&1, 2).conn)
    }

    IO.puts("(report=>#{inspect(report)})")
  end
end

case mode do
  "artifacts" ->
    defmodule SampleTest do
      use PlaywrightEx.Case, async: true

      test "passes", %{page: page} do
        Page.set_content!(page, "<h1>Passes</h1>")
        IO.puts("(ready=>true)")
        [_, _, _, go] = System.argv()
        wait = fn wait -> if !File.exists?(go), do: Process.sleep(50) && wait.(wait) end
        wait.(wait)
      end

      test "fails", %{page: page} do
        Page.set_content!(page, "<h1>Fails</h1>")
        flunk("on purpose")
      end
    end

  "modules" ->
    # Driver options per label (`driver: [env: ...]`), so no scope reuses another's driver.
    defmodule Key do
      def opts(label), do: [driver: [env: [{"PW_MODULE", to_string(label)}]]]
    end

    alias PlaywrightEx.Test.BrowserPool

    defmodule TenTest do
      # The module's lease: two browser options, a worker each.
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      setup_all do
        browser = BrowserPool.browser(Key.opts(:ten))
        other = BrowserPool.browser(Key.opts(:ten) ++ [launch_options: [timeout: 30_001]])
        %{browser: browser, other: other, scope: self()}
      end

      for i <- 1..10 do
        test "#{i}", ctx do
          Report.put(:ten, ctx.scope, ctx.browser)
          if unquote(i) == 1, do: Report.put(:ten, ctx.scope, ctx.other)
        end
      end
    end

    defmodule TwoDriversTest do
      # A test's lease: two options, two drivers.
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      test "two options" do
        Report.put(:two_a, self(), BrowserPool.browser(Key.opts(:two_a)))
        Report.put(:two_b, self(), BrowserPool.browser(Key.opts(:two_b)))
      end
    end

    defmodule FailsTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      setup_all do
        browser = BrowserPool.browser(Key.opts(:fails))
        Report.after_suite()
        %{browser: browser, scope: self()}
      end

      test "fails", ctx do
        Report.put(:fails, ctx.scope, ctx.browser)
        flunk("on purpose")
      end
    end

    defmodule ParamTest do
      # Both parameter sets hold their drivers at once.
      use ExUnit.Case, async: true, parameterize: [%{n: 1}, %{n: 2}]
      use PlaywrightEx.Test

      setup_all do: %{browser: BrowserPool.browser(Key.opts(:param)), scope: self()}

      test "holds", %{n: n} = ctx do
        Report.put(:"param_#{n}", ctx.scope, ctx.browser)
        Report.await(:"param_#{3 - n}")
      end
    end

    defmodule NoBrowserTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      test "asks for none" do
        refute Enum.any?(Map.values(:sys.get_state(PlaywrightEx.Test.Pool).seats), &(&1.scope == self()))
      end
    end

  "max_failures" ->
    defmodule HeldTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      setup_all do
        browser = PlaywrightEx.Test.BrowserPool.browser()
        Report.put(:held, self(), browser)
        Report.after_suite()
        %{browser: browser}
      end

      for i <- 1..3, do: test("#{i}", do: Process.sleep(500))
    end

    defmodule FailsTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      test "fails once the other module runs" do
        Report.await(:held)
        flunk("on purpose")
      end
    end

  "soft_errors" ->
    defmodule SoftErrorsTest do
      use PlaywrightEx.Case, async: true

      test "writes a snapshot", %{page: page} do
        Page.set_content!(page, "<h1>One</h1>")
        Expect.to_match_aria_snapshot!(page)
      end

      test "writes two", %{page: page} do
        Page.set_content!(page, "<h1>Two</h1>")
        Expect.to_match_aria_snapshot!(page, name: "two.aria.yml")
        Task.await(Task.async(fn -> Expect.to_have_screenshot!(page, name: "two.png") end))
      end

      test "fails after writing one", %{page: page} do
        Page.set_content!(page, "<h1>Three</h1>")
        Expect.to_match_aria_snapshot!(page)
        flunk("on purpose")
      end

      @tag timeout: 4_000
      test "is killed after writing one", %{page: page} do
        Page.set_content!(page, "<h1>Four</h1>")
        # A missing aria snapshot is written past the matcher's timeout.
        Expect.to_match_aria_snapshot!(page, timeout: 500)
        Process.sleep(:infinity)
      end
    end

  "soft" ->
    defmodule SoftTest do
      use PlaywrightEx.Case, async: true

      test "continues after a soft failure", %{page: page} do
        Page.set_content!(page, "<h1>One</h1>")
        heading = Page.locator(page, "h1")
        assert :ok = heading |> Expect.soft() |> Expect.to_have_text!("Uno", timeout: 100)
        IO.puts("(continued=>true)")
      end

      test "soft failures, then a hard one", %{page: page} do
        Page.set_content!(page, "<h1>Two</h1>")
        heading = Page.locator(page, "h1")
        assert :ok = heading |> Expect.soft() |> Expect.to_have_text("Dos", timeout: 100)
        assert :ok = heading |> Expect.not_() |> Expect.soft() |> Expect.to_have_text!("Two", timeout: 100)
        Expect.to_have_text!(heading, "Deux", timeout: 100)
      end

      test "passes", %{page: page} do
        Page.set_content!(page, "<h1>Three</h1>")
        page |> Page.locator("h1") |> Expect.soft() |> Expect.to_have_text!("Three")
      end
    end

  "steps" ->
    defmodule StepsTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      alias PlaywrightEx.Test

      test "fails in a boxed step" do
        Test.step "outer" do
          # (the boxed call)
          log_in()
          :unreachable
        end
      end

      defp log_in do
        Test.step "log in", box: true do
          # (inside the boxed step)
          raise "cannot log in"
        end
      end
    end

  "timeouts" ->
    defmodule TimeoutsTest do
      use PlaywrightEx.Case, async: true

      @tag timeout: 3000
      test "hangs in a Playwright call", %{page: page} do
        Page.set_content!(page, "<h1>Hangs</h1>")
        Page.wait_for_selector!(page, "#never")
      end

      @tag timeout: 3000
      test "hangs elsewhere", %{page: page} do
        Page.set_content!(page, "<h1>Sleeps</h1>")
        Process.sleep(:infinity)
      end
    end

    # ExUnit's timeout counts the setup callbacks before the registration's too.
    defmodule SlowSetupTest do
      use ExUnit.Case, async: true

      alias PlaywrightEx.{Browser, BrowserContext, Page}

      setup_all do
        %{browser: PlaywrightEx.Test.BrowserPool.browser()}
      end

      setup do
        Process.sleep(1500)
      end

      use PlaywrightEx.Test

      @tag timeout: 3000
      test "hangs in a Playwright call after a slow setup", %{browser: browser} do
        page = browser |> Browser.new_context!() |> BrowserContext.new_page!()
        Page.wait_for_selector!(page, "#never")
      end
    end

  "rerun" ->
    defmodule RerunTest do
      use PlaywrightEx.Case, async: true

      test "passes", %{page: page} do
        Page.set_content!(page, "<h1>Passes</h1>")
        File.write!(PlaywrightEx.Test.output_path("note.txt"), "")
      end

      test "fails", %{page: page} do
        Page.set_content!(page, "<h1>Fails</h1>")
        flunk("on purpose")
      end
    end

  "retry_modes" ->
    defmodule RetryModesTest do
      use PlaywrightEx.Case, async: true

      @moduletag screenshot: :off

      # Fails on the first run only, passes under `--failed`.
      defp flaky(page) do
        Page.set_content!(page, "<h1>Retry #{PlaywrightEx.Test.info().retry}</h1>")
        if PlaywrightEx.Test.info().retry == 0, do: flunk("first run")
      end

      @tag trace: :on_first_retry, video: :on_first_retry
      test("first retry", %{page: page}, do: flaky(page))

      @tag trace: :on_all_retries, video: :on_all_retries
      test("all retries", %{page: page}, do: flaky(page))

      @tag trace: :retain_on_first_failure, video: :retain_on_first_failure, screenshot: :on_first_failure
      test "first failure", %{page: page} do
        Page.set_content!(page, "<h1>Fails</h1>")
        flunk("always")
      end

      @tag trace: :retain_on_failure_and_retries, video: :retain_on_failure_and_retries
      test("failure and retries", %{page: page}, do: flaky(page))

      @tag trace: :retain_on_failure_and_retries, video: :retain_on_failure_and_retries
      test("failure and retries passing", %{page: page}, do: Page.set_content!(page, "<h1>Passes</h1>"))
    end

  "pool_start" ->
    # Stands in for the pool, whose name is registered before its `init/1` runs: this one's
    # creates the table after a while.
    defmodule SlowInit do
      use GenServer

      def init(nil) do
        Process.sleep(200)
        :ets.new(PlaywrightEx.Test.Results.table(), [:named_table, :public, :set])
        {:ok, nil}
      end

      def handle_call(_request, _from, state), do: {:reply, :ok, state}
    end

    defmodule PoolStartTest do
      use ExUnit.Case, async: true

      test "a caller racing the pool's start gets it once its table exists" do
        spawn(fn -> GenServer.start(SlowInit, nil, name: PlaywrightEx.Test.Pool) end)
        wait = fn wait -> if !Process.whereis(PlaywrightEx.Test.Pool), do: Process.sleep(1) && wait.(wait) end
        wait.(wait)
        PlaywrightEx.Test.Pool.ensure_started()
        assert PlaywrightEx.Test.Results.started?()
      end
    end

  "trace" ->
    defmodule TraceTest do
      use PlaywrightEx.Case, async: true

      @tag timeout: 500
      test "runs past its timeout", %{page: page} do
        assert :sys.get_state(PlaywrightEx.Test.Recorder.lookup(self())).timer == nil
        Process.sleep(1000)
        Page.set_content!(page, "<h1>Open</h1>")
      end
    end
end

ExUnit.run()
System.halt(0)
