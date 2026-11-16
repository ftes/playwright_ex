defmodule PlaywrightEx.TracedCalls do
  @moduledoc """
  The calls of a function by one process, from `:erlang.trace/3`'s messages sent to the test
  process: unlike `call_count`, not the calls of other async tests' traced processes.
  """
  import ExUnit.Assertions

  @doc "The calls of `mod.fun` by `pid` traced so far, taking their messages."
  def traced_calls(pid, {mod, fun}) do
    ref = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^ref}
    count(pid, mod, fun, 0)
  end

  defp count(pid, mod, fun, count) do
    receive do
      {:trace, ^pid, :call, {^mod, ^fun, _args}} -> count(pid, mod, fun, count + 1)
    after
      0 -> count
    end
  end
end
