defmodule LiveViewE2E.Issues.Issue3530Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/3530
  # flaky upstream too (16/90 with --repeat-each 30): syncLV can return before the nested LV's
  # hook logs "item-2 mounted" / "item-4 mounted"
  @tag :upstream_failure
  test "hook is initialized properly when using a stream of nested LiveViews", %{page: page} do
    # `let logs` reassigned to [] below: an Agent the listener appends to
    {:ok, logs} = Agent.start(fn -> [] end)
    Page.on(page, :console, fn e -> Agent.update(logs, &(&1 ++ [ConsoleMessage.text(e)])) end)
    {:ok, errors} = Agent.start(fn -> [] end)
    Page.on(page, :page_error, fn err -> Agent.update(errors, &(&1 ++ [err])) end)

    count = fn text ->
      logs |> Agent.get(& &1) |> Enum.filter(&String.contains?(&1, text)) |> length()
    end

    Page.goto!(page, "/issues/3530")
    sync_lv(page)

    assert Agent.get(errors, & &1) == []
    assert count.("item-1 mounted") == 1
    assert count.("item-2 mounted") == 1
    assert count.("item-3 mounted") == 1
    Agent.update(logs, fn _ -> [] end)

    page |> Page.get_by_role(:link, name: "patch a") |> Locator.click!()
    sync_lv(page)

    assert Agent.get(errors, & &1) == []
    assert count.("item-2 destroyed") == 1
    assert count.("item-1 destroyed") == 0
    assert count.("item-3 destroyed") == 0
    Agent.update(logs, fn _ -> [] end)

    page |> Page.get_by_role(:link, name: "patch b") |> Locator.click!()
    sync_lv(page)

    assert Agent.get(errors, & &1) == []
    assert count.("item-1 destroyed") == 1
    assert count.("item-2 destroyed") == 0
    assert count.("item-3 destroyed") == 0
    assert count.("item-2 mounted") == 1
    Agent.update(logs, fn _ -> [] end)

    page |> Page.locator("div[phx-click=inc]") |> Locator.click!()
    sync_lv(page)
    assert count.("item-4 mounted") == 1

    refute Enum.any?(
             Agent.get(logs, & &1),
             &(&1 =~ ~r/no hook found for custom element/)
           )

    # no uncaught exceptions
    assert Agent.get(errors, & &1) == []
  end
end
