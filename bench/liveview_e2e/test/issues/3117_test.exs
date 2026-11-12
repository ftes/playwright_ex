defmodule LiveViewE2E.Issues.Issue3117Test do
  use LiveViewE2E.Case

  test "LiveComponent with static FC root is not reset", %{page: page} do
    {:ok, errors} = Agent.start(fn -> [] end)
    Page.on(page, :page_error, fn err -> Agent.update(errors, &(&1 ++ [err])) end)

    Page.goto!(page, "/issues/3117")
    sync_lv(page)

    # clicking the button performs a live navigation
    page |> Page.locator("#navigate") |> Locator.click!()
    sync_lv(page)

    # the FC root should still be visible and not empty/skipped
    page |> Page.locator("#row-1 .static") |> Expect.to_be_visible!()
    page |> Page.locator("#row-2 .static") |> Expect.to_be_visible!()
    page |> Page.locator("#row-1 .static") |> Expect.to_have_text!("static content")
    page |> Page.locator("#row-2 .static") |> Expect.to_have_text!("static content")

    # no js errors should be thrown
    assert Agent.get(errors, & &1) == []
  end
end
