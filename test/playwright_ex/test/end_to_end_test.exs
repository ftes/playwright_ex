defmodule PlaywrightEx.Test.EndToEndTest do
  # A suite on `PlaywrightEx.Test` in a child BEAM (`test/support/test_runner_impl.exs`), with
  # `trace: :retain_on_failure, screenshot: :only_on_failure`: only the failing test keeps its
  # artifacts, and no driver outlives the halted VM (`after_suite`).
  use ExUnit.Case, async: true

  alias PlaywrightEx.RemoteServer.ChildProcess

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  test "only the failure keeps artifacts, and no driver survives the VM", %{tmp_dir: tmp_dir} do
    output_dir = Path.join(tmp_dir, "test-results")
    go = Path.join(tmp_dir, "go")
    ebin = Path.dirname(:code.which(PlaywrightEx))
    script = Path.join([__DIR__, "..", "..", "support", "test_runner_impl.exs"])
    args = ["-pa", ebin, script, output_dir, System.get_env("BROWSER", "chromium"), go]
    child = ChildProcess.start(System.find_executable("elixir"), args, %{"PWTEST_UNDER_TEST" => nil})
    on_exit(fn -> ChildProcess.stop(child) end)

    ChildProcess.await(child, &if(&1 =~ "(ready=>true)", do: {:ok, true}))
    drivers = child |> ChildProcess.pid() |> descendants() |> Enum.filter(&(elem(&1, 1) =~ "run-driver"))
    assert [_] = drivers
    File.write!(go, "")

    assert ChildProcess.exit_code(child, 60_000) == 0
    assert ChildProcess.output(child) =~ ~r"2 tests, 1 failure|Result: 1/2 passed"
    # The halt came after the drivers had exited.
    assert alive(drivers) == []

    assert [dir] = File.ls!(output_dir)
    assert dir =~ ~r/fails$/
    assert Enum.sort(File.ls!(Path.join(output_dir, dir))) == ["test-failed-1.png", "trace.zip"]
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
