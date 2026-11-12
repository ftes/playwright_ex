defmodule LiveViewE2E.Issues.Issue3200Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/3200
  test "phx-target='selector' is used correctly for form recovery", %{page: page} do
    {:ok, errors} = Agent.start(fn -> [] end)
    Page.on(page, :page_error, fn err -> Agent.update(errors, &(&1 ++ [err])) end)

    Page.goto!(page, "/issues/3200/settings")
    sync_lv(page)

    page |> Page.get_by_role(:button, name: "Messages") |> Locator.click!()
    sync_lv(page)
    Expect.to_have_url!(page, "/issues/3200/messages")

    page |> Page.locator("#new_message_input") |> Locator.fill!("Hello")
    sync_lv(page)

    Page.evaluate!(
      page,
      "() => new Promise((resolve) => window.liveSocket.disconnect(resolve))"
    )

    page |> Page.locator(".phx-loading") |> Expect.to_have_count!(1)

    Page.evaluate!(page, "() => window.liveSocket.connect()")
    sync_lv(page)

    page |> Page.locator("#new_message_input") |> Expect.to_have_value!("Hello")
    assert Agent.get(errors, & &1) == []
  end
end
