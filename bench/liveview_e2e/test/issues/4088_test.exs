defmodule LiveViewE2E.Issues.Issue4088Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/4088
  test "locked LiveComponent container can be patched properly", %{page: page} do
    {:ok, errors} = Agent.start_link(fn -> [] end)

    Page.on(page, :page_error, fn err ->
      Agent.update(errors, &(&1 ++ [err]))
    end)

    Page.goto!(page, "/issues/4088")
    sync_lv(page)

    assert length(Agent.get(errors, & &1)) == 0
  end
end
