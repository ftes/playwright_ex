defmodule PlaywrightEx.Test.StepsTest do
  # `step/3` (upstream's `test.step`) and the matchers' steps, in the test's `test.trace`
  # (upstream's `TestTracing`). Failures as ExUnit reports them: `PlaywrightEx.Test.EndToEndTest`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  @this_file __ENV__.file

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.TestInfo

  setup_all :browser

  # The `test.trace` events of the test's `trace.zip`, once its recording finished (an
  # `on_exit` registered before `record_artifacts/2` runs after it).
  defp on_trace(ctx, fun) do
    dir = Recorder.output_dir(ctx)

    on_exit(fn ->
      {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "trace.zip")), [:memory])
      files = Map.new(files, fn {name, data} -> {to_string(name), data} end)
      File.rm_rf!(dir)
      fun.(for(line <- String.split(files["test.trace"], "\n"), do: JSON.decode!(line)), files)
    end)

    record_artifacts(ctx, trace: :on)
  end

  # The source line `line` of this file.
  defp source(line), do: __ENV__.file |> File.read!() |> String.split("\n") |> Enum.at(line - 1)

  defp before(events, title), do: Enum.find(events, &(&1["type"] == "before" and &1["title"] == title))
  defp after_of(events, %{"callId" => id}), do: Enum.find(events, &(&1["type"] == "after" and &1["callId"] == id))

  test "steps nest, return their bodies' values, and are traced", ctx do
    on_trace(ctx, fn events, files ->
      assert [%{"type" => "context-options", "origin" => "testRunner", "version" => 10} | _] = events
      outer = before(events, "outer")
      inner = before(events, "inner")
      assert %{"class" => "Test", "method" => "test.step", "params" => %{"n" => "1"}} = outer
      refute Map.has_key?(outer, "parentId")
      assert inner["parentId"] == outer["callId"]
      assert [%{"file" => @this_file, "line" => line}] = inner["stack"]
      assert source(line) =~ ~s(step "inner" do)
      assert %{"annotations" => [], "endTime" => _} = after_of(events, inner)
      assert files["src/#{:crypto.hash(:sha, __ENV__.file) |> Base.encode16(case: :lower)}.exs"]
    end)

    value =
      step(
        "outer",
        fn ->
          inner =
            step "inner" do
              1
            end

          inner + 1
        end,
        params: %{n: 1}
      )

    assert value == 2
  end

  test "a step from a Task, and a skipped one", ctx do
    on_trace(ctx, fn events, _files ->
      assert before(events, "in a task")
      skipped = before(events, "skipped")
      assert [%{"type" => "skip"}] = after_of(events, skipped)["annotations"]
    end)

    assert Task.await(Task.async(fn -> step("in a task", fn -> :value end) end)) == :value
    assert step_skip("skipped", fn -> flunk("runs") end) == nil
  end

  test "outside a test it raises" do
    parent = self()

    spawn(fn ->
      send(parent, {:raised, assert_raise(RuntimeError, fn -> step("nowhere", fn -> :ok end) end)})
    end)

    assert_receive {:raised, %RuntimeError{message: "test.step() can only be called from a test"}}
  end

  test "a step's error: in its after event, raised as is or at the boxed step's call site", ctx do
    on_trace(ctx, fn events, _files ->
      assert %{"error" => %{"message" => "RuntimeError: plain"}} = after_of(events, before(events, "plain"))
      boxed = after_of(events, before(events, "boxed"))
      assert boxed["error"]["stack"] =~ ~r"^RuntimeError: boxed\n    at .*steps_test\.exs:\d+"
    end)

    stacktrace =
      try do
        step("plain", fn -> raise "plain" end)
      rescue
        _ -> __STACKTRACE__
      end

    assert {__MODULE__, _, _, location} = hd(stacktrace)
    assert source(location[:line]) =~ ~s(raise "plain")

    stacktrace =
      try do
        boxed_helper()
      rescue
        _ -> __STACKTRACE__
      end

    # The helper's frame is gone (it tail-calls the step): the first is the test's call of it.
    assert [{__MODULE__, _, _, location} | _] = stacktrace
    assert source(location[:line]) =~ "boxed_helper()"
  end

  defp boxed_helper do
    step "boxed", box: true do
      raise "boxed"
    end
  end

  test "a boxed step's stack starts at its function's call, also when the step isn't its tail call", ctx do
    on_trace(ctx, fn events, _files ->
      assert after_of(events, before(events, "boxed exit"))["error"]["stack"] =~
               ~r"^undefined\n    at .*steps_test\.exs:\d+"
    end)

    stacktrace =
      try do
        non_tail_boxed_helper(:arg)
      rescue
        _ -> __STACKTRACE__
      end

    assert [{__MODULE__, _, _, location} | _] = stacktrace
    assert source(location[:line]) =~ "non_tail_boxed_helper(:arg)"

    assert catch_exit(boxed_exit_helper()) == :boom
    assert catch_throw(step("boxed throw", fn -> throw(:boom) end, box: true)) == :boom
  end

  defp boxed_exit_helper, do: step("boxed exit", fn -> exit(:boom) end, box: true)

  defp non_tail_boxed_helper(arg) do
    step "non-tail", box: true do
      raise "boxed"
    end

    arg
  end

  test "a step the recording starts in has no events, its nested steps have", ctx do
    on_trace_in_step = fn ->
      on_trace(ctx, fn events, _files ->
        refute before(events, "untraced")
        assert after_of(events, before(events, "traced"))
        befores = for %{"type" => "before", "callId" => id} <- events, do: id
        assert for(%{"type" => "after", "callId" => id} <- events, do: id) -- befores == []
      end)
    end

    step "untraced" do
      on_trace_in_step.()
      step("traced", fn -> :ok end)
    end
  end

  test "a step times out", ctx do
    on_trace(ctx, fn events, _files ->
      assert after_of(events, before(events, "slow"))["error"]["message"] ==
               "PlaywrightEx.TimeoutError: Step timeout of 50ms exceeded."
    end)

    assert step("quick", fn -> :value end, timeout: 5000) == :value
    test_pid = self()
    assert step("in the test's process", fn -> self() end, timeout: :infinity) == test_pid

    assert_raise PlaywrightEx.TimeoutError, "Step timeout of 50ms exceeded.", fn ->
      step("slow", fn -> Process.sleep(5000) end, timeout: 50)
    end
  end

  test "a matcher is a step of the step it runs in", ctx do
    on_trace(ctx, fn events, _files ->
      outer = before(events, "check")
      matcher = before(events, ~s(Expect "toHaveText"))
      assert %{"method" => "expect", "parentId" => parent_id} = matcher
      assert parent_id == outer["callId"]
      assert %{"subtitle" => ~s[Page.locator(page, "h1")], "params" => %{"expected" => "Steps"}} = matcher
      assert [%{"file" => @this_file} | _] = matcher["stack"]
      refute Map.has_key?(after_of(events, matcher), "error")

      failed = before(events, ~s(Expect "toBeVisible"))
      assert after_of(events, failed)["error"]["message"] =~ ~r/^PlaywrightEx.ExpectError: /
      # The options are its argument.
      assert failed["params"] == %{"expected" => "Object", "locator" => ~s[Page.locator(page, "h2")]}
    end)

    %{context: context} = new_context(ctx)
    %{page: page} = new_page(%{context: context})
    Page.set_content!(page, "<h1>Steps</h1>")

    step "check" do
      Expect.to_have_text!(Page.locator(page, "h1"), "Steps")
    end

    assert {:error, _} = Expect.to_be_visible(Page.locator(page, "h2"), timeout: 1)
  end

  test "a soft matcher: a soft step, its failure recorded as the test's error, the body continues", ctx do
    on_trace(ctx, fn events, _files ->
      refute Map.has_key?(after_of(events, before(events, ~s(Expect "soft toHaveText"))), "error")
      around = before(events, "around")
      failed = Enum.find(events, &(&1["type"] == "before" and &1["parentId"] == around["callId"]))
      assert failed["title"] == ~s(Expect "soft not toHaveText")
      failed = after_of(events, failed)
      assert failed["error"]["message"] =~ ~r/^PlaywrightEx.ExpectError: expect\(locator\).not.toHaveText/
      assert after_of(events, around)["error"] == failed["error"]

      assert [%{"message" => "PlaywrightEx.ExpectError: " <> _}] =
               for(%{"type" => "error"} = event <- events, do: event)
    end)

    %{context: context} = new_context(ctx)
    %{page: page} = new_page(%{context: context})
    Page.set_content!(page, "<h1>Soft</h1>")
    heading = Page.locator(page, "h1")

    assert :ok = heading |> Expect.soft() |> Expect.to_have_text!("Soft")
    assert :ok = heading |> Expect.soft() |> Expect.not_() |> Expect.to_have_text("Hard")
    assert :ok = heading |> Expect.not_() |> Expect.soft() |> Expect.to_have_text("Hard")
    assert :ok = heading |> Expect.soft() |> Expect.not_to_have_text!("Hard")

    step "around" do
      assert :ok = heading |> Expect.soft() |> Expect.not_() |> Expect.to_have_text!("Soft", timeout: 1)
    end

    # The test's error, taken so that it passes; the end-to-end test fails one.
    assert [{:error, %PlaywrightEx.ExpectError{} = error, [{PlaywrightEx.Matchers.Expect, _, _, _} | _]}] =
             TestInfo.take_errors(self())

    assert Exception.message(error) =~ "expect(locator).not.toHaveText(expected) failed"
  end

  test "a soft matcher in a Task of the test, and a soft error other than an ExpectError", ctx do
    %{context: context} = new_context(ctx)
    %{page: page} = new_page(%{context: context})
    Page.set_content!(page, "<h1>Task</h1>")
    heading = Page.locator(page, "h1")

    assert :ok =
             Task.await(Task.async(fn -> heading |> Expect.soft() |> Expect.to_have_text!("x", timeout: 1) end))

    # The matcher raises (its `new Error`): soft too.
    assert :ok = page |> Expect.soft() |> Expect.to_match_aria_snapshot(name: "a.aria.yml", path: "a.aria.yml")

    assert [{:error, %PlaywrightEx.ExpectError{}, _}, {:error, %RuntimeError{message: message}, _}] =
             TestInfo.take_errors(self())

    assert message =~ "not both"
  end

  test "a soft matcher outside a test fails as any matcher (no step)", %{browser: browser} do
    context = PlaywrightEx.Browser.new_context!(browser)
    on_exit(fn -> PlaywrightEx.BrowserContext.close(context) end)
    page = PlaywrightEx.BrowserContext.new_page!(context)
    Page.set_content!(page, "<h1>Outside</h1>")
    heading = Page.locator(page, "h1")

    Task.async(fn ->
      Process.delete(:"$callers")
      assert TestInfo.current() == nil
      assert {:error, %PlaywrightEx.ExpectError{}} = heading |> Expect.soft() |> Expect.to_have_text("x", timeout: 1)

      assert_raise PlaywrightEx.ExpectError, ~r/not.toHaveText/, fn ->
        heading |> Expect.soft() |> Expect.not_() |> Expect.to_have_text!("Outside", timeout: 1)
      end

      assert :ok = heading |> Expect.soft() |> Expect.to_have_text("Outside")
    end)
    |> Task.await(:infinity)

    assert TestInfo.take_errors(self()) == []
  end
end
