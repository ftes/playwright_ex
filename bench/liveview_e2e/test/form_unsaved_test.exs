defmodule LiveViewE2E.FormUnsavedTest do
  use LiveViewE2E.Case

  alias PlaywrightEx.WebSocket

  # upstream's module-level `webSocketEvents` and `networkEvents`, reset in beforeEach,
  # are an Agent per test here (the listeners run in processes of their own). Not linked to the
  # test: the listeners fire until the context closes, after the test process has exited.
  setup %{page: page} do
    {:ok, events} = Agent.start(fn -> %{web_socket_events: [], network_events: []} end)

    Page.on(page, :request, fn request ->
      push(events, :network_events, %{method: Request.method(request), url: Request.url(request)})
    end)

    Page.on(page, :web_socket, fn ws ->
      WebSocket.on(ws, :frame_sent, fn event ->
        push(events, :web_socket_events, %{type: "sent", payload: event.payload})
      end)

      WebSocket.on(ws, :frame_received, fn event ->
        push(events, :web_socket_events, %{type: "received", payload: event.payload})
      end)

      WebSocket.on(ws, :close, fn _ -> push(events, :web_socket_events, %{type: "close"}) end)
    end)

    %{events: events}
  end

  test "can prevent live navigation and beforeunload", %{page: page, events: events} do
    Page.goto!(page, "/form-unsaved")
    sync_lv(page)

    assert Page.evaluate!(page, "() => window.unsavedEvents") == []

    page |> Page.locator("#unsaved-note") |> Locator.fill!("draft")
    sync_lv(page)
    page |> Page.locator("#unsaved-value") |> Expect.to_have_text!("Unsaved value: draft")

    clear(events, :network_events)
    clear(events, :web_socket_events)

    confirm_promise = Page.wait_for_event(page, :dialog)
    # the click doesn't return while the confirm is open: started here, awaited after the dismiss
    click_promise =
      Task.async(fn ->
        page |> Page.get_by_role(:link, name: "Leave form") |> Locator.click!()
      end)

    confirm_dialog = Promise.await!(confirm_promise)
    assert Dialog.type(confirm_dialog) == "confirm"
    assert Dialog.message(confirm_dialog) == "You have unsaved changes. Leave without saving?"
    Dialog.dismiss!(confirm_dialog)
    Task.await(click_promise, :infinity)

    Expect.to_have_url!(page, "/form-unsaved")
    assert get(events, :network_events) == []
    assert get(events, :web_socket_events) == []

    assert Page.evaluate!(page, "() => window.unsavedEvents") == [
             %{
               "type" => "phx",
               "detail" => %{
                 "href" => "http://localhost:4004/form-unsaved/target",
                 "patch" => false,
                 "pop" => false,
                 "direction" => "forward"
               }
             }
           ]

    page |> Page.locator("#unsaved-note") |> Locator.fill!("draft after live nav cancel")
    sync_lv(page)

    page
    |> Page.locator("#unsaved-value")
    |> Expect.to_have_text!("Unsaved value: draft after live nav cancel")

    dialog_promise = Page.wait_for_event(page, :dialog)
    close_promise = Task.async(fn -> Page.close!(page, run_before_unload: true) end)
    dialog = Promise.await!(dialog_promise)
    assert Dialog.type(dialog) == "beforeunload"
    Dialog.dismiss!(dialog)
    Task.await(close_promise, :infinity)

    assert Page.is_closed(page) == false
    Expect.to_have_url!(page, "/form-unsaved")
    page |> Page.locator("#unsaved-note") |> Expect.to_have_value!("draft after live nav cancel")

    assert Page.evaluate!(page, "() => window.unsavedEvents") == [
             %{
               "type" => "phx",
               "detail" => %{
                 "href" => "http://localhost:4004/form-unsaved/target",
                 "patch" => false,
                 "pop" => false,
                 "direction" => "forward"
               }
             },
             %{"type" => "beforeunload"}
           ]

    assert Page.evaluate!(
             page,
             """
             () => ({
               connected: window.liveSocket.isConnected(),
               unloaded: window.liveSocket.isUnloaded(),
             })
             """
           ) == %{"connected" => true, "unloaded" => false}

    page |> Page.locator("#unsaved-note") |> Locator.fill!("draft after beforeunload cancel")
    sync_lv(page)

    page
    |> Page.locator("#unsaved-value")
    |> Expect.to_have_text!("Unsaved value: draft after beforeunload cancel")
  end

  # `xs.push(event)`, `xs` and `xs = []` on upstream's module-level arrays
  defp push(events, key, event),
    do: Agent.update(events, &Map.update!(&1, key, fn xs -> xs ++ [event] end))

  defp get(events, key), do: Agent.get(events, &Map.fetch!(&1, key))
  defp clear(events, key), do: Agent.update(events, &Map.put(&1, key, []))
end
