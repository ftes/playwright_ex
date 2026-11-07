defmodule PlaywrightEx.Library.Chromium.ConnectToWorkerTest do
  @upstream "tests/library/chromium/connect-to-worker.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.RemoteServer.ChildProcess
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Worker

  if System.get_env("BROWSER", "chromium") != "chromium", do: @moduletag(skip: "upstream skip: chromium only")

  # Deviations:
  #   * `childProcess({ command })` (tests/config/commonFixtures.ts) is a port running the command,
  #     its output collected by `wait_for_output/2`; `process.execPath` (the node running the
  #     client) is the driver's node. Node 22 (Ubuntu's) fails `worker.evaluate` with "Resulting
  #     promise was garbage collected" in most runs, with the JS client too. The node preloads
  #     `exit_on_stdin_eof.js` (`PlaywrightEx.RemoteServer.ChildProcess`), so that it exits when
  #     the test BEAM dies; `--inspect-brk` pauses it before the preload, until connected.
  #   * `(browserType as any)._connectToWorker(endpoint)` and `worker._disconnect()` are internal
  #     (not in the facade): client calls in an API scope.

  defp exec_path do
    case PlaywrightEx.Driver.executable() do
      {node, [_cli]} -> node
      # PLAYWRIGHT_EX_EXECUTABLE: a driver binary, not node.
      {_driver, []} -> System.find_executable("node")
    end
  end

  defp child_process(command) do
    {executable, args, env} = ChildProcess.exit_on_stdin_eof({hd(command), tl(command)})
    env = for {name, value} <- env, do: {String.to_charlist(name), String.to_charlist(value)}

    port =
      Port.open({:spawn_executable, executable}, [:binary, :stderr_to_stdout, :exit_status, args: args, env: env])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true) end)
    %{port: port, os_pid: os_pid}
  end

  # `child.waitForOutput(substring)`, returns `child.output` so far.
  defp wait_for_output(%{port: port} = child, substring, output \\ "") do
    if String.contains?(output, substring) do
      output
    else
      receive do
        {^port, {:data, data}} -> wait_for_output(child, substring, output <> data)
      after
        10_000 -> flunk("timed out waiting for #{inspect(substring)}, output: #{output}")
      end
    end
  end

  # `then` runs right after the call returns, as JS code right after `await` does. Unlike JS, the
  # connection keeps dispatching in between (OTP runtime), so an event of the new worker can precede
  # it (see the test below). Returns `{worker, then_result}`.
  defp connect_to_worker(browser_type, endpoint, then \\ fn _worker -> nil end) do
    Api.call("browserType._connectToWorker", browser_type, fn ->
      worker = PlaywrightEx.Client.BrowserType._connect_to_worker(browser_type, endpoint)
      {worker, then.(worker)}
    end)
  end

  # The driver resumes node before replying; an evaluate landing ~1 ms later runs mid-bootstrap
  # (node: setDispatchBufferFull is not a function) and the console can precede the subscription.
  # The gap from the reply to the evaluate's send was a `File.cwd!/0` per stack frame of each
  # call (`ClientStackTrace`): 1.5 ms (62 ms under load, 35 of 40 failed), now ~0.2 ms (1 of 40
  # under load, macOS, 2026-11-06).
  @tag skip: if(System.get_env("BROWSER", "chromium") != "chromium", do: "upstream skip: chromium only")
  test "CR-043 should connect, evaluate, receive console and disconnect", %{browser_type: browser_type} do
    child =
      child_process([
        exec_path(),
        "--inspect-brk=0",
        "-e",
        ~s[console.log("hello from node"); setTimeout(() => {}, 1e9)]
      ])

    output = wait_for_output(child, "Debugger listening on ws://")
    [_, endpoint] = Regex.run(~r/Debugger listening on (ws:\/\/\S+)/, output)
    # Script runs after connect due to --inspect-brk, so listen before evaluating.
    {worker, message_promise} = connect_to_worker(browser_type, endpoint, &Worker.wait_for_event(&1, :console))
    result = Worker.evaluate!(worker, "() => 1 + 1")
    assert result == 2
    message = PlaywrightEx.Promise.await!(message_promise)
    assert ConsoleMessage.text(message) == "hello from node"
    assert ConsoleMessage.type(message) == "log"
    # Disconnect and receive close event.
    close_promise = Worker.wait_for_event(worker, :close)
    Api.call("worker._disconnect", worker, fn -> PlaywrightEx.Client.Worker._disconnect(worker) end)
    PlaywrightEx.Promise.await!(close_promise)
  end

  test "CR-044 should receive close when node process exits", %{browser_type: browser_type} do
    child = child_process([exec_path(), "--inspect-brk=0", "-e", "setTimeout(() => {}, 1e9)"])
    output = wait_for_output(child, "Debugger listening on ws://")
    [_, endpoint] = Regex.run(~r/Debugger listening on (ws:\/\/\S+)/, output)
    {worker, nil} = connect_to_worker(browser_type, endpoint)
    close_promise = Worker.wait_for_event(worker, :close)
    # child.process.kill(): SIGTERM
    System.cmd("kill", [to_string(child.os_pid)])
    PlaywrightEx.Promise.await!(close_promise)
  end
end
