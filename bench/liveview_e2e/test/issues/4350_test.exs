defmodule LiveViewE2E.Issues.Issue4350Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/4350
  #
  # A component that is used again between cids_will_destroy and cids_destroyed must
  # revive its whole subtree. Children that change tracking skips are the interesting
  # case: the parent comes back, but nothing re-renders the child, so it stays marked
  # and is deleted while its DOM is still on the page.
  #
  # The window between the two messages is a single round trip, so we hold
  # cids_destroyed in flight and bring the component back while it is delayed.
  test "reviving a component also revives children skipped by change tracking", %{page: page} do
    # cids_destroyed is held until the test releases it, so the ordering is
    # explicit rather than timing dependent
    # (the three promises are messages to the test process: {:destroyed_sent, waiter},
    # :release to the waiter, :destroyed_handled)
    test_pid = self()

    Page.route_web_socket!(page, ~r/.*live.*/, fn ws ->
      server = WebSocketRoute.connect_to_server(ws)
      # [join_ref, ref, topic, event, payload]
      {:ok, destroyed_ref} = Agent.start(fn -> nil end)

      WebSocketRoute.on_message(ws, fn message ->
        if is_binary(message) and String.contains?(message, "cids_destroyed") do
          Agent.update(destroyed_ref, fn _ -> message |> JSON.decode!() |> Enum.at(1) end)

          # `await destroyedReleased` in the handler: a handler must not block, so a
          # process waits for the release and forwards the message
          waiter =
            spawn(fn ->
              receive do
                :release -> WebSocketRoute.send(server, message)
              end
            end)

          send(test_pid, {:destroyed_sent, waiter})
        else
          WebSocketRoute.send(server, message)
        end
      end)

      WebSocketRoute.on_message(server, fn message ->
        ref = Agent.get(destroyed_ref, & &1)

        if ref != nil and is_binary(message) do
          [_, msg_ref | _] = JSON.decode!(message)

          if msg_ref == ref do
            send(test_pid, :destroyed_handled)
          end
        end

        WebSocketRoute.send(ws, message)
      end)
    end)

    Page.goto!(page, "/issues/4350")
    sync_lv(page)

    page |> Page.locator("#bump") |> Locator.click!()
    page |> Page.locator("#leaf-count") |> Expect.to_have_text!("1")

    # re-render the branch so the dynamic holding the leaf is change-tracked away
    page |> Page.locator("#tick") |> Locator.click!()
    sync_lv(page)
    page |> Page.locator("#branch") |> Expect.to_contain_text!("tick: 1")

    leaf_cid = page |> Page.locator("#leaf") |> Locator.get_attribute!("data-phx-component")

    # remove the subtree; the client reports both cids as destroyed
    page |> Page.locator("#hide") |> Locator.click!()
    page |> Page.locator("#wrapper") |> Expect.to_have_count!(0)

    # cids_destroyed is held in flight - bring the component back before it lands.
    # The subtree being back means the server has already re-rendered it.
    waiter =
      receive do
        {:destroyed_sent, waiter} -> waiter
      end

    page |> Page.locator("#show") |> Locator.click!()
    page |> Page.locator("#wrapper") |> Expect.to_have_count!(1)
    sync_lv(page)

    # only now let the destroy through, and wait for the server to answer it
    send(waiter, :release)

    receive do
      :destroyed_handled -> :ok
    end

    # the leaf is the same component and is still wired to the server
    page
    |> Page.locator("#leaf")
    |> Expect.to_have_attribute!("data-phx-component", leaf_cid)

    page |> Page.locator("#bump") |> Locator.click!()
    page |> Page.locator("#leaf-count") |> Expect.to_have_text!("2")
  end
end
