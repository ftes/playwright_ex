defmodule Playwright.Test.SetupAllStepTest do
  # `Playwright.Test.step/2,3` in a module's `setup_all`, upstream's `test.step` in `beforeAll`:
  # the step's own semantics (its value, nesting, box, skip, its error raised on), recorded
  # nowhere, as `setup_all` runs before any test.
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Page
  alias Playwright.Route
  alias Playwright.Test
  alias Playwright.Test.BrowserPool
  alias Playwright.Test.Results

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
      dir = Test.info(test_pid).output_dir

      with [{_, fun}] <- :ets.take(__MODULE__, test_pid) do
        {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "trace.zip")), [:memory])
        files = Map.new(files, fn {name, data} -> {to_string(name), data} end)
        fun.(for(line <- String.split(files["test.trace"], "\n"), do: JSON.decode!(line)))
      end

      File.rm_rf!(dir)
    end)
  end

  use Playwright.Test

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

    setup_all_pid = self()
    skipped = Test.step_skip("skipped", fn -> send(setup_all_pid, :ran) end)
    ran? = receive(do: (:ran -> true), after: (0 -> false))

    in_task = Task.await(Task.async(fn -> Test.step("in a task", fn -> :in_task end) end))

    # A process of `setup_all`'s that outlives it (`$callers`), stepping during a test.
    {:ok, late} =
      Task.start(fn ->
        receive do
          {:step, from} -> send(from, {:stepped, Test.step("late", fn -> :late end)})
        after
          60_000 -> :ok
        end
      end)

    # A route handler registered in `setup_all` (its `$callers`), stepping during a test.
    context = Browser.new_context!(BrowserPool.browser())
    on_exit(fn -> BrowserContext.close(context) end)
    page = BrowserContext.new_page!(context)

    Page.route!(page, "**/*", fn route ->
      body = Test.step("handler", fn -> "stepped" end)
      Route.fulfill!(route, body: body, content_type: "text/plain")
    end)

    %{
      nested: nested,
      boxed: boxed,
      plain: plain,
      skipped: skipped,
      ran?: ran?,
      in_task: in_task,
      late: late,
      page: page,
      setup_all_pid: setup_all_pid,
      rows: module_rows(setup_all_pid)
    }
  end

  defp boxed_helper do
    Test.step "boxed", box: true do
      Test.step("in the box", fn -> raise "boxed" end)
    end
  end

  defp source(line), do: __ENV__.file |> File.read!() |> String.split("\n") |> Enum.at(line - 1)

  defp module_rows(pid), do: :ets.match_object(Results.table(), {{:test_info, pid, :_}, :_})

  # `fun` gets the `test.trace` events of the test's `trace.zip`, once its recording finished.
  defp on_trace(fun), do: :ets.insert(__MODULE__, {self(), fun})

  defp step_titles(events), do: for(%{"type" => "before", "title" => title} <- events, do: title)

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

  test "setup_all's steps leave no rows", ctx do
    assert ctx.rows == []
  end

  test "a long-lived process or route handler of setup_all's steps during a test, unrecorded", ctx do
    on_trace(fn events ->
      titles = step_titles(events)
      assert "in the test" in titles
      refute "late" in titles
      refute "handler" in titles
    end)

    Test.step("in the test", fn -> :ok end)
    test_rows = :ets.match_object(Results.table(), {{:test_info, self(), {:step, :_}}, :_})

    send(ctx.late, {:step, self()})
    assert_receive {:stepped, :late}
    # No row of the test's (its only step is its own), nor of the module's.
    assert :ets.match_object(Results.table(), {{:test_info, self(), {:step, :_}}, :_}) == test_rows
    assert [_in_the_test] = test_rows

    Page.goto!(ctx.page, "http://setup-all.test/")
    assert Page.content!(ctx.page) =~ "stepped"
    assert module_rows(ctx.setup_all_pid) == []
  end
end

defmodule Playwright.Test.SetupAllStepTest.BeforeUse do
  # A `setup_all` above `use Playwright.Test` runs before it registers the module: no scope, so
  # `step/2,3` raises there.
  use ExUnit.Case, async: true

  require Playwright.Test

  setup_all do
    %{raised: catch_error(Playwright.Test.step("x", fn -> :ok end))}
  end

  use Playwright.Test

  test "step raises in a setup_all before use Playwright.Test", ctx do
    assert %RuntimeError{message: "test.step() can only be called from a test"} = ctx.raised
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
