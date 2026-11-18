defmodule Playwright.Test.ResultTest do
  # `Playwright.Test.info/1`: upstream's `testInfo.status`, `errors`, `expectedStatus` and
  # `duration` in teardown, on fake tests (a process registered as `use Playwright.Test`'s
  # setup does), whose `on_exit` runs in a process of its own here, as ExUnit's.
  use ExUnit.Case, async: true

  alias Playwright.Test.Pool
  alias Playwright.Test.Results

  defp fake_test(marked? \\ true) do
    parent = self()

    pid =
      spawn(fn ->
        context = %{
          test_pid: self(),
          module: __MODULE__,
          test: :"test t#{System.unique_integer([:positive])}",
          file: __ENV__.file,
          line: 1,
          "playwright.test": if(marked?, do: :marked)
        }

        send(parent, {:registered, Playwright.Test.__register__(context)})

        receive do
          {:end, messages, reason} ->
            Process.sleep(20)
            for message <- messages, do: Results.notify(message.(self()))
            exit(reason)
        end
      end)

    assert_receive {:registered, _test}

    # Its leases released, also when the test fails before the fake test's end.
    on_exit(fn ->
      Process.exit(pid, :kill)
      Pool.release(pid)
    end)

    pid
  end

  defp end_test(pid, messages, reason) do
    ref = Process.monitor(pid)
    send(pid, {:end, messages, reason})
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  # The test's `on_exit` callbacks in one process, as ExUnit runs them: `before` registered
  # after the registration (it runs first), `after` before it (it runs after its end).
  defp on_exit_callbacks(pid, before, after_end) do
    parent = self()

    {runner, ref} =
      spawn_monitor(fn ->
        first = before.()
        Playwright.Test.__finish__(pid, 5000)
        send(parent, {:results, first, after_end.()})
      end)

    assert_receive {:results, first, last}
    assert_receive {:DOWN, ^ref, :process, ^runner, _}
    {first, last}
  end

  # `fun` again until it raises, for half a second.
  defp until_raises(fun, tries \\ 50) do
    fun.()

    if tries > 1 do
      Process.sleep(10)
      until_raises(fun, tries - 1)
    end
  end

  test "in on_exit, before and after the recording's end: the test's result" do
    pid = fake_test()
    assert %{test_pid: ^pid, test_name: "t" <> _} = info = Playwright.Test.info(pid)
    refute Map.has_key?(info, :status)

    end_test(pid, [&{:failed, &1, {:error, %RuntimeError{message: "on purpose"}, []}}], :shutdown)
    {first, last} = on_exit_callbacks(pid, fn -> Playwright.Test.info(pid) end, fn -> Playwright.Test.info(pid) end)

    assert %{
             status: :failed,
             expected_status: :passed,
             errors: [%{message: "RuntimeError: on purpose"}],
             duration: duration
           } =
             first

    assert duration >= 20
    assert last == first
    # Gone with the on_exit process, once the pool saw its exit.
    assert_raise ArgumentError, ~r/no test/, fn -> until_raises(fn -> Playwright.Test.info(pid) end) end
  end

  # An unhandled error of a process of the fake test (`Playwright.Runtime.Callers.unhandled/4`).
  defp unhandled(pid, error) do
    Task.await(
      Task.async(fn ->
        Process.put(:"$callers", [pid])
        Playwright.Runtime.Callers.unhandled("", :error, error, [])
      end)
    )
  end

  # `Playwright.Test.TestInfo._unhandled_error/2`: the test's failure is the error, once.
  test "an unhandled error stops the test: its error once" do
    error = %RuntimeError{message: "listener boom"}

    interrupted = fake_test()
    ref = Process.monitor(interrupted)
    unhandled(interrupted, error)
    assert_receive {:DOWN, ^ref, :process, _, {^error, []}}, 5000
    assert %{status: :failed, errors: [%{message: "RuntimeError: listener boom"}]} = Playwright.Test.info(interrupted)

    # Once the body ended: logged, and nothing stops.
    ended = fake_test()
    assert Playwright.Test.TestInfo.finish(ended) == []
    assert ExUnit.CaptureLog.capture_log(fn -> unhandled(ended, error) end) =~ "listener boom"
    assert Process.alive?(ended)
    end_test(ended, [&{:passed, &1}], :shutdown)
    assert %{status: :passed, errors: []} = Playwright.Test.info(ended)

    for pid <- [interrupted, ended], do: on_exit_callbacks(pid, fn -> nil end, fn -> nil end)
  end

  test "passed, timed out, and unknown for another macro's test" do
    passed = fake_test()
    end_test(passed, [&{:passed, &1}], :shutdown)
    assert %{status: :passed, errors: []} = Playwright.Test.info(passed)

    killed = fake_test()
    end_test(killed, [], :killed)
    assert %{status: :timed_out, errors: [%{message: message}]} = Playwright.Test.info(killed)
    assert message == Results.killed()

    # Failed after the recorder closed its contexts at the test timeout.
    closed = fake_test()
    recorder = Results.recorder(closed)
    send(recorder, :test_timeout)
    :sys.get_state(recorder)

    end_test(
      closed,
      [&{:failed, &1, {:error, %RuntimeError{message: "Test timeout of 60000ms exceeded."}, []}}],
      :shutdown
    )

    assert %{status: :timed_out} = Playwright.Test.info(closed)

    assert {%{status: :timed_out}, %{status: :timed_out}} =
             on_exit_callbacks(closed, fn -> Playwright.Test.info(closed) end, fn ->
               Playwright.Test.info(closed)
             end)

    unmarked = fake_test(false)
    end_test(unmarked, [], :shutdown)
    assert %{status: nil, errors: []} = Playwright.Test.info(unmarked)

    for pid <- [passed, killed, unmarked], do: on_exit_callbacks(pid, fn -> nil end, fn -> nil end)
  end

  test "the finish of a test whose registration row is gone (the pool restarted) leaves the pool running" do
    pid = fake_test()
    end_test(pid, [&{:passed, &1}], :shutdown)
    pool = Process.whereis(Pool)
    :ets.delete(Results.table(), {:test, pid})

    assert Results.take(pid) == {nil, nil}

    assert ExUnit.CaptureLog.capture_log(fn -> on_exit_callbacks(pid, fn -> nil end, fn -> nil end) end) =~
             "could not finish the test: its registration is gone (the pool restarted since)"

    assert Process.whereis(Pool) == pool
  end
end
