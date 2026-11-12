defmodule LiveViewE2E.Issues.Issue3496Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/3496
  test "hook is initialized properly when reusing id between sticky and non sticky LiveViews",
       %{page: page} do
    {:ok, logs} = Agent.start(fn -> [] end)
    Page.on(page, :console, fn e -> Agent.update(logs, &(&1 ++ [ConsoleMessage.text(e)])) end)
    {:ok, errors} = Agent.start(fn -> [] end)
    Page.on(page, :page_error, fn err -> Agent.update(errors, &(&1 ++ [err])) end)

    Page.goto!(page, "/issues/3496/a")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "Go to page B") |> Locator.click!()
    sync_lv(page)

    assert length(Enum.filter(Agent.get(logs, & &1), &String.contains?(&1, "Hook mounted!"))) ==
             2

    refute Enum.any?(
             Agent.get(logs, & &1),
             &(&1 =~ ~r/no hook found for custom element/)
           )

    # no uncaught exceptions
    assert Agent.get(errors, & &1) == []
  end
end
