defmodule LiveViewE2E.Issues.Issue4094Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/4094
  test "no errors when handle_params redirects", %{page: page} do
    {:ok, js_errors} = Agent.start_link(fn -> [] end)

    Page.on(page, :page_error, fn error ->
      Agent.update(js_errors, &(&1 ++ [Exception.message(error)]))
    end)

    Page.goto!(page, "/issues/4094")
    sync_lv(page)

    # Clicking a link that redirects in handle_params would throw an exception
    # on the client.
    Page.click!(page, "a")

    Expect.to_have_url!(page, "/navigation/a")
    assert length(Agent.get(js_errors, & &1)) == 0
  end
end
