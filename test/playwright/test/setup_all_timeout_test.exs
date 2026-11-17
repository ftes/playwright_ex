defmodule Playwright.Test.SetupAllTimeoutTest do
  # The timeout of a module's `setup_all` callbacks (`Playwright.Test.SetupAllTimeout.run/2`),
  # here in a process standing in for ExUnit's `setup_all` process. A real module's:
  # `Playwright.Test.EndToEndTest`.
  use ExUnit.Case, async: true

  alias Playwright.Test.SetupAllTimeout

  if ExUnit.configuration()[:trace], do: @moduletag(skip: "mix test --trace has no timeouts")

  # A `setup_all` process running `fun` as its callbacks, then waiting as ExUnit's does.
  defp run_setup_all(timeout, fun) do
    {pid, ref} =
      spawn_monitor(fn ->
        SetupAllTimeout.run(%{module: __MODULE__, timeout: timeout}, fun)
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    ref
  end

  defp deep(0), do: Process.sleep(:infinity)
  defp deep(n), do: 1 + deep(n - 1)

  test "callbacks past the timeout: the process exits with upstream's message, renamed, and its stack" do
    ref = run_setup_all(100, fn -> Process.sleep(:infinity) end)
    assert_receive {:DOWN, ^ref, :process, _, {%RuntimeError{message: message}, stack}}, 5000
    assert message == ~s("setup_all" hook timeout of 100ms exceeded.)
    assert {Process, :sleep, 1, _} = hd(stack)
  end

  test "callbacks blocked deep in their stack time out too" do
    ref = run_setup_all(100, fn -> deep(100) end)
    assert_receive {:DOWN, ^ref, :process, _, {%RuntimeError{}, _stack}}, 5000
  end

  test "callbacks that ended in time: the process runs on past the timeout" do
    ref = run_setup_all(100, fn -> :ok end)
    refute_receive {:DOWN, ^ref, _, _, _}, 500
  end

  test "a nested run is part of the outer one's time" do
    ref = run_setup_all(100, fn -> SetupAllTimeout.run(%{timeout: :infinity}, fn -> Process.sleep(:infinity) end) end)
    assert_receive {:DOWN, ^ref, :process, _, {%RuntimeError{}, _stack}}, 5000
  end

  test "a pooled browser's time is not counted" do
    test_pid = self()

    ref =
      run_setup_all(1000, fn ->
        SetupAllTimeout.paused(fn -> Process.sleep(1500) end)
        send(test_pid, :waited)
        Process.sleep(300)
        send(test_pid, :in_time)
        Process.sleep(:infinity)
      end)

    assert_receive :waited, 5000
    assert_receive :in_time, 5000
    assert_receive {:DOWN, ^ref, :process, _, {%RuntimeError{}, _stack}}, 5000
  end

  test "callbacks that trap exits: killed a second later, unless they end before" do
    trapping = fn after_ms ->
      fn ->
        Process.flag(:trap_exit, true)
        Process.sleep(after_ms)
      end
    end

    ref = run_setup_all(100, trapping.(:infinity))
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 5000

    ref = run_setup_all(100, trapping.(500))
    refute_receive {:DOWN, ^ref, _, _, _}, 2000
  end

  test "no timeout: no watchdog" do
    ref = run_setup_all(:infinity, fn -> Process.sleep(:infinity) end)
    refute_receive {:DOWN, ^ref, _, _, _}, 500
  end
end
