defmodule LiveViewE2E.Issues.Issue3931Test do
  use LiveViewE2E.Case

  alias PlaywrightEx.WebSocket

  # https://github.com/phoenixframework/phoenix_live_view/issues/3931
  test "dynamic attributes reset __changed__ and properly re-render", %{page: page} do
    {:ok, web_socket_events} = Agent.start_link(fn -> [] end)
    push = fn event -> Agent.update(web_socket_events, &(&1 ++ [event])) end

    Page.on(page, :web_socket, fn ws ->
      WebSocket.on(ws, :frame_sent, fn event ->
        push.(%{type: "sent", payload: event.payload})
      end)

      WebSocket.on(ws, :frame_received, fn event ->
        push.(%{type: "received", payload: event.payload})
      end)

      WebSocket.on(ws, :close, fn _ -> push.(%{type: "close"}) end)
    end)

    Page.goto!(page, "/issues/3931")
    sync_lv(page)

    # it should be updated asynchronously
    page
    |> Page.locator("#async")
    |> Expect.to_contain_text!("This was loaded asynchronously!")

    # arrayContaining([{ type, payload: expect.stringContaining(...) }, ...])
    events = Agent.get(web_socket_events, & &1)

    for {type, substring} <- [
          {"sent", "phx_join"},
          {"received", "phx_reply"},
          {"received", "diff"}
        ] do
      assert Enum.any?(events, fn event ->
               event[:type] == type and is_binary(event[:payload]) and
                 String.contains?(event[:payload], substring)
             end)
    end
  end
end
