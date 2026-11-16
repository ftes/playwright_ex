defmodule PlaywrightEx.Matchers.ToPassTest do
  # `expect(callback).toPass()` and `expect.poll(callback).<matcher>` (`Expect.to_pass/2`,
  # `Expect.poll/3`), in a `PlaywrightEx.Test` test and outside one. Their steps:
  # `PlaywrightEx.Test.StepsTest`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Expect
  alias PlaywrightEx.ExpectError
  alias PlaywrightEx.Test.TestInfo

  # A counter of the calls, `n` from 0.
  defp counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    fn -> Agent.get_and_update(agent, &{&1, &1 + 1}) end
  end

  # Outside any test: no `testInfo`.
  defp outside(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      fun.()
    end)
    |> Task.await(:infinity)
  end

  describe "to_pass" do
    test "retries the callback until it returns, in the calling process" do
      next = counter()
      test_pid = self()

      assert :ok =
               Expect.to_pass!(fn ->
                 assert self() == test_pid
                 assert next.() >= 2
               end)
    end

    test "waits the intervals between tries, the last one repeated" do
      {:ok, times} = Agent.start_link(fn -> [] end)

      {:error, %ExpectError{}} =
        Expect.to_pass(
          fn ->
            Agent.update(times, &[System.monotonic_time(:millisecond) | &1])
            raise "not yet"
          end,
          intervals: [50, 100],
          timeout: 420
        )

      gaps = times |> Agent.get(&Enum.reverse/1) |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
      # 50, 100, 100, 100 (then 0 + 350 + 100 would pass the deadline).
      assert [first, second | rest] = gaps
      assert first in 50..90 and second in 100..140
      assert rest != [] and Enum.all?(rest, &(&1 in 100..140))
    end

    test "fails at its timeout with the last error and the call log" do
      next = counter()

      assert {:error, %ExpectError{message: message, matcherResult: %{name: "toPass", pass: false}}} =
               Expect.to_pass(fn -> assert next.() == -1 end, timeout: 300)

      assert message =~ ~r/\AAssertion with == failed\ncode:  assert next.\(\) == -1\nleft:  \d+\nright: -1\n/
      assert String.ends_with?(message, "\n\nCall Log:\n- Timeout 300ms exceeded while waiting on the predicate")
    end

    # The recorder closes the contexts 150 ms (5%) before ExUnit's 3 s timeout; toPass ends 250 ms
    # before that, or sooner when its next 1 s interval would pass it.
    @tag timeout: 3_000
    test "without a timeout: until just before the test's timeout, then fails with the last error" do
      started = System.monotonic_time(:millisecond)

      assert {:error, %ExpectError{message: message}} = Expect.to_pass(fn -> raise "never" end)
      assert message == "never\n\nCall Log:\n- Test timeout of 3000ms exceeded"
      assert (System.monotonic_time(:millisecond) - started) in 1_500..2_600

      assert {:error, %ExpectError{message: message}} = Expect.to_pass(fn -> raise "never" end, timeout: 100)
      assert message =~ "Timeout 100ms exceeded"
    end

    @tag timeout: 3_000
    test "a timeout past the test's: the test's message" do
      assert {:error, %ExpectError{message: message}} = Expect.poll(fn -> 1 end, &assert(&1 == 2), timeout: 60_000)
      assert message =~ "- Test timeout of 3000ms exceeded"
    end

    test "retries exits and throws too" do
      next = counter()

      assert :ok =
               Expect.to_pass!(fn ->
                 case next.() do
                   0 -> exit(:not_yet)
                   1 -> throw(:not_yet)
                   _ -> :ok
                 end
               end)

      assert {:error, %ExpectError{message: "** (exit) :late\n\nCall Log:\n" <> _}} =
               Expect.to_pass(fn -> exit(:late) end, timeout: 100)
    end

    test "not: passes once the callback fails, fails while it passes" do
      next = counter()
      assert :ok = Expect.not_to_pass!(fn -> if next.() >= 1, do: raise("now") end)
      assert :ok = fn -> raise "at once" end |> Expect.not_() |> Expect.to_pass!()

      assert {:error, %ExpectError{message: "Timeout 100ms exceeded while waiting on the predicate"}} =
               Expect.not_to_pass(fn -> :ok end, timeout: 100)
    end

    test "soft: the test fails at its end, the body continues" do
      assert :ok = fn -> raise "soft" end |> Expect.soft() |> Expect.to_pass!(timeout: 100)

      assert [{:error, %ExpectError{message: "soft\n\nCall Log:\n" <> _}, _}] = TestInfo.take_errors(self())
    end

    test "outside a test: no deadline without a timeout, a soft one fails at once" do
      outside(fn ->
        assert TestInfo.current() == nil
        next = counter()
        assert :ok = Expect.to_pass!(fn -> assert next.() >= 1 end)

        assert_raise ExpectError, ~r/^outside/, fn ->
          fn -> raise "outside" end |> Expect.soft() |> Expect.to_pass!(timeout: 100)
        end
      end)
    end
  end

  describe "poll" do
    test "polls the callback until the assertion passes" do
      next = counter()
      test_pid = self()

      assert :ok =
               Expect.poll!(
                 fn ->
                   assert self() == test_pid
                   next.()
                 end,
                 &assert(&1 == 3)
               )
    end

    test "fails at its timeout with the assertion's last error, the custom message first" do
      assert {:error, %ExpectError{message: message, matcherResult: %{name: "assert", pass: false}}} =
               Expect.poll(fn -> 1 end, &assert(&1 == 2), timeout: 300, message: "make sure it is 2")

      assert message =~ ~r/\Amake sure it is 2\n\nAssertion with == failed\n/
      assert String.ends_with?(message, "\n\nCall Log:\n- Timeout 300ms exceeded while waiting on the predicate")
    end

    test "a raising callback fails it at once, as upstream's" do
      assert {:error, %RuntimeError{message: "boom"}} = Expect.poll(fn -> raise "boom" end, &assert(&1))
    end

    test "a negated receiver raises: negate in the assertion" do
      assert_raise ArgumentError, ~r/refute in the assertion/, fn ->
        fn -> 1 end |> Expect.not_() |> Expect.poll(&assert(&1 == 1))
      end

      assert :ok = Expect.poll!(fn -> 1 end, &refute(&1 == 2))
    end

    test "soft: the test fails at its end, the body continues" do
      assert :ok = fn -> 1 end |> Expect.soft() |> Expect.poll!(&assert(&1 == 2), timeout: 100)
      assert [{:error, %ExpectError{message: "Assertion with == failed" <> _}, _}] = TestInfo.take_errors(self())
    end
  end
end
