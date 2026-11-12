defmodule LiveViewE2E.Issues.Issue3719Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/3719
  test "target is properly decoded", %{page: page} do
    {:ok, logs} = Agent.start_link(fn -> [] end)
    Page.on(page, :console, fn e -> Agent.update(logs, &(&1 ++ [ConsoleMessage.text(e)])) end)

    Page.goto!(page, "/issues/3719")
    sync_lv(page)
    page |> Page.locator("#a") |> Locator.fill!("foo")
    sync_lv(page)
    page |> Page.locator("#target") |> Expect.to_have_text!(~s(["foo"]))

    page |> Page.locator("#b") |> Locator.fill!("foo")
    sync_lv(page)
    page |> Page.locator("#target") |> Expect.to_have_text!(~s(["foo", "bar"]))

    refute Enum.any?(Agent.get(logs, & &1), &(&1 =~ ~r/view crashed/))
  end
end
