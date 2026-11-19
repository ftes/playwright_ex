defmodule Playwright.Test.SetupAllStepTest do
  # `Playwright.Test.step/2,3` in a module's `setup_all`, upstream's `test.step` in `beforeAll`:
  # the step's own semantics (its value, nesting, box, skip, its error raised on), recorded
  # nowhere, as `setup_all` runs before any test.
  use ExUnit.Case, async: true
  use Playwright.Test

  alias Playwright.Test
  alias Playwright.Test.Results

  setup_all do
    nested =
      Test.step "outer" do
        Test.step("inner", fn -> {:inner, Test.info().file} end)
      end

    boxed =
      try do
        boxed_helper()
      rescue
        error -> {error, __STACKTRACE__}
      end

    plain =
      try do
        Test.step("plain", fn -> raise "plain" end)
      rescue
        error -> {error, __STACKTRACE__}
      end

    test_pid = self()
    skipped = Test.step_skip("skipped", fn -> send(test_pid, :ran) end)
    ran? = receive(do: (:ran -> true), after: (0 -> false))

    in_task = Task.await(Task.async(fn -> Test.step("in a task", fn -> :in_task end) end))

    # A process of `setup_all`'s that outlives it (`$callers`), stepping during a test.
    {:ok, late} =
      Task.start(fn ->
        receive do
          {:step, from} -> send(from, {:stepped, Test.step("late", fn -> :late end)})
        end
      end)

    %{
      nested: nested,
      boxed: boxed,
      plain: plain,
      skipped: skipped,
      ran?: ran?,
      in_task: in_task,
      late: late,
      rows: :ets.match_object(Results.table(), {{:test_info, nil, :_}, :_})
    }
  end

  defp boxed_helper do
    Test.step "boxed", box: true do
      Test.step("in the box", fn -> raise "boxed" end)
    end
  end

  defp source(line), do: __ENV__.file |> File.read!() |> String.split("\n") |> Enum.at(line - 1)

  test "a step returns its body's value, nested ones too", ctx do
    assert ctx.nested == {:inner, Path.expand(__ENV__.file)}
    assert ctx.in_task == :in_task
  end

  test "a step's error is raised on, a boxed one's (its steps' too) at the boxed step's call site", ctx do
    {%RuntimeError{message: "plain"}, [{__MODULE__, _, _, location} | _]} = ctx.plain
    assert source(location[:line]) =~ ~s(raise "plain")

    {%RuntimeError{message: "boxed"}, [{__MODULE__, _, _, location} | _]} = ctx.boxed
    assert source(location[:line]) =~ "boxed_helper()"
  end

  test "step_skip doesn't run its body and returns nil", ctx do
    assert ctx.skipped == nil
    refute ctx.ran?
  end

  test "nothing is recorded", ctx do
    assert ctx.rows == []
  end

  test "a long-lived process of setup_all's steps during a test too", ctx do
    send(ctx.late, {:step, self()})
    assert_receive {:stepped, :late}
  end
end

defmodule Playwright.Test.SetupAllStepTest.Unregistered do
  # Without `use Playwright.Test`: no scope, so `step/2,3` raises in `setup_all`.
  use ExUnit.Case, async: true

  require Playwright.Test

  setup_all do
    %{raised: catch_error(Playwright.Test.step("x", fn -> :ok end))}
  end

  test "step raises in setup_all without use Playwright.Test", ctx do
    assert %RuntimeError{message: "test.step() can only be called from a test"} = ctx.raised
  end
end
