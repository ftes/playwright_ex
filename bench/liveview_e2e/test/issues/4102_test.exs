defmodule LiveViewE2E.Issues.Issue4102Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/4102
  test "debounce works for inputs outside of the form", %{page: page} do
    {:ok, errors} = Agent.start_link(fn -> [] end)

    Page.on(page, :page_error, fn err ->
      Agent.update(errors, &(&1 ++ [err]))
    end)

    Page.goto!(page, "/issues/4102")
    sync_lv(page)

    page |> Page.locator("input") |> Locator.fill!("123")
    page |> Page.locator("button") |> Locator.click!()
    sync_lv(page)

    assert length(Agent.get(errors, & &1)) == 0
  end
end
