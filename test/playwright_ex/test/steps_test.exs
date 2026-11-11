defmodule PlaywrightEx.Test.StepsTest do
  # `step/3` (upstream's `test.step`) and the matchers' steps, in the test's `test.trace`
  # (upstream's `TestTracing`). Failures as ExUnit reports them: `PlaywrightEx.Test.EndToEndTest`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  @this_file __ENV__.file

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Recorder

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

  test "a step times out", ctx do
    on_trace(ctx, fn events, _files ->
      assert after_of(events, before(events, "slow"))["error"]["message"] ==
               "PlaywrightEx.TimeoutError: Step timeout of 50ms exceeded."
    end)

    assert step("quick", fn -> :value end, timeout: 5000) == :value

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
end
