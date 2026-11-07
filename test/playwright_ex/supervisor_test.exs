defmodule PlaywrightEx.SupervisorTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Heap

  test "drivers of different names share a supervision tree" do
    names = [__MODULE__.One, __MODULE__.Two]

    start_supervised!(%{
      id: :tree,
      start:
        {Supervisor, :start_link, [for(n <- names, do: {PlaywrightEx.Supervisor, name: n}), [strategy: :one_for_one]]}
    })

    for name <- names, do: assert(BrowserType.name(Playwright.chromium(PlaywrightEx.playwright(name))) == "chromium")
  end

  test "after the driver exits, a new one starts and handles of the old one fail with TargetClosedError" do
    name = __MODULE__.Restart
    start_supervised!({PlaywrightEx.Supervisor, name: name})
    playwright = PlaywrightEx.playwright(name)

    %{port: port} = :sys.get_state(Heap.get(playwright, :driverProcess))
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-9", to_string(os_pid)])

    assert {:error, %PlaywrightEx.TargetClosedError{}} =
             BrowserType.launch(Playwright.chromium(playwright), timeout: 1_000)

    restarted = restarted(name, playwright)
    assert restarted != playwright
    assert BrowserType.name(Playwright.chromium(restarted)) == "chromium"
  end

  @tag :tmp_dir
  test "a driver that exits before it answers initialize fails the start", %{tmp_dir: tmp_dir} do
    executable = Path.join(tmp_dir, "playwright")
    File.write!(executable, "#!/bin/sh\nexit 3\n")
    File.chmod!(executable, 0o755)

    assert {:error, {{:shutdown, {:failed_to_start_child, _, {:shutdown, {:driver_closed, 3}}}}, _}} =
             start_supervised({PlaywrightEx.Supervisor, name: __MODULE__.Exits, executable: executable})
  end

  @tag :tmp_dir
  test "a connection process that exits during initialize fails the start with its exit", %{tmp_dir: tmp_dir} do
    # A driver that never answers.
    executable = Path.join(tmp_dir, "playwright")
    File.write!(executable, "#!/bin/sh\nexec cat >/dev/null\n")
    File.chmod!(executable, 0o755)
    name = __MODULE__.ConnectionExits
    spawn_link(fn -> kill_connection_in_initialize(PlaywrightEx.Supervisor.out_of_process(name)) end)

    assert {:error, {{:shutdown, {:failed_to_start_child, _, {:shutdown, {:connection_exit, :killed}}}}, _}} =
             start_supervised({PlaywrightEx.Supervisor, name: name, executable: executable})
  end

  test "a call that cannot be encoded fails alone, the driver stays" do
    name = __MODULE__.Unencodable
    start_supervised!({PlaywrightEx.Supervisor, name: name})
    playwright = PlaywrightEx.playwright(name)
    chromium = Playwright.chromium(playwright)

    assert {:error, %PlaywrightEx.PlaywrightError{message: message}} =
             BrowserType.launch(chromium, executable_path: <<0xFF>>, timeout: 1_000)

    assert message =~ "cannot be encoded as JSON"
    assert PlaywrightEx.playwright(name) == playwright
    assert BrowserType.name(chromium) == "chromium"
  end

  defp kill_connection_in_initialize(out_of_process) do
    with pid when is_pid(pid) <- Process.whereis(out_of_process),
         {:current_stacktrace, stack} <- Process.info(pid, :current_stacktrace),
         true <- Enum.any?(stack, &match?({PlaywrightEx.OutOfProcess, :initialize, 3, _}, &1)),
         {:links, links} <- Process.info(pid, :links),
         conn when is_pid(conn) <- Enum.find(links, &connection?/1) do
      Process.exit(conn, :kill)
    else
      _ ->
        Process.sleep(5)
        kill_connection_in_initialize(out_of_process)
    end
  end

  defp connection?(pid) do
    is_pid(pid) and
      match?({:dictionary, %{"$initial_call": {PlaywrightEx.Runtime.Conn, :init, 1}}}, dictionary(pid))
  end

  defp dictionary(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, entries} -> {:dictionary, Map.new(entries)}
      nil -> nil
    end
  end

  # The root of the restarted driver (`playwright/1` exits while there is none).
  defp restarted(name, old, attempts \\ 100) do
    new =
      try do
        PlaywrightEx.playwright(name)
      catch
        :exit, _ -> nil
      end

    cond do
      new not in [nil, old] -> new
      attempts > 0 -> Process.sleep(50) && restarted(name, old, attempts - 1)
      true -> flunk("driver did not restart")
    end
  end
end
