defmodule PlaywrightEx.Test.StepsTest do
  # `step/3` (upstream's `test.step`) and the matchers' steps, in the test's `test.trace`
  # (upstream's `TestTracing`). Failures as ExUnit reports them: `PlaywrightEx.Test.EndToEndTest`.
  use ExUnit.Case, async: true

  @this_file __ENV__.file

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.TestInfo

  @moduletag trace: :on

  # The checks of `on_trace/1`, by test pid, in a table of the module's.
  setup_all do
    :ets.new(__MODULE__, [:public, :named_table])
    :ok
  end

  # Before the registration, so its `on_exit` runs after the test's end saved its trace.
  setup ctx do
    dir = Recorder.output_dir(ctx)
    test_pid = self()

    on_exit(fn ->
      with [{_, fun}] <- :ets.take(__MODULE__, test_pid) do
        {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "trace.zip")), [:memory])
        files = Map.new(files, fn {name, data} -> {to_string(name), data} end)
        fun.(for(line <- String.split(files["test.trace"], "\n"), do: JSON.decode!(line)), files)
      end

      File.rm_rf!(dir)
    end)
  end

  use PlaywrightEx.Test

  # `fun` gets the `test.trace` events of the test's `trace.zip`, once its recording finished.
  defp on_trace(fun), do: :ets.insert(__MODULE__, {self(), fun})

  defp new_page do
    BrowserPool.shared() |> Browser.new_context!() |> BrowserContext.new_page!()
  end

  # The source line `line` of this file.
  defp source(line), do: __ENV__.file |> File.read!() |> String.split("\n") |> Enum.at(line - 1)

  defp before(events, title), do: Enum.find(events, &(&1["type"] == "before" and &1["title"] == title))
  defp after_of(events, %{"callId" => id}), do: Enum.find(events, &(&1["type"] == "after" and &1["callId"] == id))

  test "steps nest, return their bodies' values, and are traced" do
    on_trace(fn events, files ->
      assert [%{"type" => "context-options", "origin" => "testRunner", "version" => 10} | _] = events
      outer = before(events, "outer")
      inner = before(events, "inner")
      assert %{"class" => "Test", "method" => "test.step", "params" => %{"n" => "1"}} = outer
      refute Map.has_key?(outer, "parentId")
      assert inner["parentId"] == outer["callId"]
      assert [%{"file" => @this_file, "line" => line}] = inner["stack"]
      assert source(line) =~ ~s(Test.step "inner" do)
      assert %{"annotations" => [], "endTime" => _} = after_of(events, inner)
      assert files["src/#{:crypto.hash(:sha, __ENV__.file) |> Base.encode16(case: :lower)}.exs"]
    end)

    value =
      Test.step(
        "outer",
        fn ->
          inner =
            Test.step "inner" do
              1
            end

          inner + 1
        end,
        params: %{n: 1}
      )

    assert value == 2
  end

  test "a step from a Task, and a skipped one" do
    on_trace(fn events, _files ->
      assert before(events, "in a task")
      skipped = before(events, "skipped")
      assert [%{"type" => "skip"}] = after_of(events, skipped)["annotations"]
    end)

    assert Task.await(Task.async(fn -> Test.step("in a task", fn -> :value end) end)) == :value
    assert Test.step_skip("skipped", fn -> flunk("runs") end) == nil
  end

  test "outside a test it raises" do
    parent = self()

    spawn(fn ->
      send(parent, {:raised, assert_raise(RuntimeError, fn -> Test.step("nowhere", fn -> :ok end) end)})
    end)

    assert_receive {:raised, %RuntimeError{message: "test.step() can only be called from a test"}}
  end

  test "a step's error: in its after event, raised as is or at the boxed step's call site" do
    on_trace(fn events, _files ->
      assert %{"error" => %{"message" => "RuntimeError: plain"}} = after_of(events, before(events, "plain"))
      boxed = after_of(events, before(events, "boxed"))
      assert boxed["error"]["stack"] =~ ~r"^RuntimeError: boxed\n    at .*steps_test\.exs:\d+"
    end)

    stacktrace =
      try do
        Test.step("plain", fn -> raise "plain" end)
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
    Test.step "boxed", box: true do
      raise "boxed"
    end
  end

  test "a boxed step's stack starts at its function's call, also when the step isn't its tail call" do
    on_trace(fn events, _files ->
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
    assert catch_throw(Test.step("boxed throw", fn -> throw(:boom) end, box: true)) == :boom
  end

  defp boxed_exit_helper, do: Test.step("boxed exit", fn -> exit(:boom) end, box: true)

  defp non_tail_boxed_helper(arg) do
    Test.step "non-tail", box: true do
      raise "boxed"
    end

    arg
  end

  test "a step rejects timeout and runs in the test's process" do
    assert_raise ArgumentError, ~r/^step timeout is not supported/, fn ->
      Test.step("timed", fn -> :value end, timeout: 5000)
    end

    test_pid = self()
    Process.put(:in_step, :put)
    send(self(), :sent)

    assert Test.step("in the test's process", fn ->
             assert_receive :sent
             {self(), Process.get(:in_step)}
           end) == {test_pid, :put}
  end

  test "a matcher is a step of the step it runs in" do
    on_trace(fn events, _files ->
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

    page = new_page()
    Page.set_content!(page, "<h1>Steps</h1>")

    Test.step "check" do
      Expect.to_have_text!(Page.locator(page, "h1"), "Steps")
    end

    assert {:error, _} = Expect.to_be_visible(Page.locator(page, "h2"), timeout: 1)
  end

  test "a matcher's driver call shares its step's callId" do
    on_trace(fn events, files ->
      matcher = before(events, ~s(Expect "toHaveText"))

      driver_ids =
        for {name, trace} <- files,
            name != "test.trace" and Path.extname(name) == ".trace",
            line <- String.split(trace, "\n", trim: true),
            event = JSON.decode!(line),
            match?(%{"type" => "before", "class" => "Frame", "method" => "expect"}, event),
            do: event["callId"]

      assert driver_ids == [matcher["callId"]]
    end)

    page = new_page()
    Page.set_content!(page, "<h1>One</h1>")
    Expect.to_have_text!(Page.locator(page, "h1"), "One")
  end

  test "a soft matcher: a soft step, its failure recorded as the test's error, the body continues" do
    on_trace(fn events, _files ->
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

    page = new_page()
    Page.set_content!(page, "<h1>Soft</h1>")
    heading = Page.locator(page, "h1")

    assert :ok = heading |> Expect.soft() |> Expect.to_have_text!("Soft")
    assert :ok = heading |> Expect.soft() |> Expect.not_() |> Expect.to_have_text("Hard")
    assert :ok = heading |> Expect.not_() |> Expect.soft() |> Expect.to_have_text("Hard")
    assert :ok = heading |> Expect.soft() |> Expect.not_to_have_text!("Hard")

    Test.step "around" do
      assert :ok = heading |> Expect.soft() |> Expect.not_() |> Expect.to_have_text!("Soft", timeout: 1)
    end

    # The test's error, taken so that it passes; the end-to-end test fails one.
    assert [{:error, %PlaywrightEx.ExpectError{} = error, [{PlaywrightEx.Matchers.Expect, _, _, _} | _]}] =
             TestInfo.take_errors(self())

    assert Exception.message(error) =~ "expect(locator).not.toHaveText(expected) failed"
  end

  test "a custom message: the step's title and the error's first paragraph, with not_ and soft; poll's own wins" do
    on_trace(fn events, _files ->
      assert %{"method" => "expect"} = before(events, "should be logged in")
      failed = after_of(events, before(events, "negated soft"))

      assert failed["error"]["message"] =~
               ~r/^PlaywrightEx.ExpectError: negated soft\n\nexpect\(locator\).not.toHaveText/

      assert before(events, "the receiver's poll")
      assert before(events, "poll's own")
      refute before(events, "overridden")
    end)

    page = new_page()
    Page.set_content!(page, "<h1>Name</h1>")
    heading = Page.locator(page, "h1")

    assert :ok = heading |> Expect.message("should be logged in") |> Expect.to_be_visible!()

    assert {:error, %PlaywrightEx.ExpectError{message: "not visible\n\n" <> rest}} =
             heading |> Expect.message("not visible") |> Expect.not_() |> Expect.to_be_visible(timeout: 1)

    assert rest =~ "expect(locator).not.toBeVisible"

    assert :ok =
             heading
             |> Expect.not_()
             |> Expect.soft()
             |> Expect.message("negated soft")
             |> Expect.to_have_text!("Name", timeout: 1)

    assert [{:error, %PlaywrightEx.ExpectError{message: "negated soft\n\n" <> _}, _}] = TestInfo.take_errors(self())

    assert :ok = fn -> 1 end |> Expect.message("the receiver's poll") |> Expect.poll!(&assert(&1 == 1))
    assert :ok = fn -> 1 end |> Expect.message("overridden") |> Expect.poll!(&assert(&1 == 1), message: "poll's own")
  end

  test "a soft matcher in a Task of the test, and a soft error other than an ExpectError" do
    page = new_page()
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

  @tag :tmp_dir
  test "attach: a test.attach step with the attachment, its content in the trace", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "report.json")
    File.write!(file, ~s({"ok": true}))

    on_trace(fn events, files ->
      attach = before(events, ~s(Attach "report"))
      assert %{"method" => "test.attach", "parentId" => parent_id} = attach
      assert parent_id == before(events, "with an attachment")["callId"]

      assert [%{"name" => "report", "contentType" => "application/json", "file" => file}] =
               after_of(events, attach)["attachments"]

      assert files[file] == ~s({"ok": true})

      assert [%{"name" => "note", "contentType" => "text/plain", "file" => note}] =
               after_of(events, before(events, ~s(Attach "note")))["attachments"]

      assert files[note] == "hello"

      assert [%{"name" => "bytes", "contentType" => "application/octet-stream"}] =
               after_of(events, before(events, ~s(Attach "bytes")))["attachments"]
    end)

    Test.step "with an attachment" do
      assert Test.attach("report", path: file) == :ok
    end

    Test.attach("note", body: "hello")
    Task.await(Task.async(fn -> Test.attach("bytes", body: <<255, 0>>) end))

    %{output_dir: dir} = Test.info()
    assert [copy] = File.ls!(Path.join(dir, "attachments"))
    assert copy =~ ~r/^report-[0-9a-f]{40}\.json$/

    assert_raise RuntimeError, ~r/Exactly one of "path" and "body"/, fn -> Test.attach("x", path: file, body: "") end
    assert_raise ArgumentError, fn -> Test.attach("x", contentType: "text/plain") end
  end

  test "toPass and expect.poll are steps, with the callback's steps and the poll's tries in them" do
    on_trace(fn events, _files ->
      to_pass = before(events, ~s(Expect "toPass"))
      id = to_pass["callId"]
      assert [^id, ^id] = for(%{"type" => "before", "title" => "try"} = e <- events, do: e["parentId"])
      poll = before(events, ~s(Expect "poll assert"))
      tries = for %{"type" => "before", "parentId" => id} = e <- events, id == poll["callId"], do: e["title"]
      assert [~s(Expect "assert"), ~s(Expect "assert")] = tries
      assert after_of(events, poll)["error"] == nil
    end)

    {:ok, agent} = Agent.start_link(fn -> 0 end)
    next = fn -> Agent.get_and_update(agent, &{&1, &1 + 1}) end

    Expect.to_pass!(fn ->
      Test.step "try" do
        assert next.() >= 1
      end
    end)

    Expect.poll!(next, &assert(&1 >= 3))
  end

  test "a soft matcher outside a test fails as any matcher (no step)" do
    page = new_page()
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
