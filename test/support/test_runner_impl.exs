# The child BEAM of `PlaywrightEx.Test.EndToEndTest`: a suite on `PlaywrightEx.Test`, run as
# `mix test` runs one (`ExUnit.run/0`, then halt).
#
# Runs as `elixir -pa <playwright_ex ebin> test_runner_impl.exs <mode> <output dir> <browser> [<go file>]`:
#
#   * `artifacts` - one passing and one failing test, `trace: :retain_on_failure, screenshot:
#     :only_on_failure`. It prints "(ready=>true)" in the passing test and waits there until the
#     go file exists.
#   * `modules` - isolated modules (ten tests, two driver keys, a failure, `parameterize:`) and
#     one with no browser; prints the pool after the run: `(report=>%{...})`.
#   * `max_failures` - `max_failures: 1`, an isolated module running when another fails; prints
#     the pool after the run.

# credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename

PlaywrightEx.ClientProcess.halt_on_stdin_eof()
Logger.configure(level: :info)

[mode, output_dir, browser_name | _] = System.argv()

Application.put_env(:playwright_ex, :test,
  browser_name: String.to_atom(browser_name),
  output_dir: output_dir,
  trace: :retain_on_failure,
  screenshot: :only_on_failure,
  max_isolated: 8
)

# The test build's .app lists the test-only deps: start the library's own tree.
:ok = Application.load(:playwright_ex)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = PlaywrightEx.Application.start(:normal, [])

max_failures = if mode == "max_failures", do: 1, else: :infinity
ExUnit.start(autorun: false, max_cases: 8, max_failures: max_failures)

# What the modules saw: `{label, token, playwright}`.
:ets.new(:report, [:named_table, :public, :bag])

defmodule Report do
  def put(label, ctx, %{playwright: playwright}),
    do: :ets.insert(:report, {label, ctx.playwright_ex_module, playwright})

  # Polls until `label` is in the report.
  def await(label, attempts \\ 100) do
    cond do
      :ets.member(:report, label) -> :ok
      attempts == 0 -> raise "#{inspect(label)} not reported"
      true -> Process.sleep(50) && await(label, attempts - 1)
    end
  end

  # Prints the pool after the run, before it stops the drivers: `after_suite` callbacks run
  # newest first, and the pool registers its own when it starts its first driver.
  def after_suite, do: ExUnit.after_suite(&print/1)

  # The labels of the free drivers, how many modules hold drivers, and per label how many
  # tokens and drivers its tests saw.
  def print(_stats) do
    state = :sys.get_state(PlaywrightEx.Test.Pool)
    reported = :ets.tab2list(:report)
    # A driver's connection names it (every driver's Playwright has the same guid).
    label_of = Map.new(reported, fn {label, _token, playwright} -> {playwright.conn, label} end)
    free = for {pid, _key} <- state.free, do: label_of[:sys.get_state(pid).playwright.conn]

    report = %{
      free: Enum.sort(free),
      busy: map_size(state.busy),
      tokens:
        reported |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> Map.new(fn {l, ts} -> {l, length(Enum.uniq(ts))} end),
      drivers:
        reported
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 2).conn)
        |> Map.new(fn {l, cs} -> {l, length(Enum.uniq(cs))} end),
      param_tokens:
        reported
        |> Enum.filter(&(elem(&1, 0) in [:param_1, :param_2]))
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()
        |> length()
    }

    IO.puts("(report=>#{inspect(report)})")
  end
end

case mode do
  "artifacts" ->
    defmodule SampleTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      alias PlaywrightEx.Page

      setup_all :browser
      setup [:new_context, :new_page]

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
    # A driver key per module (`driver: [env: ...]`), so no module reuses another's driver.
    defmodule Key do
      def opts(label), do: [isolate: true, driver: [env: [{"PW_MODULE", to_string(label)}]]]
    end

    defmodule TenTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      for i <- 1..10 do
        test "#{i}", ctx do
          Report.put(:ten, ctx, browser(ctx, Key.opts(:ten)))
          # Another browser key: on the same driver.
          other = Key.opts(:ten) ++ [launch_options: [timeout: 30_001]]
          if unquote(i) == 1, do: Report.put(:ten, ctx, browser(ctx, other))
        end
      end
    end

    defmodule TwoDriversTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      test "two driver keys", ctx do
        Report.put(:two_a, ctx, browser(ctx, Key.opts(:two_a)))
        Report.put(:two_b, ctx, browser(ctx, Key.opts(:two_b)))
      end
    end

    defmodule FailsTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      setup_all ctx do
        browser = browser(ctx, Key.opts(:fails))
        Report.after_suite()
        browser
      end

      test "fails", ctx do
        Report.put(:fails, ctx, ctx)
        flunk("on purpose")
      end
    end

    defmodule ParamTest do
      # Both parameter sets hold their drivers at once.
      use ExUnit.Case, async: true, parameterize: [%{n: 1}, %{n: 2}]
      use PlaywrightEx.Test

      setup_all ctx, do: browser(ctx, Key.opts(:param))

      test "holds", %{n: n} = ctx do
        Report.put(:"param_#{n}", ctx, ctx)
        Report.await(:"param_#{3 - n}")
      end
    end

    defmodule NoBrowserTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      test "asks for none", ctx do
        assert Map.get(:sys.get_state(PlaywrightEx.Test.Pool).busy, ctx.playwright_ex_module) == nil
      end
    end

  "max_failures" ->
    defmodule IsolatedTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      setup_all ctx do
        browser = browser(ctx, isolate: true)
        Report.put(:isolated, ctx, browser)
        Report.after_suite()
        browser
      end

      for i <- 1..3, do: test("#{i}", do: Process.sleep(500))
    end

    defmodule FailsTest do
      use ExUnit.Case, async: true
      use PlaywrightEx.Test

      test "fails once the other module runs" do
        Report.await(:isolated)
        flunk("on purpose")
      end
    end
end

ExUnit.run()
System.halt(0)
