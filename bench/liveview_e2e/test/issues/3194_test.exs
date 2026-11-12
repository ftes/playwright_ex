defmodule LiveViewE2E.Issues.Issue3194Test do
  use LiveViewE2E.Case

  test "does not send event to wrong LV when submitting form with debounce blur", %{page: page} do
    {:ok, logs} = Agent.start(fn -> [] end)
    Page.on(page, :console, fn e -> Agent.update(logs, &(&1 ++ [ConsoleMessage.text(e)])) end)

    Page.goto!(page, "/issues/3194")
    sync_lv(page)

    page |> Page.locator("input") |> Locator.focus!()
    page |> Page.keyboard() |> Keyboard.type!("hello")
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    Expect.to_have_url!(page, "/issues/3194/other")

    # give it some time for old events to reach the new LV
    # (this is the failure case!)
    Page.wait_for_timeout!(page, 50)

    # we navigated to another LV
    assert Enum.any?(
             Agent.get(logs, & &1),
             &(&1 =~ ~r/destroyed: the child has been removed from the parent/)
           )

    # it should not have crashed
    refute Enum.any?(Agent.get(logs, & &1), &(&1 =~ ~r/view crashed/))
  end
end
