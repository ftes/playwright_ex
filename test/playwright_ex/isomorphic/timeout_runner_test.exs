defmodule PlaywrightEx.Isomorphic.TimeoutRunnerTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Isomorphic.TimeoutRunner
  alias PlaywrightEx.Runtime.Invocation

  test "a result that comes after the deadline leaves no message" do
    cb = fn ->
      # The caller races once cb yields (awaits), as in JS.
      Invocation.yield()
      Process.sleep(50)
      :late
    end

    deadline = System.monotonic_time(:millisecond) + 10
    assert TimeoutRunner.race_against_deadline(cb, deadline) == %{timedOut: true}
    Process.sleep(100)
    refute_received _
  end

  test "a result before the deadline" do
    deadline = System.monotonic_time(:millisecond) + 60_000
    assert TimeoutRunner.race_against_deadline(fn -> :ok end, deadline) == %{result: :ok, timedOut: false}
    refute_received _
  end
end
