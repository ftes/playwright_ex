defmodule LiveViewE2E.ErrorsTest do
  @moduledoc """
  https://phoenix-live-view.hexdocs.pm/error-handling.html
  """
  use LiveViewE2E.Case

  alias PlaywrightEx.{Response, WebSocket}

  # test.describe("exception handling"): ExUnit's describe blocks don't nest, so the outer
  # describe is the module (its beforeEach a module-level setup) and the inner describes are
  # named "exception handling <inner>".

  # The describe's `let`s, reset in beforeEach, are an Agent each (the listeners run in
  # processes of their own).
  setup %{page: page} do
    {:ok, network_events} = Agent.start_link(fn -> [] end)
    {:ok, web_socket_events} = Agent.start_link(fn -> [] end)
    {:ok, console_messages} = Agent.start_link(fn -> [] end)

    Page.on(page, :request, fn request ->
      push(network_events, %{method: Request.method(request), url: Request.url(request)})
    end)

    Page.on(page, :web_socket, fn ws ->
      WebSocket.on(ws, :frame_sent, fn event ->
        push(web_socket_events, %{type: "sent", payload: event.payload})
      end)

      WebSocket.on(ws, :frame_received, fn event ->
        push(web_socket_events, %{type: "received", payload: event.payload})
      end)

      WebSocket.on(ws, :close, fn _ -> push(web_socket_events, %{type: "close"}) end)
    end)

    Page.on(page, :console, fn msg -> push(console_messages, ConsoleMessage.text(msg)) end)

    %{
      network_events: network_events,
      web_socket_events: web_socket_events,
      console_messages: console_messages
    }
  end

  defp push(agent, value), do: Agent.update(agent, &(&1 ++ [value]))
  defp get(agent), do: Agent.get(agent, & &1)
  defp reset(agent), do: Agent.update(agent, fn _ -> [] end)

  # expect(actual).toEqual(expect.arrayContaining([expect.stringMatching(re), ...]))
  defp assert_array_containing_matching(actual, patterns) do
    for pattern <- patterns do
      assert Enum.any?(actual, &(&1 =~ pattern)),
             "expected #{inspect(actual)} to contain a string matching #{inspect(pattern)}"
    end
  end

  # expect(actual).toEqual([expect.stringMatching(re), ...]) (also stringContaining)
  defp assert_each_matching(actual, patterns) do
    assert length(actual) == length(patterns),
           "expected #{inspect(actual)} to match #{inspect(patterns)}"

    for {string, pattern} <- Enum.zip(actual, patterns) do
      assert string =~ pattern, "expected #{inspect(actual)} to match #{inspect(patterns)}"
    end
  end

  describe "exception handling during HTTP mount" do
    test "500 error when dead mount fails", %{page: page} do
      Page.on(page, :response, fn response ->
        assert Response.status(response) == 500
      end)

      Page.goto!(page, "/errors?dead-mount=raise")
    end
  end

  describe "exception handling during connected mount" do
    # When the connected mount fails, the page is reloaded. The hope here is
    # that the next time the page is loaded, either the connected mount will
    # succeed, or the same error will be triggered during the dead mount as well,
    # rendering an error page.
    #
    # In the unlikely case that the dead mount succeeds, but the connected mount
    # fails repeatedly, the liveSocket enters failsafe mode. This still means that
    # the page will be reloaded without giving up, but the duration is set to 30s
    # by default.
    test "reloads the page when connected mount fails", %{
      page: page,
      network_events: network_events,
      console_messages: console_messages
    } do
      Page.goto!(page, "/errors?connected-mount=raise")

      # the page was loaded once
      assert network_events
             |> get()
             |> Enum.filter(
               &String.contains?(&1.url, "http://localhost:4004/errors?connected-mount=raise")
             )
             |> length() == 1

      reset(network_events)

      Page.wait_for_timeout!(page, 2000)

      # the page was reloaded 5 times
      # (expect.arrayContaining with the same request listed 7 times)
      events = get(network_events)

      for expected <-
            List.duplicate(
              %{method: "GET", url: "http://localhost:4004/errors?connected-mount=raise"},
              7
            ) do
        assert expected in events
      end

      assert_array_containing_matching(get(console_messages), [
        ~r/consecutive reloads. Entering failsafe mode/
      ])
    end

    # TBD: if the connected mount of the main LV succeeds, but a child LV fails
    # on mount, we only try to rejoin the child LV instead of reloading the page.
    test "rejoin instead of reload when child LV fails on connected mount", %{
      page: page,
      network_events: network_events,
      console_messages: console_messages
    } do
      Page.goto!(page, "/errors?connected-child-mount-raise=2")
      Page.wait_for_timeout!(page, 2000)

      assert_array_containing_matching(get(console_messages), [
        ~r/mount/,
        ~r/child error: unable to join/,
        ~r/child error: unable to join/,
        # third time's the charm
        ~r/child mount/
      ])

      # page was not reloaded
      assert network_events
             |> get()
             |> Enum.filter(&String.contains?(&1.url, "http://localhost:4004/errors?"))
             |> length() == 1
    end

    # TBD: if the connected mount of the main LV succeeds, but a child LV fails
    # repeatedly, we reload the page. Maybe we should give up without reloading the page?
    test "abandons child remount if child LV fails multiple times", %{
      page: page,
      network_events: network_events,
      console_messages: console_messages
    } do
      Page.goto!(page, "/errors?connected-child-mount-raise=5")
      # maybe we can find a better way than waiting for a fixed amount of time
      Page.wait_for_timeout!(page, 1000)

      # expect.stringContaining: a string pattern
      assert_each_matching(
        console_messages |> get() |> Enum.filter(&String.starts_with?(&1, "child ")),
        [
          "child error: unable to join",
          "child error: unable to join",
          "child error: unable to join",
          # maxChildJoinTries is 3, we count from 0, so the 4th try is the last
          "child error: giving up",
          "child destroyed"
        ]
      )

      # page remained loaded without parent failsafe reload
      assert network_events
             |> get()
             |> Enum.filter(
               &String.contains?(
                 &1.url,
                 "http://localhost:4004/errors?connected-child-mount-raise=5"
               )
             )
             |> length() == 1
    end
  end

  describe "exception handling after connected mount" do
    # When a child LV crashes after the connected mount, the parent LV is not
    # affected. The child LV is simply remounted.
    test "page does not reload if child LV crashes (handle_event)", %{
      page: page,
      network_events: network_events,
      console_messages: console_messages
    } do
      Page.goto!(page, "/errors?child")
      sync_lv(page)

      parent_time = page |> Page.locator("#render-time") |> Locator.inner_text!()
      child_time = page |> Page.locator("#child-render-time") |> Locator.inner_text!()

      # both lvs mounted, no other messages
      assert_array_containing_matching(get(console_messages), [~r/mount/, ~r/child mount/])
      reset(console_messages)

      page |> Page.get_by_role(:button, name: "Crash child") |> Locator.click!()
      sync_lv(page)

      # child crashed and re-rendered
      new_child_time = Page.locator(page, "#child-render-time")
      new_child_time |> Expect.not_() |> Expect.to_have_text!(child_time)

      assert_each_matching(get(console_messages), [
        ~r/child error: view crashed/,
        ~r/child mount/
      ])

      # parent did not re-render
      new_parent_tiem = Page.locator(page, "#render-time")
      Expect.to_have_text!(new_parent_tiem, parent_time)

      # page was not reloaded
      assert network_events
             |> get()
             |> Enum.filter(&String.contains?(&1.url, "http://localhost:4004/errors?child"))
             |> length() == 1
    end

    # When the main LV crashes after the connected mount, the page is not reloaded.
    # The main LV is simply remounted over the existing transport.
    test "page does not reload if main LV crashes (handle_event)", %{
      page: page,
      network_events: network_events,
      console_messages: console_messages
    } do
      Page.goto!(page, "/errors?child")
      sync_lv(page)

      parent_time = page |> Page.locator("#render-time") |> Locator.inner_text!()
      child_time = page |> Page.locator("#child-render-time") |> Locator.inner_text!()

      # both lvs mounted, no other messages
      assert_array_containing_matching(get(console_messages), [~r/mount/, ~r/child mount/])
      reset(console_messages)

      page |> Page.get_by_role(:button, name: "Crash main") |> Locator.click!()
      sync_lv(page)

      # main and child re-rendered (full page refresh)
      new_child_time = Page.locator(page, "#child-render-time")
      new_child_time |> Expect.not_() |> Expect.to_have_text!(child_time)
      new_parent_tiem = Page.locator(page, "#render-time")
      new_parent_tiem |> Expect.not_() |> Expect.to_have_text!(parent_time)

      assert_each_matching(get(console_messages), [
        ~r/child destroyed/,
        ~r/error: view crashed/,
        ~r/mount/,
        ~r/child mount/
      ])

      # page was not reloaded
      assert network_events
             |> get()
             |> Enum.filter(&String.contains?(&1.url, "http://localhost:4004/errors?child"))
             |> length() == 1
    end

    # When the main LV mounts successfully, but a child LV crashes which is linked
    # to the parent, the parent LV crashed too, triggering a remount of both.
    test "parent crashes and reconnects when linked child LV crashes", %{
      page: page,
      network_events: network_events,
      console_messages: console_messages
    } do
      Page.goto!(page, "/errors?connected-child-mount-raise=link")
      sync_lv(page)

      # child crashed on mount, linked to parent -> parent crashed too
      # second mounts are successful
      assert_array_containing_matching(get(console_messages), [
        ~r/mount/,
        ~r/child error: unable to join/,
        ~r/child destroyed/,
        ~r/error: view crashed/,
        ~r/mount/,
        ~r/child mount/
      ])

      reset(console_messages)

      parent_time = page |> Page.locator("#render-time") |> Locator.inner_text!()
      child_time = page |> Page.locator("#child-render-time") |> Locator.inner_text!()

      # the processes are still linked, crashing the child again crashes the parent
      page |> Page.get_by_role(:button, name: "Crash child") |> Locator.click!()
      sync_lv(page)

      # main and child re-rendered (full page refresh)
      new_child_time = Page.locator(page, "#child-render-time")
      new_child_time |> Expect.not_() |> Expect.to_have_text!(child_time)
      new_parent_tiem = Page.locator(page, "#render-time")
      new_parent_tiem |> Expect.not_() |> Expect.to_have_text!(parent_time)

      assert_each_matching(get(console_messages), [
        ~r/child error: view crashed/,
        ~r/child destroyed/,
        ~r/error: view crashed/,
        ~r/mount/,
        ~r/child mount/
      ])

      # page was not reloaded
      assert network_events
             |> get()
             |> Enum.filter(
               &String.contains?(
                 &1.url,
                 "http://localhost:4004/errors?connected-child-mount-raise=link"
               )
             )
             |> length() == 1
    end
  end
end
