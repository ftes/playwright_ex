defmodule Playwright.Test.AssertionsTest.Helper do
  # A helper module that opts in with the import alone (no `ExUnit.Assertions`).
  import Playwright.Test, only: [assert: 1, assert: 2, refute: 1, refute: 2]

  def check(value) do
    assert value == :ok
    refute match?({:error, _}, value)
    value
  end
end

defmodule Playwright.Test.AssertionsTest.OwnOperator do
  # An `==` that isn't Kernel's, which ExUnit's `assert` doesn't translate (no `right`).
  import Kernel, except: [==: 2]
  import Playwright.Test, only: [assert: 1]

  def left == right, do: Kernel.==(left, right)

  def check(value) do
    assert value == :ok
    true
  end
end

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

  test "a failed one is a step where its error ends, the test's catch, with its error; none if rescued" do
    on_trace(fn events ->
      assert [failed, other, refuted, messaged] = Enum.filter(befores(events), &(&1["method"] == "expect"))
      refute Map.has_key?(failed, "parentId")
      assert %{"params" => %{"expression" => "Process.get(:attempt) == 2", "expected" => "2"}} = failed
      assert located_at(failed, "assert Process.get(:attempt) == 2")
      assert after_of(events, failed)["error"]["message"] =~ "Assertion with == failed"

      assert %{"params" => %{"expression" => "String.length(string) > 1", "expected" => "1"}} = other
      assert located_at(other, "ExUnit.Assertions.assert(String.length(string) > 1)")
      assert after_of(events, other)["error"]["message"] =~ "Assertion with > failed"

      assert %{"title" => ~s(Expect "refute")} = refuted
      assert located_at(refuted, ~s(refute "x" =~ "x"))
      assert after_of(events, refuted)["error"]["message"] =~ "Refute with =~ failed"

      # `assert/2`'s own `try` records it, in its step, rescued or not.
      assert %{"title" => "never", "params" => %{"expression" => "false"}} = messaged
      assert messaged["parentId"] == before(events, "with a message")["callId"]
      assert located_at(messaged, ~s(assert false, "never"))
      assert after_of(events, messaged)["error"]["message"] =~ "never"
    end)

    Process.put(:attempt, 1)

    # As the test's catch (`__failed__/3`) records it: nested steps fail with it, it ends there.
    test_failure(fn ->
      Test.step "outer" do
        Test.step "inner" do
          assert Process.get(:attempt) == 2
        end
      end
    end)

    # Rescued by the test itself: no step.
    assertion_error(fn -> Test.step("rescued", fn -> assert 1 == 2 end) end)
    test_failure(fn -> Test.step("other", fn -> helper_assert("x") end) end)
    test_failure(fn -> Test.step("refutes", fn -> refute "x" =~ "x" end) end)
    test_failure(fn -> Test.step("with a message", fn -> assert false, "never" end) end)
  end

  # A failure of `fun`, recorded as the test's catch records it (`Playwright.Test.__failed__/3`).
  defp test_failure(fun) do
    error =
      try do
        fun.()
        nil
      catch
        kind, reason -> {kind, reason, __STACKTRACE__}
      end

    Playwright.Test.__assertion_error__(TestInfo.current(), error || flunk("passed"))
  end

  # A helper module's assertion, without the import: its failure is a step too.
  # Not a tail call, so its frame is in the stacktrace on each OTP.
  defp helper_assert(string) do
    ExUnit.Assertions.assert(String.length(string) > 1)
    :ok
  end

  test "match?: one step each, passed or failed" do
    on_trace(fn events ->
      assert [passed, refuted, failed] = befores(events) |> Enum.filter(&(&1["method"] == "expect"))
      assert %{"title" => ~s(Expect "assert"), "subtitle" => "match?({:ok, _}, ok)"} = passed
      assert %{"title" => ~s(Expect "refute"), "subtitle" => "match?({:error, _}, ok)"} = refuted
      refute after_of(events, refuted)["error"]
      assert %{"title" => ~s(Expect "refute"), "subtitle" => "match?({:ok, _}, ok)"} = failed
      assert located_at(failed, "refute match?({:ok, _}, ok)")
      assert after_of(events, failed)["error"]["message"] =~ "match (match?) succeeded, but should have failed"
    end)

    # Not a literal, which the type checker would flag.
    ok = Process.get(:not_set, {:ok, 1})
    assert match?({:ok, _}, ok)
    refute match?({:error, _}, ok)
    test_failure(fn -> refute match?({:ok, _}, ok) end)
  end

  test "a failed one in a to_pass attempt is a step of the toPass step, each attempt's" do
    on_trace(fn events ->
      to_pass = before(events, ~s(Expect "toPass"))
      attempts = for %{"parentId" => id} = event <- befores(events), id == to_pass["callId"], do: event
      assert [first, second, third] = attempts
      assert Enum.all?(attempts, &(&1["title"] == ~s(Expect "assert")))
      assert after_of(events, first)["error"]["message"] =~ "Assertion with >= failed"
      assert after_of(events, second)["error"]
      refute after_of(events, third)["error"]
      assert located_at(first, "assert Agent.get_and_update(agent, &{&1, &1 + 1}) >= 2")
    end)

    {:ok, agent} = Agent.start_link(fn -> 0 end)
    Expect.to_pass!(fn -> assert Agent.get_and_update(agent, &{&1, &1 + 1}) >= 2 end, intervals: [0])
  end

  test "a to_pass or poll that times out records its attempts' failed asserts, not again at the test's level" do
    on_trace(fn events ->
      to_pass = before(events, ~s(Expect "toPass"))
      attempts = for %{"parentId" => id} = event <- befores(events), id == to_pass["callId"], do: event
      assert [_ | _] = attempts
      assert Enum.all?(attempts, &(&1["title"] == ~s(Expect "assert") and after_of(events, &1)["error"]))
      # Each failed `assert` is an attempt's, or the poll's matcher (no step of its own).
      assert Enum.filter(befores(events), &(&1["title"] == ~s(Expect "assert"))) |> Enum.all?(& &1["parentId"])
    end)

    test_failure(fn -> Expect.to_pass!(fn -> assert 1 == 2 end, intervals: [10], timeout: 50) end)
    test_failure(fn -> Expect.poll!(fn -> 1 end, &assert(&1 == 2), intervals: [10], timeout: 50) end)
  end

  test "a helper module with the import alone records its passed assertions" do
    on_trace(fn events ->
      assert [~s(Expect "assert"), ~s(Expect "refute")] = Enum.map(befores(events), & &1["title"])
    end)

    Playwright.Test.AssertionsTest.Helper.check(:ok)
  end

  test "the right side ExUnit binds is the step's expected, evaluated once, as upstream's toEqual(expected)" do
    on_trace(fn events ->
      params = for %{"method" => "expect"} = event <- befores(events), do: event["params"]

      assert params == [
               %{"expression" => "next.() < next.()", "expected" => "2"},
               %{"expression" => "Agent.get(agent, & &1) == 2", "expected" => "2"},
               %{"expression" => "length([1, 2]) != 3", "expected" => "3"},
               %{"expression" => "\"abc\" =~ ~r/b/", "expected" => "Object"},
               %{"expression" => "[1, 2] == [1, 2]", "expected" => "[1, 2]"},
               %{"expression" => "1 + 1 == 3", "expected" => "3"},
               %{"expression" => "refute(1 + 1 == 3) == false"},
               %{"expression" => "{:ok, _} = {:ok, 1}", "expected" => "{:ok, 1}"},
               %{"expression" => "match?({:ok, _}, {:ok, 1})", "expected" => "{:ok, 1}"},
               %{"expression" => "match?({:error, _}, Process.get(:not_set, {:ok, 1}))", "expected" => "{:ok, 1}"},
               # None for a falsy one (`if (args[0])`), a truthy assert, or an expansion that binds
               # no `right` (an operator that isn't Kernel's).
               %{"expression" => "0 == 0"},
               %{"expression" => "Enum.any?([1])"},
               %{"expression" => "value == :ok"},
               %{"expression" => "Playwright.Test.AssertionsTest.OwnOperator.check(:ok)"},
               # A failed one's, from its error: its `right`, or its `left` if both sides are equal.
               %{"expression" => "1 + 1 == 4", "expected" => "4"},
               %{"expression" => "1 != 1", "expected" => "1"},
               %{"expression" => "{:error, _} = {:ok, 2}", "expected" => "{:ok, 2}"}
             ]
    end)

    {:ok, agent} = Agent.start_link(fn -> 0 end)
    next = fn -> Agent.get_and_update(agent, &{&1 + 1, &1 + 1}) end
    # Each side once: 1 (left), then 2 (right).
    assert next.() < next.()
    assert Agent.get(agent, & &1) == 2
    assert length([1, 2]) != 3
    assert "abc" =~ ~r/b/
    assert [1, 2] == [1, 2]
    assert refute(1 + 1 == 3) == false
    assert {:ok, _} = {:ok, 1}
    assert match?({:ok, _}, {:ok, 1})
    refute match?({:error, _}, Process.get(:not_set, {:ok, 1}))
    assert 0 == 0
    assert Enum.any?([1])
    assert Playwright.Test.AssertionsTest.OwnOperator.check(:ok)
    test_failure(fn -> Test.step("fails", fn -> assert 1 + 1 == 4 end) end)
    test_failure(fn -> Test.step("equal", fn -> assert 1 != 1 end) end)
    test_failure(fn -> Test.step("match", fn -> assert {:error, _} = {:ok, 2} end) end)
  end

  test "a comparison fails with ExUnit's error, message and diff" do
    for {ours, exunit} <- [
          {fn -> assert 1 + 1 == 3 end, fn -> ExUnit.Assertions.assert(1 + 1 == 3) end},
          {fn -> assert [1, 2] === [1, 3] end, fn -> ExUnit.Assertions.assert([1, 2] === [1, 3]) end},
          {fn -> assert 1 != 1 end, fn -> ExUnit.Assertions.assert(1 != 1) end},
          {fn -> assert "abc" =~ ~r/x/ end, fn -> ExUnit.Assertions.assert("abc" =~ ~r/x/) end},
          {fn -> refute 2 > 1 end, fn -> ExUnit.Assertions.refute(2 > 1) end},
          {fn -> refute 1 == 1 end, fn -> ExUnit.Assertions.refute(1 == 1) end},
          {fn -> assert {:error, _} = Process.get(:not_set, {:ok, 1}) end,
           fn -> ExUnit.Assertions.assert({:error, _} = Process.get(:not_set, {:ok, 1})) end},
          {fn -> assert match?({:error, _}, Process.get(:not_set, {:ok, 1})) end,
           fn -> ExUnit.Assertions.assert(match?({:error, _}, Process.get(:not_set, {:ok, 1}))) end},
          {fn -> refute match?({:ok, _}, {:ok, 1}) end, fn -> ExUnit.Assertions.refute(match?({:ok, _}, {:ok, 1})) end}
        ] do
      ours = assertion_error(ours)
      exunit = assertion_error(exunit)
      # `inspect`: a regex's compiled form differs between two sigils; the code's lines differ.
      assert inspect(without_meta(ours.error)) == inspect(without_meta(exunit.error))
      assert Exception.message(ours.error) == Exception.message(exunit.error)

      assert ExUnit.Formatter.format_assertion_diff(ours.error, 0, :infinity, &diff_formatter/2) ==
               ExUnit.Formatter.format_assertion_diff(exunit.error, 0, :infinity, &diff_formatter/2)

      assert elem(hd(ours.stacktrace), 0) == elem(hd(exunit.stacktrace), 0)
    end
  end

  defp diff_formatter(_key, value), do: value

  defp without_meta(error) do
    strip =
      &Macro.prewalk(&1, fn
        {name, meta, args} when is_list(meta) -> {name, [], args}
        node -> node
      end)

    %{error | expr: strip.(error.expr), left: strip.(error.left)}
  end

  test "a large expected is previewed short" do
    on_trace(fn events ->
      [binary, list, invalid] =
        for %{"params" => %{"expression" => expression, "expected" => expected}} <- befores(events),
            expression in ["binary == same_binary", "list == same_list", "invalid == same_invalid"],
            do: expected

      assert byte_size(binary) < 1100
      assert String.ends_with?(binary, "…")
      assert byte_size(list) < 1100
      assert String.starts_with?(list, "[0, 1, 2")
      assert String.ends_with?(list, ", …]")
      assert byte_size(invalid) < 1100
      assert String.starts_with?(invalid, "<<255, 255")
    end)

    binary = String.duplicate("x", 1_000_000)
    same_binary = :binary.copy(binary)
    list = Enum.to_list(0..99_999)
    same_list = Enum.to_list(0..99_999)
    invalid = String.duplicate(<<0xFF>>, 1_000_000)
    same_invalid = :binary.copy(invalid)
    assert binary == same_binary
    assert list == same_list
    assert invalid == same_invalid
  end

  test "a binary that isn't UTF-8 is previewed as inspected, so the trace is JSON" do
    on_trace(fn events ->
      assert [passed, failed] = Enum.filter(befores(events), &(&1["method"] == "expect"))
      assert passed["params"]["expected"] == "<<137, 255>>"
      assert failed["params"]["expected"] == "<<137, 254>>"
      assert after_of(events, failed)["error"]
    end)

    frame = Process.get(:not_set, <<0x89, 0xFF>>)
    assert frame == <<0x89, 0xFF>>
    test_failure(fn -> assert frame == <<0x89, 0xFE>> end)
  end

  test "a poll's attempt is its assertion's own step, with its expression and expected; none outside a test" do
    on_trace(fn events ->
      poll = before(events, ~s(Expect "poll assert"))
      # No function as its `expected`, nor as `toPass`'s.
      refute Map.has_key?(poll["params"] || %{}, "expected")
      refute Map.has_key?(before(events, ~s(Expect "toPass"))["params"] || %{}, "expected")
      attempts = for %{"parentId" => id} = event <- befores(events), id == poll["callId"], do: event
      assert [failed, passed] = attempts

      for attempt <- attempts do
        assert %{"title" => ~s(Expect "assert"), "params" => %{"expression" => "&1 == 2", "expected" => "2"}} = attempt
        assert located_at(attempt, "Expect.poll!(")
        refute Enum.any?(befores(events), &(&1["parentId"] == attempt["callId"]))
      end

      assert after_of(events, failed)["error"]["message"] =~ "Assertion with == failed"
      refute after_of(events, passed)["error"]
      # The poll's, its attempts, `toPass`'s (its attempt asserts nothing), and the Task's.
      assert length(befores(events)) == 5
    end)

    {:ok, agent} = Agent.start_link(fn -> 0 end)
    Expect.poll!(fn -> Agent.get_and_update(agent, &{&1 + 1, &1 + 1}) end, &assert(&1 == 2), intervals: [0])
    Expect.to_pass!(fn -> :ok end)

    Task.async(fn ->
      assert TestInfo.current()
      Process.delete(:"$callers")
      assert TestInfo.current() == nil
      refute TestInfo.current()
    end)
    |> Task.await()
  end
end

defmodule Playwright.Test.AssertionsOptOutTest do
  # `use Playwright.Test, assert_steps: false`: ExUnit's own `assert` and `refute`, no steps.
  use ExUnit.Case, async: true

  alias Playwright.Expect
  alias Playwright.Test.TestInfo

  @moduletag Playwright.Test.use(trace: :on)

  setup _ctx do
    test_pid = self()

    on_exit(fn ->
      dir = Playwright.Test.info(test_pid).output_dir
      {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "trace.zip")), [:memory])
      {_, trace} = List.keyfind(files, ~c"test.trace", 0)
      events = for line <- String.split(trace, "\n"), do: JSON.decode!(line)
      File.rm_rf!(dir)
      befores = for %{"type" => "before", "method" => "expect"} = event <- events, do: event
      # No assertion's step (no `expression`); a poll's attempts are the matcher's.
      refute Enum.any?(befores, &(&1["params"]["expression"] != nil))
      expected = Process.get(:not_set, :persistent_term.get({__MODULE__, test_pid}, []))
      assert Enum.map(befores, & &1["title"]) == expected
    end)
  end

  use Playwright.Test, assert_steps: false
  # A later `use` without the option (a case template's `using` and the module's) keeps it.
  use Playwright.Test

  test "assert and refute are ExUnit's, and record no step, passed or failed" do
    assert Macro.Env.lookup_import(__ENV__, {:assert, 1}) == [macro: ExUnit.Assertions]
    assert Macro.Env.lookup_import(__ENV__, {:refute, 2}) == [function: ExUnit.Assertions]
    assert 1 + 1 == 2
    refute 1 + 1 == 3

    error =
      try do
        assert Process.get(:not_set, 1) == 2
      catch
        kind, reason -> {kind, reason, __STACKTRACE__}
      end

    # ExUnit's error and frames; the test's catch records none for this module.
    assert {:error, %ExUnit.AssertionError{message: "Assertion with == failed"},
            [{ExUnit.Assertions, :assert, 2, _} | _]} =
             error

    Playwright.Test.__assertion_error__(TestInfo.current(), error)
  end

  test "a poll's attempts are the matcher's steps" do
    :persistent_term.put({__MODULE__, self()}, [~s(Expect "poll assert"), ~s(Expect "assert"), ~s(Expect "assert")])
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    Expect.poll!(fn -> Agent.get_and_update(agent, &{&1 + 1, &1 + 1}) end, &assert(&1 == 2), intervals: [0])
  end

  test "the option takes a literal boolean, the config a boolean" do
    assert_raise ArgumentError,
                 ~r"^config :playwright, :test: invalid value :yes for assert_steps, expected a boolean",
                 fn ->
                   Playwright.Test.Options.validate_key!(:assert_steps, :yes, "config :playwright, :test")
                 end

    quoted =
      quote do
        defmodule Playwright.Test.AssertionsOptOutTest.Invalid do
          use ExUnit.Case
          use Playwright.Test, assert_steps: :yes
        end
      end

    assert_raise ArgumentError, ~r"^use Playwright.Test: invalid value :yes for assert_steps", fn ->
      Code.eval_quoted(quoted)
    end

    # From a list that isn't literal, `use` sees no option at compile time.
    assert_raise ArgumentError, ~r"^use Playwright.Test: assert_steps must be a literal boolean", fn ->
      Playwright.Test.Options.use_options(assert_steps: false)
    end
  end
end
