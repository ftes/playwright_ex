defmodule PlaywrightEx.Test.ResultTest do
  # `PlaywrightEx.Test.info/1`: upstream's `testInfo.status`, `errors`, `expectedStatus` and
  # `duration` in teardown, on fake tests (a process registered as `use PlaywrightEx.Test`'s
  # setup does), whose `on_exit` runs in a process of its own here, as ExUnit's.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.Pool

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
          playwright_ex: if(marked?, do: :marked)
        }

        send(parent, {:registered, PlaywrightEx.Test.__register__(context)})

        receive do
          {:end, messages, reason} ->
            Process.sleep(20)
            for message <- messages, do: Pool.notify(message.(self()))
            exit(reason)
        end
      end)

    assert_receive {:registered, _test}
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
        PlaywrightEx.Test.__finish__(pid, 5000)
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
    assert %{test_pid: ^pid, test_name: "t" <> _} = info = PlaywrightEx.Test.info(pid)
    refute Map.has_key?(info, :status)

    end_test(pid, [&{:failed, &1, {:error, %RuntimeError{message: "on purpose"}, []}}], :shutdown)
    {first, last} = on_exit_callbacks(pid, fn -> PlaywrightEx.Test.info(pid) end, fn -> PlaywrightEx.Test.info(pid) end)

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
    assert_raise ArgumentError, ~r/no test/, fn -> until_raises(fn -> PlaywrightEx.Test.info(pid) end) end
  end

  test "passed, timed out, and unknown for another macro's test" do
    passed = fake_test()
    end_test(passed, [&{:passed, &1}], :shutdown)
    assert %{status: :passed, errors: []} = PlaywrightEx.Test.info(passed)

    killed = fake_test()
    end_test(killed, [], :killed)
    assert %{status: :timed_out, errors: [%{message: message}]} = PlaywrightEx.Test.info(killed)
    assert message == Pool.killed()

    # Failed after the recorder closed its contexts at the test timeout.
    closed = fake_test()
    recorder = Pool.recorder(closed)
    send(recorder, :test_timeout)
    :sys.get_state(recorder)

    end_test(
      closed,
      [&{:failed, &1, {:error, %RuntimeError{message: "Test timeout of 60000ms exceeded."}, []}}],
      :shutdown
    )

    assert %{status: :timed_out} = PlaywrightEx.Test.info(closed)

    assert {%{status: :timed_out}, %{status: :timed_out}} =
             on_exit_callbacks(closed, fn -> PlaywrightEx.Test.info(closed) end, fn ->
               PlaywrightEx.Test.info(closed)
             end)

    unmarked = fake_test(false)
    end_test(unmarked, [], :shutdown)
    assert %{status: nil, errors: []} = PlaywrightEx.Test.info(unmarked)

    for pid <- [passed, killed, unmarked], do: on_exit_callbacks(pid, fn -> nil end, fn -> nil end)
  end
end
