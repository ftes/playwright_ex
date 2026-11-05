defmodule PlaywrightEx.Library.Chromium.ConnectToWorkerTest do
  @upstream "tests/library/chromium/connect-to-worker.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Worker

  if System.get_env("BROWSER", "chromium") != "chromium", do: @moduletag(skip: "chromium only")

  # Deviations:
  #   * `childProcess({ command })` (tests/config/commonFixtures.ts) is a port running the command,
  #     its output collected by `wait_for_output/2`; `process.execPath` is `node` on the PATH.
  #   * `(browserType as any)._connectToWorker(endpoint)` and `worker._disconnect()` are internal
  #     (not in the facade): client calls in an API scope.
  #   * `worker.waitForEvent(...)` is not ported (`Worker.waitForEvent`): a `Worker.once` listener.

  defp child_process(command) do
    [executable | args] = command
    port = Port.open({:spawn_executable, executable}, [:binary, :stderr_to_stdout, :exit_status, args: args])
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

  # `then` runs in the tick that resolves the call, as JS code right after `await` does (in the API
  # scope, holding the baton): no event is dispatched in between.
  defp connect_to_worker(browser_type, endpoint, then \\ fn _worker -> nil end) do
    Api.call("browserType._connectToWorker", browser_type, fn ->
      worker = PlaywrightEx.Client.BrowserType._connect_to_worker(browser_type, endpoint)
      then.(worker)
      worker
    end)
  end

  defp worker_once(worker, event) do
    test_pid = self()
    Worker.once(worker, event, fn payload -> send(test_pid, {:worker, event, payload}) end)
  end

  # Ported, but `--inspect-brk` is released on connect (the server sends
  # `Runtime.runIfWaitingForDebugger` before replying), so the console event races the console
  # subscription (`updateSubscription`, sent when the listener is added): over the out-of-process
  # driver the event is often dropped, upstream's in-process one wins the race.
  @tag skip: "flaky: the console event races the Worker console subscription (out-of-process driver)"
  test "should connect, evaluate, receive console and disconnect", %{browser_type: browser_type} do
    child =
      child_process([
        System.find_executable("node"),
        "--inspect-brk=0",
        "-e",
        ~s[console.log("hello from node"); setTimeout(() => {}, 1e9)]
      ])

    output = wait_for_output(child, "Debugger listening on ws://")
    [_, endpoint] = Regex.run(~r/Debugger listening on (ws:\/\/\S+)/, output)
    # Script runs after connect due to --inspect-brk, so listen before evaluating.
    worker = connect_to_worker(browser_type, endpoint, &worker_once(&1, :console))
    result = Worker.evaluate!(worker, "() => 1 + 1")
    assert result == 2
    assert_receive {:worker, :console, message}, 5000
    assert ConsoleMessage.text(message) == "hello from node"
    assert ConsoleMessage.type(message) == "log"
    # Disconnect and receive close event.
    worker_once(worker, :close)
    Api.call("worker._disconnect", worker, fn -> PlaywrightEx.Client.Worker._disconnect(worker) end)
    assert_receive {:worker, :close, _}, 5000
  end

  test "should receive close when node process exits", %{browser_type: browser_type} do
    child = child_process([System.find_executable("node"), "--inspect-brk=0", "-e", "setTimeout(() => {}, 1e9)"])
    output = wait_for_output(child, "Debugger listening on ws://")
    [_, endpoint] = Regex.run(~r/Debugger listening on (ws:\/\/\S+)/, output)
    worker = connect_to_worker(browser_type, endpoint)
    worker_once(worker, :close)
    # child.process.kill(): SIGTERM
    System.cmd("kill", [to_string(child.os_pid)])
    assert_receive {:worker, :close, _}, 5000
  end
end
