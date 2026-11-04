defmodule PlaywrightEx.Client.ConnectionTracingTest do
  # Not async: `capture_log` sees the logs of tests running concurrently (event_loop_test logs on purpose).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Playwright

  @moduletag timeout: 120_000

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    %{playwright: PlaywrightEx.playwright(__MODULE__)}
  end

  # connection.ts sendMessageToServer: `if (this._tracingCount && frames && type !== 'LocalUtils')
  # this._localUtils?.addStackToTracingNoReply(...).catch(() => {})` -- an async call without await.
  test "while tracing, each call first sends its stack to LocalUtils", %{playwright: playwright} do
    test = self()
    connection = get(playwright, :_connection)
    onmessage = get(connection, :onmessage)

    put(connection, :onmessage, fn message ->
      send(test, {:sent, message})
      onmessage.(message)
    end)

    put(connection, :_tracingCount, 1)

    log =
      capture_log(fn ->
        browser = BrowserType.launch!(Playwright.chromium(playwright))
        put(connection, :_tracingCount, 0)
        Browser.close!(browser)
      end)

    put(connection, :onmessage, onmessage)

    assert_received {:sent, %{method: stack_method, id: stack_id, params: %{callData: %{id: launch_id, stack: stack}}}}
    assert to_string(stack_method) == "addStackToTracingNoReply"
    assert [%{file: _, line: _} | _] = stack
    # sent before the call it describes, as JS runs the async function up to its first await
    assert_received {:sent, %{method: launch_method, id: ^launch_id}}
    assert to_string(launch_method) == "launch"

    # the driver replied: the callback is gone and nothing was swallowed by `.catch`
    assert map_get(connection, :_callbacks, stack_id) == nil
    refute log =~ "Uncaught"
  end
end
