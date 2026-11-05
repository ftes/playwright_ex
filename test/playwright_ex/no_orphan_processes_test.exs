defmodule PlaywrightEx.NoOrphanProcessesTest do
  # No OS process the client or the test fixtures start outlives a BEAM that dies abnormally
  # (`kill -9`): a child BEAM starts each kind (`no_orphan_processes_impl.exs`), the test kills
  # it and waits until all its descendants are gone.
  use ExUnit.Case, async: true

  alias PlaywrightEx.RemoteServer.ChildProcess

  @moduletag :slow
  @moduletag timeout: 120_000

  test "a killed BEAM leaves no driver, server, child BEAM or browser behind" do
    browser_name = System.get_env("BROWSER", "chromium")
    ebin = Path.dirname(:code.which(PlaywrightEx))
    script = Path.join([__DIR__, "..", "support", "no_orphan_processes_impl.exs"])
    child = ChildProcess.start(System.find_executable("elixir"), ["-pa", ebin, script, browser_name])
    on_exit(fn -> ChildProcess.stop(child) end)

    ChildProcess.await(child, &if(&1 =~ "(ready=>true)", do: {:ok, true}))
    beam = ChildProcess.pid(child)
    descendants = descendants(beam)
    commands = Enum.map_join(descendants, "\n", &elem(&1, 1))
    assert commands =~ "run-driver"
    assert commands =~ "run-server"
    assert commands =~ "launch-server"
    assert commands =~ "remote-server-impl.js"
    assert commands =~ "client_process_impl.exs"

    ChildProcess.kill(child, "SIGKILL")
    ChildProcess.exit_code(child)

    left = wait_gone(descendants, 100)
    for {pid, _command} <- left, do: System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
    assert left == [], "left behind:\n" <> Enum.map_join(left, "\n", &elem(&1, 1))
  end

  # [{pid, command, start}] of the processes below `root` (`start` tells a reused pid apart).
  defp descendants(root) do
    processes = processes()
    children = Enum.group_by(processes, fn {_pid, ppid, _start, _command} -> ppid end)
    collect(children, [root])
  end

  defp collect(_children, []), do: []

  defp collect(children, [pid | rest]) do
    kids = Map.get(children, pid, [])

    Enum.map(kids, fn {kid, _ppid, start, command} -> {kid, command, start} end) ++
      collect(children, Enum.map(kids, &elem(&1, 0)) ++ rest)
  end

  defp processes do
    {out, 0} = System.cmd("ps", ["-A", "-ww", "-o", "pid=,ppid=,lstart=,command="])

    for line <- String.split(out, "\n", trim: true),
        [pid, ppid | rest] = String.split(line, " ", trim: true),
        {start, command} = Enum.split(rest, 5),
        do: {String.to_integer(pid), String.to_integer(ppid), Enum.join(start, " "), Enum.join(command, " ")}
  end

  defp wait_gone(descendants, attempts) do
    running = MapSet.new(processes(), fn {pid, _ppid, start, _command} -> {pid, start} end)
    left = Enum.filter(descendants, fn {pid, _command, start} -> {pid, start} in running end)

    if left == [] or attempts == 0 do
      Enum.map(left, fn {pid, command, _start} -> {pid, command} end)
    else
      Process.sleep(200)
      wait_gone(descendants, attempts - 1)
    end
  end
end
