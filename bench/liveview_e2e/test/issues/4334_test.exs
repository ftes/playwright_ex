defmodule LiveViewE2E.Issues.Issue4334Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/4334
  test "hook is remounted when changing LC root id and content is properly patched", %{
    page: page
  } do
    {:ok, logs} = Agent.start_link(fn -> [] end)
    Page.on(page, :console, fn e -> Agent.update(logs, &(&1 ++ [ConsoleMessage.text(e)])) end)

    Page.goto!(page, "/issues/4334")
    sync_lv(page)

    assert Enum.filter(Agent.get(logs, & &1), &String.contains?(&1, "MyHook")) == [
             "MyHook mounted"
           ]

    page |> Page.get_by_role(:button, name: "Change component root id") |> Locator.click!()
    sync_lv(page)

    # Hook remounts
    assert Enum.filter(Agent.get(logs, & &1), &String.contains?(&1, "MyHook")) == [
             "MyHook mounted",
             "MyHook mounted"
           ]

    page |> Page.get_by_text("NEW CHILD SHOULD REMAIN VISIBLE") |> Expect.to_be_visible!()
  end
end
