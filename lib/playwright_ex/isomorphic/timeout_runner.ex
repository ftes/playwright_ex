defmodule PlaywrightEx.Isomorphic.TimeoutRunner do
  @upstream "packages/isomorphic/timeoutRunner.ts"
  @moduledoc "Port of `#{@upstream}`."

  alias PlaywrightEx.Runtime.Promise

  def race_against_deadline(cb, deadline) do
    # `let timer` assigned in the executor: the executor runs synchronously, so it is computed first.
    # `if (!deadline)`: 0 and undefined mean no deadline.
    timer = if deadline not in [nil, 0], do: Promise.timer(max(0, round(deadline - monotonic_time())))
    timed_out = if timer, do: [Promise.then_(timer, fn _ -> %{timedOut: true} end)], else: []

    # Note: not including "await" here truncates the async stack inside cb(), so always include it.
    result = Promise.async(cb)

    try do
      Promise.await(
        Promise.race([
          Promise.then_(result, fn result -> %{result: result, timedOut: false} end) | timed_out
        ])
      )
    after
      if timer, do: Promise.free(timer)
      # Elixir only: a result that comes after the deadline is dropped, not left in the mailbox.
      Promise.free(result)
    end
  end

  # `callback` returns `%{continuePolling: boolean, result: term}`; the result is
  # `%{result: term | nil, timedOut: boolean}`. `deadline` is monotonic milliseconds, `nil`, `0`
  # or `:infinity` for none (deviation: BEAM's monotonic clock may be any integer, so no
  # deadline is not only `0`, and the test runner's `kMaxDeadline` is `:infinity`).
  def poll_against_deadline(callback, deadline, poll_intervals \\ [100, 250, 500, 1000]) do
    # const lastPollInterval = pollIntervals.pop() ?? 1000;
    {last_poll_interval, poll_intervals} =
      case Enum.reverse(poll_intervals) do
        [last | rest] -> {last, Enum.reverse(rest)}
        [] -> {1000, []}
      end

    # const wrappedCallback = () => Promise.resolve().then(callback);  -- not ported: no microtasks
    poll_loop(callback, deadline, poll_intervals, last_poll_interval, nil)
  end

  defp poll_loop(callback, deadline, poll_intervals, last_poll_interval, last_result) do
    time = monotonic_time()

    if deadline?(deadline) and time >= deadline do
      %{timedOut: true, result: last_result}
    else
      # deviation: `callback` runs in the calling process, not raced against the deadline
      # (`raceAgainstDeadline`): a process can't be interrupted, and racing would run it in
      # another one, with another `self()`, mailbox and process dictionary than the caller's.
      # A callback that runs past the deadline overruns it; the next check below ends the loop.
      received = callback.()
      last_result = received.result

      if !received.continuePolling do
        %{result: last_result, timedOut: false}
      else
        {interval, poll_intervals} =
          case poll_intervals do
            [interval | rest] -> {interval, rest}
            [] -> {last_poll_interval, []}
          end

        if deadline?(deadline) and deadline <= monotonic_time() + interval do
          %{timedOut: true, result: last_result}
        else
          Process.sleep(interval)
          poll_loop(callback, deadline, poll_intervals, last_poll_interval, last_result)
        end
      end
    end
  end

  # `if (deadline && ...)`: 0 and undefined mean no deadline.
  defp deadline?(deadline), do: deadline not in [nil, 0, :infinity]

  # isomorphic/time.ts monotonicTime(), in milliseconds.
  defp monotonic_time, do: System.monotonic_time(:millisecond)
end
