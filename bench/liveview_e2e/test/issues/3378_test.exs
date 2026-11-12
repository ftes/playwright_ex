defmodule LiveViewE2E.Issues.Issue3378Test do
  use LiveViewE2E.Case

  test "can rejoin with nested streams without errors", %{page: page} do
    {:ok, errors} = Agent.start(fn -> [] end)

    Page.on(page, :page_error, fn err ->
      Agent.update(errors, &(&1 ++ [err]))
    end)

    Page.goto!(page, "/issues/3378")
    sync_lv(page)

    page |> Page.locator("#notifications") |> Expect.to_contain_text!("big")

    Page.evaluate!(
      page,
      "() => new Promise((resolve) => window.liveSocket.disconnect(resolve))"
    )

    Page.evaluate!(page, "() => window.liveSocket.connect()")
    sync_lv(page)

    # no js errors should be thrown
    assert Agent.get(errors, & &1) == []
  end
end
