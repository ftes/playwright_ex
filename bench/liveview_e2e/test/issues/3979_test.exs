defmodule LiveViewE2E.Issues.Issue3979Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/3979
  test "components destroyed check works properly", %{page: page} do
    {:ok, errors} = Agent.start_link(fn -> [] end)
    Page.on(page, :page_error, fn err -> Agent.update(errors, &(&1 ++ [err])) end)

    Page.goto!(page, "/issues/3979")
    sync_lv(page)

    bump_btn = Page.get_by_role(page, :button, name: "Bump ID (and counter)")

    for _i <- 0..9 do
      Locator.click!(bump_btn)
      sync_lv(page)
    end

    for i <- 0..9 do
      page
      |> Page.locator(~s([data-phx-component="#{i + 1}"]))
      |> Expect.to_have_text!("10")
    end

    assert Agent.get(errors, & &1) == []
  end
end
