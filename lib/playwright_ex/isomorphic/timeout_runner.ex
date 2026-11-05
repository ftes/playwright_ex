defmodule PlaywrightEx.Isomorphic.TimeoutRunner do
  @upstream "packages/isomorphic/timeoutRunner.ts"
  @moduledoc "Port of `#{@upstream}`."

  alias PlaywrightEx.Runtime.Promise

  def race_against_deadline(cb, deadline) do
    # `let timer` assigned in the executor: the executor runs synchronously, so it is computed first.
    timer = if deadline != 0, do: Promise.timer(max(0, round(deadline - monotonic_time())))
    timed_out = if timer, do: [Promise.then_(timer, fn _ -> %{timedOut: true} end)], else: []

    # Note: not including "await" here truncates the async stack inside cb(), so always include it.
    try do
      Promise.await(
        Promise.race([
          Promise.then_(Promise.async(cb), fn result -> %{result: result, timedOut: false} end) | timed_out
        ])
      )
    after
      if timer, do: Promise.free(timer)
    end
  end

  # pollAgainstDeadline  -- not ported

  # isomorphic/time.ts monotonicTime(), in milliseconds.
  defp monotonic_time, do: System.monotonic_time(:millisecond)
end
