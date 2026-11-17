defmodule Playwright.Test.SetupAllTimeoutTest do
  # The watchdog of a `setup_all` process (`Playwright.Test.SetupAllTimeout`), here on a process
  # that runs a fake module's `__ex_unit__/2`, as ExUnit's runner runs a module's callbacks. The
  # timeout of a real `setup_all`: `Playwright.Test.EndToEndTest`.
  use ExUnit.Case, async: true

  alias Playwright.Test.SetupAllTimeout

  if ExUnit.configuration()[:trace], do: @moduletag(skip: "mix test --trace has no timeouts")

  defmodule FakeCase do
    # As ExUnit's compiled callbacks: the call keeps its frame.
    def __ex_unit__(:setup_all, fun) do
      result = fun.()
      ExUnit.Callbacks.__noop__()
      result
    end
  end

  # A `setup_all` process running `fun` as its callbacks, then waiting as ExUnit's does.
  defp run_setup_all(timeout, fun) do
    {pid, ref} =
      spawn_monitor(fn ->
        FakeCase.__ex_unit__(:setup_all, fn ->
          SetupAllTimeout.start(%{module: FakeCase, timeout: timeout})
          fun.()
        end)

        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    ref
  end

  test "callbacks past the timeout: the process exits with upstream's message and its stack" do
    ref = run_setup_all(100, fn -> Process.sleep(:infinity) end)
    assert_receive {:DOWN, ^ref, :process, _, {%RuntimeError{message: message}, stack}}, 1000
    assert message == ~s("setup_all" hook timeout of 100ms exceeded.)
    assert {Process, :sleep, 1, _} = hd(stack)
  end

  test "callbacks that ended in time: the process runs on past the timeout" do
    ref = run_setup_all(100, fn -> :ok end)
    refute_receive {:DOWN, ^ref, _, _, _}, 300
  end

  test "a wait for a seat is not counted" do
    test_pid = self()

    ref =
      run_setup_all(200, fn ->
        SetupAllTimeout.paused(fn -> Process.sleep(300) end)
        send(test_pid, :waited)
        Process.sleep(150)
        send(test_pid, :in_time)
        Process.sleep(:infinity)
      end)

    assert_receive :waited, 1000
    assert_receive :in_time, 1000
    assert_receive {:DOWN, ^ref, :process, _, {%RuntimeError{}, _stack}}, 1000
  end

  test "no timeout: no watchdog" do
    ref = run_setup_all(:infinity, fn -> Process.sleep(:infinity) end)
    refute_receive {:DOWN, ^ref, _, _, _}, 300
  end
end
