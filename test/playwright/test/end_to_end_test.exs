defmodule Playwright.Test.EndToEndTest do
  # Suites on `Playwright.Test` in a child BEAM (`test/support/test_runner_impl.exs`): only the
  # failing test keeps its artifacts and gets `error-context.md`, no driver outlives the halted
  # VM (`after_suite`), each scope's workers go back idle at its end (their drivers stopped
  # after a failure), also when `max_failures` stops the run, a test fails with the
  # snapshots its matchers wrote and with its soft matchers' failures, and a failing step's error
  # as ExUnit reports it and in the trace, and a rerun under `--failed` writes a `-retry1` dir.
  use ExUnit.Case, async: true

  alias Playwright.RemoteServer.ChildProcess

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  defp start(mode, tmp_dir, args \\ []) do
    ebin = Path.dirname(:code.which(Playwright))
    script = Path.join([__DIR__, "..", "..", "support", "test_runner_impl.exs"])
    browser = System.get_env("BROWSER", "chromium")
    args = ["-pa", ebin, script, mode, Path.join(tmp_dir, "test-results"), browser | args]
    child = ChildProcess.start(System.find_executable("elixir"), args, %{"PWTEST_UNDER_TEST" => nil})
    on_exit(fn -> ChildProcess.stop(child) end)
    child
  end

  defp report(child) do
    assert ChildProcess.exit_code(child, 60_000) == 0
    output = ChildProcess.output(child)
    [_, report] = Regex.run(~r/\(report=>(%\{.*\})\)/, output)
    {report, []} = Code.eval_string(report)
    {output, report}
  end

  test "only the failure keeps artifacts, and no driver survives the VM", %{tmp_dir: tmp_dir} do
    go = Path.join(tmp_dir, "go")
    child = start("artifacts", tmp_dir, [go])

    ChildProcess.await(child, &if(&1 =~ "(ready=>true)", do: {:ok, true}))
    drivers = child |> ChildProcess.pid() |> descendants() |> Enum.filter(&(elem(&1, 1) =~ "run-driver"))
    assert [_] = drivers
    File.write!(go, "")

    assert ChildProcess.exit_code(child, 60_000) == 0
    output = ChildProcess.output(child)
    assert output =~ ~r"2 tests, 1 failure|Result: 1/2 passed"
    # The trace hint follows ExUnit's failures and summary, not the failure before its own.
    [_, after_failure] = String.split(output, "test fails (SampleTest)")
    [_, after_summary] = String.split(after_failure, ~r"2 tests, 1 failure|Result: 1/2 passed")
    assert after_summary =~ ~r/\nTrace of ".*fails": mix playwright.cli show-trace .*fails-[0-9a-f]{5}\/trace.zip\n/
    # The halt came after the drivers had exited.
    assert alive(drivers) == []

    output_dir = Path.join(tmp_dir, "test-results")
    assert [dir] = File.ls!(output_dir)
    assert dir =~ ~r/fails-[0-9a-f]{5}$/
    assert Enum.sort(File.ls!(Path.join(output_dir, dir))) == ["error-context.md", "test-failed-1.png", "trace.zip"]
    error_context = File.read!(Path.join([output_dir, dir, "error-context.md"]))
    assert error_context =~ "- Name: test/support/test_runner_impl.exs >> fails"
    assert error_context =~ "ExUnit.AssertionError: on purpose"
    assert error_context =~ ~s(heading "Fails")
    assert error_context =~ ~r/^> \d+ +\| +flunk\("on purpose"\)$/m
  end

  test "a rerun under --failed writes -retry1 next to the first run's dir, a run without it removes both",
       %{tmp_dir: tmp_dir} do
    output_dir = Path.join(tmp_dir, "test-results")
    files = ["error-context.md", "test-failed-1.png", "trace.zip"]

    run = fn args ->
      child = start("rerun", tmp_dir, args)
      assert ChildProcess.exit_code(child, 60_000) == 0
      output_dir |> File.ls!() |> Enum.sort()
    end

    # `preserve_output: :failures_only`: the passing test's file is gone with its dir.
    assert [dir] = run.([])
    assert dir =~ ~r/^support-test_runner_impl-fails-[0-9a-f]{5}$/
    assert Enum.sort(File.ls!(Path.join(output_dir, dir))) == files
    first = File.read!(Path.join([output_dir, dir, "trace.zip"]))

    assert run.(["failed"]) == [dir, dir <> "-retry1"]
    assert File.read!(Path.join([output_dir, dir, "trace.zip"])) == first
    assert Enum.sort(File.ls!(Path.join(output_dir, dir <> "-retry1"))) == files
    assert File.read!(Path.join([output_dir, dir <> "-retry1", "error-context.md"])) =~ "on purpose"

    assert run.([]) == [dir]
    refute File.read!(Path.join([output_dir, dir, "trace.zip"])) == first
  end

  test "retry modes: a test under --failed is a retry, its trace, video and screenshot by its mode",
       %{tmp_dir: tmp_dir} do
    output_dir = Path.join(tmp_dir, "test-results")

    # The files of each test's dir of the run, `retry` its suffix.
    run = fn args, retry ->
      child = start("retry_modes", tmp_dir, args)
      assert ChildProcess.exit_code(child, 60_000) == 0
      suffix = if retry > 0, do: "-retry#{retry}", else: ""

      for name <- ["first-retry", "all-retries", "first-failure", "failure-and-retries", "failure-and-retries-passing"],
          into: %{} do
        dir = Enum.find(File.ls!(output_dir), &(&1 =~ ~r/^support-test_runner_impl-#{name}-[0-9a-f]{5}#{suffix}$/))
        {name, if(dir, do: output_dir |> Path.join(dir) |> File.ls!() |> Enum.sort())}
      end
    end

    artifacts = ["trace.zip", "video.webm"]

    assert run.([], 0) == %{
             "first-retry" => ["error-context.md"],
             "all-retries" => ["error-context.md"],
             "first-failure" => ["error-context.md", "test-failed-1.png" | artifacts],
             "failure-and-retries" => ["error-context.md" | artifacts],
             "failure-and-retries-passing" => nil
           }

    assert run.(["failed"], 1) == %{
             "first-retry" => artifacts,
             "all-retries" => artifacts,
             "first-failure" => ["error-context.md"],
             "failure-and-retries" => artifacts,
             "failure-and-retries-passing" => nil
           }
  end

  test "pooled drivers: one per options and scope, back idle at its end, stopped after a failure (setup_all's too)",
       %{tmp_dir: tmp_dir} do
    {output, report} = report(start("modules", tmp_dir))
    assert output =~ ~r"18 tests, 1 failure, 3 invalid|Result: 14/15 passed, 3 invalid"

    assert report.holds == 0
    # Not the failed module's, nor the failed `setup_all`s'; each parameter set's own (a driver has
    # one label).
    assert report.free == [:param_1, :param_2, :ten, :ten, :two_a, :two_b]
    # Ten tests and two browser options of one module: a worker each.
    assert report.drivers.ten == 2
    assert report.scopes.ten == 1
  end

  test "max_failures: a module still running is released", %{tmp_dir: tmp_dir} do
    {output, report} = report(start("max_failures", tmp_dir))
    assert output =~ "--max-failures reached, aborting test suite"
    assert report.holds == 0
    assert report.free == [:held]
  end

  test "a test's setup racing the pool's start waits for its init", %{tmp_dir: tmp_dir} do
    child = start("pool_start", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    assert ChildProcess.output(child) =~ ~r"1 test, 0 failures|Result: 1 passed"
  end

  test "a test fails at its end with the snapshots it wrote, all errors reported, also when killed", %{tmp_dir: tmp_dir} do
    child = start("soft_errors", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    output = ChildProcess.output(child)
    assert output =~ ~r"4 tests, 4 failures|Result: 0/4 passed"

    snapshots = Path.join(tmp_dir, "snapshots/support/test_runner_impl.exs-snapshots")
    platform = Atom.to_string(elem(:os.type(), 1))

    assert Enum.sort(File.ls!(snapshots)) ==
             [
               "fails-after-writing-one-1.aria.yml",
               "is-killed-after-writing-one-1.aria.yml",
               "two-#{platform}.png",
               "two.aria.yml",
               "writes-a-snapshot-1.aria.yml"
             ]

    # The matcher's line; ExUnit numbers several failures.
    one = failure(output, "test writes a snapshot (SoftErrorsTest)")
    assert one =~ ~r"\*\* \(RuntimeError\) A snapshot doesn't exist at .*writes-a-snapshot-1.aria.yml, writing actual."

    assert one =~
             ~r"code: Expect.to_match_aria_snapshot!\(page\)\n +stacktrace:\n +test/support/test_runner_impl.exs:\d+: \(test\)"

    refute one =~ "Failure #"

    two = failure(output, "test writes two (SoftErrorsTest)")
    assert two =~ ~r"Failure #1\n +\*\* \(RuntimeError\) A snapshot doesn't exist at .*two.aria.yml, writing actual."

    assert two =~
             ~r"Failure #2\n +\*\* \(RuntimeError\) A snapshot doesn't exist at .*two-#{platform}.png, writing actual."

    three = failure(output, "test fails after writing one (SoftErrorsTest)")

    assert three =~
             ~r"Failure #1\n +\*\* \(RuntimeError\) A snapshot doesn't exist at .*fails-after-writing-one-1.aria.yml"

    assert three =~ ~r"Failure #2\n +on purpose"

    # `error-context.md` has each error.
    output_dir = Path.join(tmp_dir, "test-results")
    [dir] = output_dir |> File.ls!() |> Enum.filter(&(&1 =~ "writes-two"))
    error_context = File.read!(Path.join([output_dir, dir, "error-context.md"]))

    assert error_context =~
             ~r"RuntimeError: A snapshot doesn't exist at .*two.aria.yml.*RuntimeError: A snapshot doesn't exist at .*two-#{platform}.png"s

    # Killed past its timeout: ExUnit reported the timeout only, `error-context.md` has the
    # snapshot it wrote too.
    [dir] = output_dir |> File.ls!() |> Enum.filter(&(&1 =~ "is-killed"))
    error_context = File.read!(Path.join([output_dir, dir, "error-context.md"]))

    assert error_context =~
             ~r"RuntimeError: A snapshot doesn't exist at .*is-killed-after-writing-one-1.aria.yml.*killed"s
  end

  test "a soft matcher's failure: the body continues, the test fails at its end with all its errors",
       %{tmp_dir: tmp_dir} do
    child = start("soft", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    output = ChildProcess.output(child)
    assert output =~ ~r"3 tests, 2 failures|Result: 1/3 passed"
    assert output =~ "(continued=>true)"

    # The matcher's line, as a hard failure's.
    one = failure(output, "test continues after a soft failure (SoftTest)")
    assert one =~ ~r"\*\* \(Playwright.ExpectError\) expect\(locator\).toHaveText\(expected\) failed"
    assert one =~ ~s(Expected: "Uno")
    assert one =~ ~r"code: assert :ok = heading \|> Expect.soft\(\) \|> Expect.to_have_text!\(\"Uno\", timeout: 100\)"
    refute one =~ "Failure #"

    two = failure(output, "test soft failures, then a hard one (SoftTest)")
    assert two =~ ~r"Failure #1\n +\*\* \(Playwright.ExpectError\) expect\(locator\).toHaveText\(expected\) failed"

    assert two =~
             ~r"Failure #2\n +\*\* \(Playwright.ExpectError\) expect\(locator\).not.toHaveText\(expected\) failed"

    assert two =~ ~r"Failure #3\n +\*\* \(Playwright.ExpectError\) expect\(locator\).toHaveText\(expected\) failed"
    assert two =~ ~s(Expected: "Deux")
  end

  test "a boxed step fails at its call site, a failed assert is a step, traced", %{tmp_dir: tmp_dir} do
    child = start("steps", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    output = ChildProcess.output(child)
    assert output =~ ~r"6 tests, 6 failures|Result: 0/6 passed"

    script = Path.join([__DIR__, "..", "..", "support", "test_runner_impl.exs"]) |> File.read!() |> String.split("\n")
    line = fn marker -> Enum.find_index(script, &(&1 =~ marker)) + 2 end

    boxed = failure(output, "test fails in a boxed step (StepsTest)")
    assert boxed =~ "** (RuntimeError) cannot log in"
    # The boxed step's call site, not the frames inside it.
    assert boxed =~ "test/support/test_runner_impl.exs:#{line.("(the boxed call)")}:"
    refute boxed =~ "test/support/test_runner_impl.exs:#{line.("(inside the boxed step)")}:"

    trace_events = fn name ->
      output_dir = Path.join(tmp_dir, "test-results")
      [dir] = output_dir |> File.ls!() |> Enum.filter(&(&1 =~ name))
      {:ok, files} = :zip.unzip(String.to_charlist(Path.join([output_dir, dir, "trace.zip"])), [:memory])
      {_, trace} = List.keyfind(files, ~c"test.trace", 0)
      for event <- String.split(trace, "\n"), do: JSON.decode!(event)
    end

    events = trace_events.("fails-in-a-boxed-step")
    [outer, log_in] = for %{"type" => "before"} = event <- events, do: event
    assert %{"title" => "outer", "method" => "test.step"} = outer
    assert %{"title" => "log in", "parentId" => parent_id} = log_in
    assert parent_id == outer["callId"]

    # Both steps failed with the boxed error, and so did the test.
    for %{"type" => "after", "error" => error} <- events,
        do:
          assert(
            error["stack"] =~
              ~r"^RuntimeError: cannot log in\n    at .*test_runner_impl.exs:#{line.("(the boxed call)")}:"
          )

    assert [%{"message" => "RuntimeError: cannot log in", "stack" => [frame | _]}] =
             for(%{"type" => "error"} = event <- events, do: event)

    assert frame["line"] == line.("(the boxed call)")

    # ExUnit's failure, and an expect step before the test's error.
    failed = failure(output, "test fails in an assert (StepsTest)")
    assert failed =~ "Assertion with == failed\n     code:  assert value + 1 == 3\n     left:  2\n     right: 3"
    assert failed =~ "test/support/test_runner_impl.exs:#{line.("(the failing assert)")}: (test)"

    events = trace_events.("fails-in-an-assert")
    [passed, failed] = for %{"type" => "before"} = event <- events, do: event

    assert %{
             "title" => ~s(Expect "assert"),
             "method" => "expect",
             "params" => %{"expression" => "{:ok, value} = {:ok, 1}"}
           } = passed

    assert %{"title" => ~s(Expect "assert"), "subtitle" => "value + 1 == 3", "stack" => [frame | _]} = failed
    assert frame["line"] == line.("(the failing assert)")

    assert [%{"callId" => id, "error" => %{"message" => message}}] =
             for(%{"type" => "after", "error" => _} = e <- events, do: e)

    assert id == failed["callId"]
    assert message =~ "Assertion with == failed"
    assert [%{"message" => ^message}] = for(%{"type" => "error"} = event <- events, do: event)

    assert Enum.find_index(events, &(&1["callId"] == id and &1["type"] == "after")) <
             Enum.find_index(events, &(&1["type"] == "error"))

    # Once, at the test's level: after the steps it failed in, which fail with its error.
    expects = fn events -> for %{"type" => "before", "method" => "expect"} = event <- events, do: event end
    after_of = fn events, %{"callId" => id} -> Enum.find(events, &(&1["type"] == "after" and &1["callId"] == id)) end
    events = trace_events.("fails-in-a-nested-step")
    assert [nested] = expects.(events)
    refute Map.has_key?(nested, "parentId")
    assert %{"params" => %{"expression" => "1 + 1 == 3", "expected" => "3"}, "stack" => [frame | _]} = nested
    assert frame["line"] == line.("(the nested assert)")
    message = after_of.(events, nested)["error"]["message"]
    assert message =~ "Assertion with == failed"

    for %{"type" => "before", "title" => title} = step <- events,
        title in ["outer", "inner"],
        do: assert(after_of.(events, step)["error"]["message"] == message)

    # Raised again from a rescue (its own stacktrace: there), or reraised; an assert the rescue
    # rescues itself is none.
    assert [again] = expects.(trace_events.("fails-raised-again"))
    assert %{"params" => %{"expression" => "1 == 2", "expected" => "2"}, "stack" => [frame | _]} = again
    assert frame["line"] == line.("(raised again)")
    assert [reraised] = expects.(trace_events.("fails-reraised"))
    assert %{"params" => %{"expression" => "1 == 2"}, "stack" => [frame | _]} = reraised
    assert frame["line"] == line.("(the reraised assert)")

    # A message's, by its own `try`, in its step: once.
    events = trace_events.("with-a-message")
    assert [messaged] = expects.(events)
    assert %{"title" => "never", "parentId" => parent_id, "stack" => [frame | _]} = messaged
    assert parent_id == Enum.find(events, &(&1["title"] == "outer"))["callId"]
    assert frame["line"] == line.("(the message assert)")
  end

  test "config assert_steps: false: ExUnit's assert, no steps; a module's use assert_steps: true wins",
       %{tmp_dir: tmp_dir} do
    child = start("assert_steps", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    output = ChildProcess.output(child)
    assert output =~ ~r"2 tests, 2 failures|Result: 0/2 passed"
    assert output =~ "(config_off=>[macro: ExUnit.Assertions])"
    assert output =~ "(use_on=>[macro: Playwright.Test])"

    expects = fn name ->
      output_dir = Path.join(tmp_dir, "test-results")
      [dir] = output_dir |> File.ls!() |> Enum.filter(&(&1 =~ name))
      {:ok, files} = :zip.unzip(String.to_charlist(Path.join([output_dir, dir, "trace.zip"])), [:memory])
      {_, trace} = List.keyfind(files, ~c"test.trace", 0)
      events = for event <- String.split(trace, "\n"), do: JSON.decode!(event)
      for %{"type" => "before", "method" => "expect"} = event <- events, do: event["params"]["expression"]
    end

    assert expects.("config-off") == []
    assert expects.("use-on") == ["1 + 1 == 2", "Process.get(:not_set, 1) == 2"]
  end

  test "a test past its timeout: a hanging Playwright call fails with the call log, other code as ExUnit's",
       %{tmp_dir: tmp_dir} do
    child = start("timeouts", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    output = ChildProcess.output(child)
    assert output =~ ~r"3 tests, 3 failures|Result: 0/3 passed"

    hangs = failure(output, "test hangs in a Playwright call (TimeoutsTest)")
    assert hangs =~ "Test timeout of 3000ms exceeded."
    assert hangs =~ ~r"Call log:\n.*waiting for locator\('#never'\)"
    refute hangs =~ "ExUnit.TimeoutError"

    output_dir = Path.join(tmp_dir, "test-results")
    [dir] = output_dir |> File.ls!() |> Enum.filter(&(&1 =~ "hangs-in-a-Playwright-call"))
    files = File.ls!(Path.join(output_dir, dir))
    assert "trace.zip" in files
    assert "test-failed-1.png" in files
    error_context = File.read!(Path.join([output_dir, dir, "error-context.md"]))
    assert error_context =~ "Test timeout of 3000ms exceeded."
    assert error_context =~ ~s(heading "Hangs")

    sleeps = failure(output, "test hangs elsewhere (TimeoutsTest)")
    assert sleeps =~ "** (ExUnit.TimeoutError) test timed out after 3000ms"

    # The deadline counts the slow setup before the registration, as ExUnit's timeout does.
    slow_setup = failure(output, "test hangs in a Playwright call after a slow setup (SlowSetupTest)")
    assert slow_setup =~ "Test timeout of 3000ms exceeded."
    refute slow_setup =~ "ExUnit.TimeoutError"
  end

  test "an error in a listener or route handler stops the test at once, with its failure's artifacts",
       %{tmp_dir: tmp_dir} do
    started = System.monotonic_time(:millisecond)
    child = start("interrupt", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    # The whole run, teardowns included, under the tests' timeout (45 s): none hung.
    assert System.monotonic_time(:millisecond) - started < 40_000
    output = ChildProcess.output(child)
    assert output =~ ~r"4 tests, 4 failures|Result: 0/4 passed"
    # Each ended well under its timeout, which it would hang until.
    durations = for [_, ms] <- Regex.scan(~r/\(duration=>(\d+)\)/, output), do: String.to_integer(ms)
    assert length(durations) == 4
    assert Enum.max(durations) < 15_000
    refute output =~ "TimeoutError"
    refute output =~ "Test timeout"

    dialog = failure(output, "test fails in a dialog listener (InterruptDialogTest)")
    assert dialog =~ ~r"\*\* \(EXIT from #PID<[0-9.]+>\) an exception was raised:\n\s+Assertion with == failed"
    assert dialog =~ ~S|code:  assert Playwright.Dialog.message(dialog) == "expected"|
    assert length(String.split(dialog, "Assertion with == failed")) == 2

    route = failure(output, "test fails in a route handler (InterruptTest)")
    assert route =~ "** (RuntimeError) route boom"

    # The soft error recorded before the listener's, then that one: each once.
    soft = failure(output, "test fails softly, then in a console listener (InterruptTest)")
    assert soft =~ ~r"\*\* \(EXIT from #PID<[0-9.]+>\) an exception was raised:\n\s+\*\* \(ExUnit.MultiError\)"
    assert [_, after_soft] = String.split(soft, "toHaveText(expected) failed")
    assert [_, _] = String.split(after_soft, "** (RuntimeError) after soft boom")
    [dir] = Path.join(tmp_dir, "test-results") |> File.ls!() |> Enum.filter(&(&1 =~ "then-in-a-console-listener"))
    soft_context = File.read!(Path.join([tmp_dir, "test-results", dir, "error-context.md"]))
    assert [_, after_soft] = String.split(soft_context, "toHaveText(expected) failed")
    assert [_] = Regex.scan(~r/^RuntimeError: after soft boom$/m, after_soft)

    # Its failure's artifacts, from the teardown, the error once.
    console = failure(output, "test fails in a console listener (InterruptTest)")
    assert console =~ ~S|code:  assert Playwright.ConsoleMessage.text(message) == "expected"|
    output_dir = Path.join(tmp_dir, "test-results")
    [dir] = output_dir |> File.ls!() |> Enum.filter(&(&1 =~ "fails-in-a-console-listener"))
    assert Enum.sort(File.ls!(Path.join(output_dir, dir))) == ["error-context.md", "test-failed-1.png", "trace.zip"]
    error_context = File.read!(Path.join([output_dir, dir, "error-context.md"]))
    assert length(String.split(error_context, "```\nExUnit.AssertionError: Assertion with == failed")) == 2
    # The listener's frame (its `assert` is no tail call, `Playwright.Test.assert/1`): its source.
    assert error_context =~ ~r/^> \d+ \| .*Page.on\(page, :console, fn message -> assert/m
    assert error_context =~ ~s(heading "Logs")
    {:ok, zip} = :zip.unzip(String.to_charlist(Path.join([output_dir, dir, "trace.zip"])), [:memory])
    {_, trace} = List.keyfind(zip, ~c"test.trace", 0)

    assert [%{"message" => "ExUnit.AssertionError: Assertion with == failed" <> _}] =
             for(event <- String.split(trace, "\n"), %{"type" => "error"} = event <- [JSON.decode!(event)], do: event)
  end

  test "--trace: no test timeout, so no timer, and no setup_all timeout", %{tmp_dir: tmp_dir} do
    child = start("trace", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    assert ChildProcess.output(child) =~ ~r"2 tests, 0 failures|Result: 2 passed"
  end

  # Upstream's `beforeAll` hook gets the test timeout, `"beforeAll" hook timeout of 30000ms
  # exceeded.` (`workerMain.ts` `_runAllHooksForSuite`, `timeoutManager.ts`).
  test "a setup_all past its module's timeout fails with upstream's beforeAll message, renamed, and its stack", %{
    tmp_dir: tmp_dir
  } do
    child = start("setup_all_timeout", tmp_dir)
    assert ChildProcess.exit_code(child, 60_000) == 0
    output = ChildProcess.output(child)
    assert output =~ ~r"5 tests, 0 failures, 2 invalid|Result: 3 passed, 2 invalid"

    for {module, timeout, frame} <- [
          {"SetupAllSleepsTest", 1000, "Process.sleep/1"},
          # Its stack: in the wait, or in the context or page on a slow browser.
          {"SetupAllHangsTest", 6000, nil}
        ] do
      setup_all = failure(output, "#{module}: failure on setup_all callback, all tests have been invalidated")
      assert setup_all =~ ~s[** (RuntimeError) "setup_all" hook timeout of #{timeout}ms exceeded.]
      if frame, do: assert(setup_all =~ frame)
    end
  end

  defp alive(processes) do
    {out, 0} = System.cmd("ps", ["-A", "-o", "pid=,lstart="])
    running = MapSet.new(String.split(out, "\n", trim: true), &String.trim/1)
    Enum.filter(processes, fn {pid, _command, start} -> "#{pid} #{start}" in running end)
  end

  # [{pid, command, start}] of the processes below `root`.
  defp descendants(root) do
    {out, 0} = System.cmd("ps", ["-A", "-ww", "-o", "pid=,ppid=,lstart=,command="])

    processes =
      for line <- String.split(out, "\n", trim: true),
          [pid, ppid | rest] = String.split(line, " ", trim: true),
          {start, command} = Enum.split(rest, 5),
          do: {String.to_integer(pid), String.to_integer(ppid), Enum.join(start, " "), Enum.join(command, " ")}

    collect(Enum.group_by(processes, &elem(&1, 1)), [root])
  end

  defp collect(_children, []), do: []

  defp collect(children, [pid | rest]) do
    kids = Map.get(children, pid, [])

    Enum.map(kids, fn {kid, _, start, command} -> {kid, command, start} end) ++
      collect(children, Enum.map(kids, &elem(&1, 0)) ++ rest)
  end

  # A failure's block in ExUnit's output: up to the next failure, the progress dots or the summary
  # (a passing test's dot may follow it directly).
  defp failure(output, title) do
    [_, block] =
      Regex.run(~r/#{Regex.escape(title)}\n(.*?)(?=\n\n+(?: +\d+\) test |[.*]|Finished |Result: )|\n*\z)/s, output)

    block
  end
end
