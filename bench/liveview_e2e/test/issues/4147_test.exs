defmodule LiveViewE2E.Issues.Issue4147Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/4147
  test "hook outside of liveview does works when reconnecting", %{page: page} do
    {:ok, logs} = Agent.start_link(fn -> [] end)

    Page.on(page, :console, fn msg ->
      Agent.update(logs, &(&1 ++ [ConsoleMessage.text(msg)]))
    end)

    {:ok, errors} = Agent.start_link(fn -> [] end)

    Page.on(page, :page_error, fn err ->
      Agent.update(errors, &(&1 ++ [err]))
    end)

    Page.goto!(page, "/issues/4147")
    sync_lv(page)

    Page.evaluate!(
      page,
      "() => new Promise((resolve) => window.liveSocket.disconnect(resolve))"
    )

    page |> Page.locator(".phx-loading") |> Expect.to_have_count!(1)

    Page.evaluate!(page, "() => window.liveSocket.connect()")
    sync_lv(page)

    assert length(Agent.get(errors, & &1)) == 0
    # Hook was mounted once
    assert length(
             Enum.filter(Agent.get(logs, & &1), &String.contains?(&1, "HookOutside mounted"))
           ) == 1
  end
end
