defmodule PlaywrightEx.Library.Unit.TimeoutRunnerTest do
  @upstream "tests/library/unit/timeout-runner.spec.ts"
  # Deviation: plain ExUnit case, this spec tests the isomorphic TimeoutRunner without a browser.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Isomorphic.TimeoutRunner
  alias PlaywrightEx.Runtime.Promise

  @moduletag upstream: @upstream

  test "TO-001 raceAgainstDeadline should not emit TimeoutNegativeWarning for a passed deadline" do
    # Deviation: Node's `process.on('warning')` has no counterpart; a negative delay would make
    # `set_timeout` (`Process.send_after`) raise, so resolving at all is the check.
    result =
      TimeoutRunner.race_against_deadline(
        fn -> Promise.await(Promise.new()) end,
        System.monotonic_time(:millisecond) - 1
      )

    assert result.timedOut == true
  end
end
