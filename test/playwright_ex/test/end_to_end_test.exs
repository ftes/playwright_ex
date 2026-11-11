defmodule PlaywrightEx.Test.EndToEndTest do
  # Suites on `PlaywrightEx.Test` in a child BEAM (`test/support/test_runner_impl.exs`): only the
  # failing test keeps its artifacts and gets `error-context.md`, no driver outlives the halted
  # VM (`after_suite`), and each module's isolated drivers are checked in at its end (discarded
  # after a failure), also when `max_failures` stops the run.
  use ExUnit.Case, async: true

  alias PlaywrightEx.RemoteServer.ChildProcess

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  defp start(mode, tmp_dir, args \\ []) do
    ebin = Path.dirname(:code.which(PlaywrightEx))
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
    assert ChildProcess.output(child) =~ ~r"2 tests, 1 failure|Result: 1/2 passed"
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

  test "a module's isolated drivers: one per driver key, checked in at its end, discarded after a failure",
       %{tmp_dir: tmp_dir} do
    {output, report} = report(start("modules", tmp_dir))
    assert output =~ ~r"15 tests, 1 failure|Result: 14/15 passed"

    assert report.busy == 0
    # Not the failed module's.
    assert report.free == [:param_1, :param_2, :ten, :two_a, :two_b]
    # Ten tests and two browser keys on one driver; a token per parameter set, each its own driver.
    assert report.drivers.ten == 1
    assert report.tokens.ten == 1
    assert report.param_tokens == 2
  end

  test "max_failures: a module still running is checked in", %{tmp_dir: tmp_dir} do
    {output, report} = report(start("max_failures", tmp_dir))
    assert output =~ "--max-failures reached, aborting test suite"
    assert report.busy == 0
    assert report.free == [:isolated]
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
end
