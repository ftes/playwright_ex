defmodule PlaywrightEx.Library.Unit.TimeoutRunnerTest do
  @upstream "tests/library/unit/timeout-runner.spec.ts"
  # Deviation: plain ExUnit case, this spec tests the isomorphic TimeoutRunner without a browser.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Isomorphic.TimeoutRunner
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise

  @moduletag upstream: @upstream

  setup do
    %{loop: EventLoop.get(start_supervised!(EventLoop))}
  end

  test "raceAgainstDeadline should not emit TimeoutNegativeWarning for a passed deadline", %{loop: loop} do
    # Deviation: Node's `process.on('warning')` has no counterpart; a negative delay would make
    # `set_timeout` (`Process.send_after`) raise, so resolving at all is the check.
    result =
      EventLoop.with_baton(loop, fn ->
        TimeoutRunner.race_against_deadline(
          fn -> Promise.await(Promise.new()) end,
          System.monotonic_time(:millisecond) - 1
        )
      end)

    assert result.timedOut == true
  end
end
