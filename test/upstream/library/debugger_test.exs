defmodule PlaywrightEx.Library.DebuggerTest do
  @upstream "tests/library/debugger.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Debugger
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Utils

  @moduletag :page

  # Listeners are added before the action that triggers the event (JS adds them right after
  # starting it, in the same tick). Call locations are this file's (`debugger_test`, not `debugger.spec`).

  defp once_paused(dbg) do
    test_pid = self()
    Debugger.once(dbg, :paused_state_changed, fn _ -> send(test_pid, :paused_state_changed) end)
  end

  # For calls whose location matters: the call runs in the test process (a call inside a
  # `Task.async(fn -> ... end)` is a tail call, so the location would be Task's). This starts a
  # helper that waits for the pause, reads `pausedDetails`, resumes and waits for the resume.
  defp resume_when_paused(dbg) do
    task =
      Task.async(fn ->
        assert_receive :paused_state_changed, 5000
        details = Debugger.paused_details(dbg)
        once_paused(dbg)
        Debugger.resume!(dbg)
        assert_receive :paused_state_changed, 5000
        details
      end)

    Debugger.once(dbg, :paused_state_changed, fn _ -> send(task.pid, :paused_state_changed) end)
    task
  end

  # `dbg._enable()` and the `apicallsupdated` event are internal (not in the facade).
  defp enable(dbg), do: Api.call("debugger._enable", dbg, fn -> PlaywrightEx.Client.Debugger._enable(dbg) end)

  defp on_api_calls_updated(dbg) do
    test_pid = self()
    PlaywrightEx.Client.Debugger.on(dbg, "apicallsupdated", fn api_calls -> send(test_pid, {:api_calls, api_calls}) end)
  end

  # `page._wrapApiCall(fn, { internal: true })`, internal too.
  defp internal_call(page, fun) do
    Api.call(nil, page, fn -> PlaywrightEx.Client.Page._wrap_api_call(page, fn _ -> fun.() end, %{internal: true}) end)
  end

  # `dbg.on('apicallsupdated', apiCalls => all.push(...apiCalls))`: an Agent of all updates (cast:
  # updates after the test are dropped).
  defp collect_api_calls(dbg) do
    {:ok, updates} = Agent.start_link(fn -> [] end)

    PlaywrightEx.Client.Debugger.on(dbg, "apicallsupdated", fn api_calls ->
      Agent.cast(updates, &(&1 ++ api_calls))
    end)

    updates
  end

  defp received_api_calls do
    receive do
      {:api_calls, api_calls} -> api_calls ++ received_api_calls()
    after
      0 -> []
    end
  end

  test "DB-001 should pause at next and resume", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<div>click me</div>")
    dbg = BrowserContext.debugger(context)
    assert Debugger.paused_details(dbg) == nil

    Debugger.request_pause!(dbg)
    paused = resume_when_paused(dbg)
    Page.click!(page, "div")

    assert %{title: title, location: %{file: file, line: line, column: column}} = Task.await(paused, :infinity)
    assert title =~ "Click"
    assert file =~ "debugger_test"
    assert is_number(line)
    assert is_number(column)

    assert Debugger.paused_details(dbg) == nil
  end

  test "DB-002 should pause at pause call", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<div>click me</div>")
    dbg = BrowserContext.debugger(context)
    assert Debugger.paused_details(dbg) == nil

    Debugger.request_pause!(dbg)
    once_paused(dbg)
    pause_promise = Runtime.Promise.async(fn -> Page.pause!(page) end)
    assert_receive :paused_state_changed, 5000

    assert %{title: title} = Debugger.paused_details(dbg)
    assert title =~ "Pause"

    Debugger.resume!(dbg)
    Runtime.Promise.await(pause_promise)
  end

  test "DB-003 should run to location", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<div>click me</div>")
    dbg = BrowserContext.debugger(context)
    assert Debugger.paused_details(dbg) == nil

    # First, pause on next action.
    Debugger.request_pause!(dbg)
    once_paused(dbg)
    Runtime.Promise.void(fn -> Page.click(page, "div") end)
    assert_receive :paused_state_changed, 5000

    # Now run to a specific location.
    line = __ENV__.line
    # Note: careful with the line offset below.
    Debugger.run_to!(dbg, %{file: "debugger_test", line: line + 7})
    paused = resume_when_paused(dbg)
    # should not pause here
    Page.content!(page)
    # should pause here
    Page.click!(page, "div")

    assert %{title: title} = Task.await(paused, :infinity)
    assert title =~ "Click"
  end

  test "DB-004 should stream api calls via _enable", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<button>click me</button>")
    dbg = BrowserContext.debugger(context)

    # Accumulate deltas by id, appending newLogEntries — mirrors the dashboard bridge.
    updates = collect_api_calls(dbg)
    enable(dbg)

    Page.click!(page, "button")

    calls = fn ->
      Enum.reduce(Agent.get(updates, & &1), %{}, fn call, calls ->
        existing = calls[call.id]

        Map.put(calls, call.id, %{
          title: call.title,
          status: call.status,
          location: call[:location],
          actionPoint: call[:actionPoint] || (existing && existing.actionPoint),
          logs: ((existing && existing.logs) || []) ++ call.newLogEntries,
          statusHistory: ((existing && existing.statusHistory) || []) ++ [call.status]
        })
      end)
    end

    click_call = fn -> calls.() |> Map.values() |> Enum.find(&(&1.title =~ "Click")) end
    Utils.poll(fn -> click_call.()[:status] end, &assert(&1 == "success"))

    call = click_call.()
    assert call.location.file =~ "debugger_test"
    assert %{x: x, y: y} = call.actionPoint
    assert is_number(x) and is_number(y)
    assert call.logs != []

    # The status streamed running -> success (not just a single terminal event).
    assert hd(call.statusHistory) == "running"
    assert List.last(call.statusHistory) == "success"
  end

  test "DB-005 should report error status for failed api calls", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<div>no button here</div>")
    dbg = BrowserContext.debugger(context)

    updates = collect_api_calls(dbg)
    enable(dbg)

    Page.click(page, "button", timeout: 1000)

    click_call = fn ->
      updates
      |> Agent.get(& &1)
      |> Enum.reduce(%{}, &Map.put(&2, &1.id, &1))
      |> Map.values()
      |> Enum.find(&(&1.title =~ "Click"))
    end

    Utils.poll(fn -> click_call.()[:status] end, &assert(&1 == "error"))
    Utils.assert_truthy(click_call.().error)
  end

  test "DB-006 should not stream internal api calls", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<button>click me</button>")
    dbg = BrowserContext.debugger(context)
    updates = collect_api_calls(dbg)
    enable(dbg)

    # A call wrapped as internal (mirrors the dashboard's own traffic) is excluded.
    internal_call(page, fn -> Page.click!(page, "button") end)
    # A normal call is still streamed.
    Page.click!(page, "button")

    Utils.poll(fn -> Enum.any?(Agent.get(updates, & &1), &(&1.title =~ "Click")) end, &assert(&1 == true))
    click_ids = for c <- Agent.get(updates, & &1), c.title =~ "Click", uniq: true, do: c.id
    assert length(click_ids) == 1
  end

  test "DB-007 should not pause at internal api calls", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<button>click me</button>")
    dbg = BrowserContext.debugger(context)

    Debugger.request_pause!(dbg)
    # The internal call must not trip the pause, and must not consume the arming.
    internal_call(page, fn -> Page.click!(page, "button") end)
    assert Debugger.paused_details(dbg) == nil

    # The next normal call still pauses.
    once_paused(dbg)
    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "button") end)
    assert_receive :paused_state_changed, 5000
    assert Debugger.paused_details(dbg)

    once_paused(dbg)
    Debugger.resume!(dbg)
    assert_receive :paused_state_changed, 5000
    Runtime.Promise.await(click_promise)
  end

  test "DB-008 should expose the action point while paused on an input action", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, ~s(<button style="position:absolute; left:40px; top:60px">click me</button>))
    dbg = BrowserContext.debugger(context)
    on_api_calls_updated(dbg)
    enable(dbg)

    # With api calls enabled, requestPause pauses inside the action (after auto-waiting),
    # so the action point is known — unlike the default "pause before waiting" behavior.
    Debugger.request_pause!(dbg)
    once_paused(dbg)
    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "button") end)
    assert_receive :paused_state_changed, 5000

    assert Debugger.paused_details(dbg).title =~ "Click"

    calls =
      Enum.reduce(received_api_calls(), %{}, fn c, calls ->
        existing = calls[c.id]
        Map.put(calls, c.id, Map.put(c, :actionPoint, c[:actionPoint] || (existing && existing[:actionPoint])))
      end)

    click_call = calls |> Map.values() |> Enum.find(&(&1.title =~ "Click"))
    assert click_call.status == "running"
    assert %{x: x, y: y} = click_call.actionPoint
    assert is_number(x) and is_number(y)

    once_paused(dbg)
    Debugger.resume!(dbg)
    assert_receive :paused_state_changed, 5000
    Runtime.Promise.await(click_promise)
  end

  test "DB-009 should replay ongoing calls when enabled late", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<button>click me</button>")
    dbg = BrowserContext.debugger(context)

    # Start a call and pause on it, so it is definitely in-flight — but do NOT enable yet.
    # (The click runs in the test process for its location; a helper does the rest.)
    Debugger.request_pause!(dbg)

    helper =
      Task.async(fn ->
        assert_receive :paused_state_changed, 5000

        # Enabling now must replay the already-ongoing call right away.
        updates = collect_api_calls(dbg)
        enable(dbg)

        click_call = fn -> Enum.find(Agent.get(updates, & &1), &(&1.title =~ "Click")) end
        Utils.poll(fn -> click_call.()[:status] end, &assert(&1 == "running"))

        once_paused(dbg)
        Debugger.resume!(dbg)
        assert_receive :paused_state_changed, 5000
        click_call.()
      end)

    Debugger.once(dbg, :paused_state_changed, fn _ -> send(helper.pid, :paused_state_changed) end)
    Page.click!(page, "button")

    click_call = Task.await(helper, :infinity)
    assert click_call.location.file =~ "debugger_test"
  end

  test "DB-010 should keep pause working when api calls are enabled", %{context: context} do
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<div>click me</div>")
    dbg = BrowserContext.debugger(context)
    enable(dbg)

    Debugger.request_pause!(dbg)
    once_paused(dbg)
    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "div") end)
    assert_receive :paused_state_changed, 5000
    assert Debugger.paused_details(dbg).title =~ "Click"

    once_paused(dbg)
    Debugger.resume!(dbg)
    assert_receive :paused_state_changed, 5000
    Runtime.Promise.await(click_promise)
    assert Debugger.paused_details(dbg) == nil
  end
end
