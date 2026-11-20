defmodule Playwright.Test.AssertionsTest do
  # `use Playwright.Test`'s `assert` and `refute`: ExUnit's, each also an `expect` step of the
  # test's `test.trace`. A failure in the test's body as ExUnit reports it: `Playwright.Test.EndToEndTest`.
  use ExUnit.Case, async: true

  @this_file __ENV__.file

  alias Playwright.Expect
  alias Playwright.Test
  alias Playwright.Test.TestInfo

  @moduletag Playwright.Test.use(trace: :on)

  # The checks of `on_trace/1`, by test pid, in a table of the module's.
  setup_all do
    :ets.new(__MODULE__, [:public, :named_table])
    :ok
  end

  # Before the registration, so its `on_exit` runs after the test's end saved its trace.
  setup _ctx do
    test_pid = self()

    on_exit(fn ->
      dir = Playwright.Test.info(test_pid).output_dir

      with [{_, fun}] <- :ets.take(__MODULE__, test_pid) do
        {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "trace.zip")), [:memory])
        {_, trace} = List.keyfind(files, ~c"test.trace", 0)
        fun.(for(line <- String.split(trace, "\n"), do: JSON.decode!(line)))
      end

      File.rm_rf!(dir)
    end)
  end

  use Playwright.Test

  setup_all do
    # In `setup_all`, as `step/3` there: recorded nowhere.
    assert Test.step("in setup_all", fn -> 1 end) == 1
    refute nil
    assert_raise ExUnit.AssertionError, fn -> Test.step("fails in setup_all", fn -> assert 1 == 2 end) end
    :ok
  end

  # `fun` gets the `test.trace` events of the test's `trace.zip`, once its recording finished.
  defp on_trace(fun), do: :ets.insert(__MODULE__, {self(), fun})

  # The source line `line` of this file.
  defp source(line), do: __ENV__.file |> File.read!() |> String.split("\n") |> Enum.at(line - 1)

  defp befores(events), do: for(%{"type" => "before"} = event <- events, do: event)
  defp before(events, title), do: Enum.find(befores(events), &(&1["title"] == title))
  defp after_of(events, %{"callId" => id}), do: Enum.find(events, &(&1["type"] == "after" and &1["callId"] == id))

  defp located_at(%{"stack" => [%{"file" => @this_file, "line" => line} | _]}, code), do: source(line) =~ code

  test "a passed assert or refute is an expect step: its expression the subtitle and param, located at its call" do
    on_trace(fn events ->
      assert [one, two, three, four] = befores(events)
      assert %{"class" => "Test", "method" => "expect", "title" => ~s(Expect "assert")} = one
      assert %{"params" => %{"expression" => "1 + 1 == 2"}} = one
      assert located_at(one, "assert 1 + 1 == 2")
      refute Map.has_key?(one, "parentId")
      assert %{"title" => "Expect \"refute\"", "params" => %{"expression" => "Enum.empty?([1])"}} = two
      assert located_at(two, "refute Enum.empty?([1])")
      assert %{"title" => "the sum", "params" => %{"expression" => "1 + 2 == 3"}} = three
      assert located_at(three, ~s(assert 1 + 2 == 3, "the sum"))
      assert %{"title" => "no sum", "params" => %{"expression" => "1 + 2 == 4"}} = four

      for event <- [one, two, three, four] do
        assert event["stack"] |> hd() |> Map.fetch!("file") == @this_file
        assert %{"endTime" => _} = after_of(events, event)
        refute after_of(events, event)["error"]
      end
    end)

    assert 1 + 1 == 2
    refute Enum.empty?([1])
    assert 1 + 2 == 3, "the sum"
    refute 1 + 2 == 4, "no sum"
  end

  test "an assertion binds and returns as ExUnit's, and fails with ExUnit's error at the same place" do
    assert {:ok, x} = {:ok, 1}
    assert (y = x + 1) > 0
    assert {:ok, z} = {:ok, y + 1}, "binds with a message"
    assert {x, y, z} == {1, 2, 3}
    assert assert({:ok, _} = {:ok, :value}) == {:ok, :value}
    assert refute(nil) == nil

    ours = assertion_error(fn -> Test.step("fails", fn -> assert 1 + 1 == 3 end) end)
    exunit = assertion_error(fn -> Test.step("fails", fn -> ExUnit.Assertions.assert(1 + 1 == 3) end) end)
    # Their `expr`s differ only by their lines.
    assert %{ours.error | expr: nil} == %{exunit.error | expr: nil}
    assert Macro.to_string(ours.error.expr) == Macro.to_string(exunit.error.expr)
    # Raised by ExUnit's `assert/2` (the operator's), in the test's frame.
    assert hd(ours.stacktrace) == hd(exunit.stacktrace)
    assert {__MODULE__, _, _, location} = Enum.at(ours.stacktrace, 1)
    assert source(location[:line]) =~ "assert 1 + 1 == 3"

    with_message = assertion_error(fn -> assert false, "with a message" end)
    assert with_message.error == %ExUnit.AssertionError{message: "with a message"}
    assert [{ExUnit.Assertions, :assert, 2, _}, {__MODULE__, _, _, location} | _] = with_message.stacktrace
    assert source(location[:line]) =~ ~s(assert false, "with a message")
  end

  test "a function that ends in a failed assert keeps its frame, as it is no tail call" do
    assert [{ExUnit.Assertions, :assert, 2, _}, {__MODULE__, :ends_in_assert, 1, location}, {__MODULE__, _, _, _} | _] =
             assertion_error(fn -> ends_in_assert(2) end).stacktrace

    assert source(location[:line]) =~ "assert(n == 1)"
  end

  defp ends_in_assert(n), do: assert(n == 1)

  defp assertion_error(fun) do
    fun.()
    flunk("passed")
  rescue
    error in ExUnit.AssertionError -> %{error: error, stacktrace: __STACKTRACE__}
  end

  test "a failed one is a step with its error, once, in the step that caught it; again when it fails again" do
    on_trace(fn events ->
      [outer | _] = for %{"title" => "outer"} = event <- befores(events), do: event
      inners = for %{"title" => "inner"} = event <- befores(events), do: event
      failed = for %{"title" => ~s(Expect "assert")} = event <- befores(events), do: event
      assert [first, again, other] = failed

      assert Enum.map([first, again], & &1["parentId"]) == Enum.map(inners, & &1["callId"])
      assert hd(inners)["parentId"] == outer["callId"]
      assert %{"params" => %{"expression" => "Process.get(:attempt) == 2"}} = first
      assert located_at(first, "assert Process.get(:attempt) == 2")
      assert after_of(events, first)["error"]["message"] =~ "Assertion with == failed"
      assert after_of(events, hd(inners))["error"]["message"] == after_of(events, first)["error"]["message"]
      assert after_of(events, outer)["error"]
      assert after_of(events, again)["error"]

      assert %{"params" => %{"expression" => "String.length(string) > 1"}} = other
      assert located_at(other, "ExUnit.Assertions.assert(String.length(string) > 1)")
      assert after_of(events, other)["error"]["message"] =~ "Assertion with > failed"

      assert %{"title" => ~s(Expect "refute")} = refuted = before(events, ~s(Expect "refute"))
      assert located_at(refuted, ~s(refute "x" =~ "x"))
      assert after_of(events, refuted)["error"]["message"] =~ "Refute with =~ failed"

      assert %{"params" => %{"expression" => "false"}} = messaged = before(events, "never")
      assert located_at(messaged, ~s(assert false, "never"))
      assert after_of(events, messaged)["error"]["message"] =~ "never"
    end)

    Process.put(:attempt, 1)

    for _attempt <- 1..2 do
      assertion_error(fn ->
        Test.step "outer" do
          Test.step "inner" do
            assert Process.get(:attempt) == 2
          end
        end
      end)
    end

    assertion_error(fn -> Test.step("other", fn -> helper_assert("x") end) end)
    assertion_error(fn -> Test.step("refutes", fn -> refute "x" =~ "x" end) end)
    assertion_error(fn -> Test.step("with a message", fn -> assert false, "never" end) end)
  end

  # A helper module's assertion, without the import: its failure is a step too.
  defp helper_assert(string), do: ExUnit.Assertions.assert(String.length(string) > 1)

  test "no step of its own for expect.poll's assertion, nor outside a test" do
    on_trace(fn events ->
      poll = before(events, ~s(Expect "poll assert"))
      [attempt] = for %{"parentId" => id} = event <- befores(events), id == poll["callId"], do: event
      assert attempt["title"] == ~s(Expect "assert")
      refute Enum.any?(befores(events), &(&1["parentId"] == attempt["callId"]))
      # The poll's, its attempt's and the Task's.
      assert length(befores(events)) == 3
    end)

    Expect.poll!(fn -> 1 end, &assert(&1 == 1))

    Task.async(fn ->
      assert TestInfo.current()
      Process.delete(:"$callers")
      assert TestInfo.current() == nil
      refute TestInfo.current()
    end)
    |> Task.await()
  end
end
