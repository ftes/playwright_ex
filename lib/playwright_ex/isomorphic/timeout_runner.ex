defmodule PlaywrightEx.Isomorphic.TimeoutRunner do
  @upstream "packages/isomorphic/timeoutRunner.ts"
  @moduledoc "Port of `#{@upstream}`."

  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise

  def race_against_deadline(cb, deadline) do
    # `let timer` assigned in the executor: the executor runs synchronously, so it is computed first.
    timed_out = Promise.new()

    timer =
      if deadline != 0,
        do:
          EventLoop.set_timeout(
            fn -> Promise.resolve(timed_out, %{timedOut: true}) end,
            max(0, round(deadline - monotonic_time()))
          )

    # Note: not including "await" here truncates the async stack inside cb(), so always include it.
    try do
      Promise.await(
        Promise.race([
          Promise.then_(Promise.async(cb), fn result -> %{result: result, timedOut: false} end),
          timed_out
        ])
      )
    after
      EventLoop.clear_timeout(timer)
    end
  end

  # pollAgainstDeadline  -- not ported

  # isomorphic/time.ts monotonicTime(), in milliseconds.
  defp monotonic_time, do: System.monotonic_time(:millisecond)
end
