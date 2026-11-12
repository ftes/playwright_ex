defmodule LiveViewE2E.NavigationTest do
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

  test "can navigate between LiveViews in the same live session over websocket", %{
    page: page,
    events: events
  } do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    assert events
           |> get(:network_events)
           |> Enum.filter(&String.contains?(&1.url, "http://localhost:4004/navigation/"))
           |> length() == 1

    assert [%{type: "sent", payload: payload1}, %{type: "received", payload: payload2}] =
             get(events, :web_socket_events)

    assert payload1 =~ "phx_join"
    assert payload2 =~ "phx_reply"

    # clear events
    clear(events, :network_events)
    clear(events, :web_socket_events)

    # patch the LV
    length = Page.evaluate!(page, "() => window.history.length")
    page |> Page.get_by_role(:link, name: "Patch this LiveView") |> Locator.click!()
    sync_lv(page)
    assert get(events, :network_events) == []

    assert [%{type: "sent", payload: payload1}, %{type: "received", payload: payload2}] =
             get(events, :web_socket_events)

    assert payload1 =~ "live_patch"
    assert payload2 =~ "phx_reply"
    assert Page.evaluate!(page, "() => window.history.length") == length + 1

    clear(events, :web_socket_events)

    # live navigation to other LV
    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()
    sync_lv(page)

    assert get(events, :network_events) == []
    # we don't assert the order of the events here, because they are not deterministic
    web_socket_events = get(events, :web_socket_events)
    assert has_frame?(web_socket_events, "sent", "phx_leave")
    assert has_frame?(web_socket_events, "sent", "phx_join")
    assert has_frame?(web_socket_events, "received", "phx_close")
    assert has_frame?(web_socket_events, "received", "phx_reply")
    assert has_frame?(web_socket_events, "received", "phx_reply")
  end

  test "handles live redirect loops", %{page: page, events: events} do
    Page.goto!(page, "/navigation/redirectloop")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "Redirect Loop") |> Locator.click!()

    to_pass(fn ->
      assert events |> get(:web_socket_events) |> has_frame?("received", "phx_error")
    end)

    # We need to wait for the LV to reconnect
    sync_lv(page)
    message = Page.locator(page, "#message")
    Expect.to_have_text!(message, "Too many redirects")
  end

  test "popstate", %{page: page, events: events} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    # clear network events
    clear(events, :network_events)

    page |> Page.get_by_role(:link, name: "Patch this LiveView") |> Locator.click!()
    sync_lv(page)
    Expect.to_have_url!(page, ~r/\/navigation\/a\?/)
    assert get(events, :network_events) == []

    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/b")
    assert get(events, :network_events) == []

    Page.go_back!(page)
    sync_lv(page)
    assert get(events, :network_events) == []
    Expect.to_have_url!(page, ~r/\/navigation\/a\?/)

    Page.go_back!(page)
    sync_lv(page)
    assert get(events, :network_events) == []
    Expect.to_have_url!(page, "/navigation/a")

    # and forward again
    Page.go_forward!(page)
    Page.go_forward!(page)
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/b")

    # everything was sent over the websocket, no network requests
    assert get(events, :network_events) == []
  end

  test "can prevent live link navigation with before navigate", %{page: page, events: events} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    Page.evaluate!(page, """
    () => {
      window.beforeNavigateEvents = [];
      window.navigateEvents = [];
      window.preventNavigation = true;
      window.addEventListener("phx:before-navigate", (event) => {
        window.beforeNavigateEvents.push(event.detail);
        if (window.preventNavigation) {
          event.preventDefault();
        }
      });
      window.addEventListener("phx:navigate", (event) => {
        window.navigateEvents.push(event.detail);
      });
    }
    """)

    clear(events, :network_events)
    clear(events, :web_socket_events)

    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()

    Expect.to_have_url!(page, "/navigation/a")
    assert get(events, :network_events) == []
    assert get(events, :web_socket_events) == []

    assert Page.evaluate!(page, "() => window.beforeNavigateEvents") == [
             %{
               "href" => "http://localhost:4004/navigation/b",
               "patch" => false,
               "pop" => false,
               "direction" => "forward"
             }
           ]

    assert Page.evaluate!(page, "() => window.navigateEvents") == []

    Page.evaluate!(page, """
    () => {
      window.preventNavigation = false;
    }
    """)

    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()
    sync_lv(page)

    Expect.to_have_url!(page, "/navigation/b")
    assert get(events, :network_events) == []
  end

  test "can prevent popstate navigation with before navigate", %{page: page, events: events} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/b")

    Page.evaluate!(page, """
    () => {
      window.beforeNavigateEvents = [];
      window.navigateEvents = [];
      window.preventNavigation = true;
      window.addEventListener("phx:before-navigate", (event) => {
        window.beforeNavigateEvents.push(event.detail);
        if (window.preventNavigation) {
          event.preventDefault();
        }
      });
      window.addEventListener("phx:navigate", (event) => {
        window.navigateEvents.push(event.detail);
      });
    }
    """)

    clear(events, :network_events)
    clear(events, :web_socket_events)

    Page.go_back!(page)

    Expect.to_have_url!(page, "/navigation/b")
    assert get(events, :network_events) == []
    assert get(events, :web_socket_events) == []

    assert Page.evaluate!(page, "() => window.beforeNavigateEvents") == [
             %{
               "href" => "http://localhost:4004/navigation/a",
               "patch" => false,
               "pop" => true,
               "direction" => "backward"
             }
           ]

    assert Page.evaluate!(page, "() => window.navigateEvents") == []

    Page.evaluate!(page, """
    () => {
      window.preventNavigation = false;
    }
    """)

    Page.go_back!(page)
    sync_lv(page)

    Expect.to_have_url!(page, "/navigation/a")
    assert get(events, :network_events) == []
  end

  test "can prevent popstate navigation across a fragment entry with before navigate", %{
    page: page
  } do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()
    sync_lv(page)
    page |> Page.get_by_role(:link, name: "Go to 42.") |> Locator.click!()
    Expect.to_have_url!(page, "/navigation/b#items-item-42")
    page |> Page.get_by_role(:link, name: "Item 1", exact: true) |> Locator.click!()
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/b/item-1")

    Page.evaluate!(page, "() => history.go(-3)")
    Expect.to_have_url!(page, "/navigation/a")
    sync_lv(page)

    Page.evaluate!(page, """
    () => {
      window.beforeNavigateEvents = [];
      window.preventNavigation = true;
      window.addEventListener("phx:before-navigate", (event) => {
        window.beforeNavigateEvents.push(event.detail);
        if (window.preventNavigation) {
          event.preventDefault();
        }
      });
    }
    """)

    Page.evaluate!(page, "() => history.go(3)")

    # expect.poll(...).not.toEqual([]) (poll's default timeout is the expect timeout)
    to_pass(
      fn -> assert Page.evaluate!(page, "() => window.beforeNavigateEvents") != [] end,
      timeout: 5000
    )

    Expect.to_have_url!(page, "/navigation/a")

    assert Page.evaluate!(page, "() => window.beforeNavigateEvents") == [
             %{
               "href" => "http://localhost:4004/navigation/b/item-1",
               "patch" => true,
               "pop" => true,
               "direction" => "forward"
             }
           ]

    # the revert returned to the original entry
    Page.evaluate!(page, """
    () => {
      window.preventNavigation = false;
    }
    """)

    Page.evaluate!(page, "() => history.go(3)")
    Expect.to_have_url!(page, "/navigation/b/item-1")
    sync_lv(page)

    Page.evaluate!(page, """
    () => {
      window.beforeNavigateEvents = [];
      window.preventNavigation = true;
    }
    """)

    Page.evaluate!(page, "() => history.go(-3)")

    to_pass(
      fn -> assert Page.evaluate!(page, "() => window.beforeNavigateEvents") != [] end,
      timeout: 5000
    )

    Expect.to_have_url!(page, "/navigation/b/item-1")

    assert Page.evaluate!(page, "() => window.beforeNavigateEvents") == [
             %{
               "href" => "http://localhost:4004/navigation/a",
               "patch" => false,
               "pop" => true,
               "direction" => "backward"
             }
           ]
  end

  test "can prevent popstate navigation to an entry pushed by other scripts with before navigate",
       %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()
    sync_lv(page)
    Page.evaluate!(page, ~s|() => history.pushState(null, "", "/navigation/b?foreign=1")|)
    page |> Page.get_by_role(:link, name: "Item 1", exact: true) |> Locator.click!()
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/b/item-1")

    Page.evaluate!(page, "() => history.go(-3)")
    Expect.to_have_url!(page, "/navigation/a")
    sync_lv(page)

    Page.evaluate!(page, """
    () => {
      window.beforeNavigateEvents = [];
      window.preventNavigation = true;
      window.addEventListener("phx:before-navigate", (event) => {
        window.beforeNavigateEvents.push(event.detail);
        if (window.preventNavigation) {
          event.preventDefault();
        }
      });
    }
    """)

    Page.evaluate!(page, "() => history.go(2)")

    to_pass(
      fn -> assert Page.evaluate!(page, "() => window.beforeNavigateEvents") != [] end,
      timeout: 5000
    )

    Expect.to_have_url!(page, "/navigation/a")

    assert Page.evaluate!(page, "() => window.beforeNavigateEvents") == [
             %{
               "href" => "http://localhost:4004/navigation/b?foreign=1",
               "patch" => false,
               "pop" => true,
               "direction" => "forward"
             }
           ]

    # the revert returned to the original entry
    Page.evaluate!(page, """
    () => {
      window.preventNavigation = false;
    }
    """)

    Page.evaluate!(page, "() => history.go(3)")
    Expect.to_have_url!(page, "/navigation/b/item-1")
  end

  test "can prevent popstate navigation across an iframe entry with before navigate", %{
    page: page
  } do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()
    sync_lv(page)
    # the iframe lives outside the LiveView, so it survives live navigation
    Page.evaluate!(page, """
    () =>
      new Promise((resolve) => {
        const iframe = document.createElement("iframe");
        iframe.srcdoc = "<p>iframe</p>";
        iframe.onload = () => {
          iframe.contentWindow.history.pushState(null, "");
          resolve();
        };
        document.body.appendChild(iframe);
      })
    """)

    page |> Page.get_by_role(:link, name: "Item 1", exact: true) |> Locator.click!()
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/b/item-1")

    Page.evaluate!(page, "() => history.go(-3)")
    Expect.to_have_url!(page, "/navigation/a")
    sync_lv(page)

    Page.evaluate!(page, """
    () => {
      window.beforeNavigateEvents = [];
      window.preventNavigation = true;
      window.addEventListener("phx:before-navigate", (event) => {
        window.beforeNavigateEvents.push(event.detail);
        if (window.preventNavigation) {
          event.preventDefault();
        }
      });
    }
    """)

    Page.evaluate!(page, "() => history.go(3)")

    to_pass(
      fn -> assert Page.evaluate!(page, "() => window.beforeNavigateEvents") != [] end,
      timeout: 5000
    )

    Expect.to_have_url!(page, "/navigation/a")

    assert Page.evaluate!(page, "() => window.beforeNavigateEvents") == [
             %{
               "href" => "http://localhost:4004/navigation/b/item-1",
               "patch" => true,
               "pop" => true,
               "direction" => "forward"
             }
           ]

    # the revert returned to the original entry
    Page.evaluate!(page, """
    () => {
      window.preventNavigation = false;
    }
    """)

    Page.evaluate!(page, "() => history.go(3)")
    Expect.to_have_url!(page, "/navigation/b/item-1")
  end

  test "before navigate does not prevent server-side navigation", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    Page.evaluate!(page, """
    () => {
      window.beforeNavigateEvents = [];
      window.addEventListener("phx:before-navigate", (event) => {
        window.beforeNavigateEvents.push(event.detail);
        event.preventDefault();
      });
    }
    """)

    page |> Page.get_by_role(:button, name: "Server Navigate") |> Locator.click!()
    sync_lv(page)

    Expect.to_have_url!(page, "/navigation/b")
    assert Page.evaluate!(page, "() => window.beforeNavigateEvents") == []
  end

  test "JS.patch and JS.navigate resolve relative hrefs", %{page: page, events: events} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    clear(events, :network_events)
    clear(events, :web_socket_events)

    page |> Page.get_by_role(:button, name: "JS patch (relative)") |> Locator.click!()
    sync_lv(page)

    Expect.to_have_url!(page, ~r/\/navigation\/a\?param=-?\d+$/)
    url = Page.url(page)
    param = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.get("param")
    page |> Page.get_by_text("Current param: #{param}") |> Expect.to_be_visible!()
    assert get(events, :network_events) == []

    assert [%{type: "sent", payload: payload1}, %{type: "received", payload: payload2}] =
             get(events, :web_socket_events)

    assert payload1 =~ ~s|"live_patch",{"url":"#{url}"}|
    assert payload2 =~ "phx_reply"

    # a rejoin sends the full URL as well
    clear(events, :web_socket_events)

    Page.evaluate!(
      page,
      "() => new Promise((resolve) => window.liveSocket.disconnect(resolve))"
    )

    Page.evaluate!(page, "() => window.liveSocket.connect()")
    sync_lv(page)

    page |> Page.get_by_text("Current param: #{param}") |> Expect.to_be_visible!()
    assert events |> get(:web_socket_events) |> has_frame?("sent", ~s|"url":"#{url}"|)

    clear(events, :network_events)
    clear(events, :web_socket_events)

    page |> Page.get_by_role(:button, name: "JS navigate (relative)") |> Locator.click!()
    sync_lv(page)

    Expect.to_have_url!(page, "/navigation/b")

    assert events
           |> get(:network_events)
           |> Enum.filter(&String.contains?(&1.url, "/navigation/")) == []

    assert events
           |> get(:web_socket_events)
           |> has_frame?("sent", ~s|"redirect":"http://localhost:4004/navigation/b"|)
  end

  test "patch with replace replaces history", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)
    url = Page.url(page)

    length = Page.evaluate!(page, "() => window.history.length")

    page |> Page.get_by_role(:link, name: "Patch (Replace)") |> Locator.click!()
    sync_lv(page)

    assert Page.evaluate!(page, "() => window.history.length") == length
    assert Page.url(page) != url
  end

  test "navigate creates its history entry when the link is clicked", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)
    length = Page.evaluate!(page, "() => window.history.length")

    page |> Page.get_by_role(:link, name: "Slow", exact: true) |> Locator.click!()
    # the entry exists while the slow LiveView is still mounting
    Expect.to_have_url!(page, "/navigation/slow?sleep=1000")
    page |> Page.get_by_role(:heading, name: "This is page A") |> Expect.to_be_visible!()
    assert Page.evaluate!(page, "() => window.history.length") == length + 1

    page |> Page.get_by_role(:heading, name: "This is the slow page") |> Expect.to_be_visible!()
    sync_lv(page)
    assert Page.evaluate!(page, "() => window.history.length") == length + 1
    assert %{"type" => "redirect"} = Page.evaluate!(page, "() => window.history.state")

    Page.go_back!(page)
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/a")
    page |> Page.get_by_role(:heading, name: "This is page A") |> Expect.to_be_visible!()
  end

  test "going back while navigate is pending cancels the navigation", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "Slow", exact: true) |> Locator.click!()
    Expect.to_have_url!(page, "/navigation/slow?sleep=1000")
    Page.go_back!(page)

    Expect.to_have_url!(page, "/navigation/a")
    page |> Page.get_by_role(:heading, name: "This is page A") |> Expect.to_be_visible!()
    sync_lv(page)
    # the slow mount has finished by now, but must not be rendered
    Page.wait_for_timeout!(page, 1500)
    Expect.to_have_url!(page, "/navigation/a")
    page |> Page.get_by_role(:heading, name: "This is page A") |> Expect.to_be_visible!()
  end

  test "navigate that supersedes a pending navigate reuses its history entry", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)
    length = Page.evaluate!(page, "() => window.history.length")

    page |> Page.get_by_role(:link, name: "Slow", exact: true) |> Locator.click!()
    Expect.to_have_url!(page, "/navigation/slow?sleep=1000")
    page |> Page.get_by_role(:link, name: "LiveView B") |> Locator.click!()
    sync_lv(page)

    Expect.to_have_url!(page, "/navigation/b")
    page |> Page.get_by_role(:heading, name: "This is page B") |> Expect.to_be_visible!()
    assert Page.evaluate!(page, "() => window.history.length") == length + 1

    Page.go_back!(page)
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/a")
  end

  test "live redirect on mount replaces the navigate history entry", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)
    length = Page.evaluate!(page, "() => window.history.length")

    page |> Page.get_by_role(:link, name: "Slow (live redirect)") |> Locator.click!()
    sync_lv(page)

    Expect.to_have_url!(page, "/navigation/b")
    page |> Page.get_by_role(:heading, name: "This is page B") |> Expect.to_be_visible!()
    assert Page.evaluate!(page, "() => window.history.length") == length + 1

    Page.go_back!(page)
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/a")
  end

  test "redirect on mount replaces the navigate history entry", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)
    length = Page.evaluate!(page, "() => window.history.length")

    page |> Page.get_by_role(:link, name: "Slow (redirect)") |> Locator.click!()

    Expect.to_have_url!(page, "/navigation/dead")
    page |> Page.get_by_role(:heading, name: "Dead view") |> Expect.to_be_visible!()
    assert Page.evaluate!(page, "() => window.history.length") == length + 1

    Page.go_back!(page)
    sync_lv(page)
    Expect.to_have_url!(page, "/navigation/a")
  end

  for name <- ["Patch to fragment", "Navigate to fragment"] do
    test ~s|going back while "#{name}" is pending cancels the navigation|, %{page: page} do
      Page.goto!(page, "/navigation/a")
      sync_lv(page)
      Page.evaluate!(page, "() => window.liveSocket.enableLatencySim(500)")

      page |> Page.get_by_role(:link, name: unquote(name)) |> Locator.click!()
      Expect.to_have_url!(page, "/navigation/a#fragment")
      Page.go_back!(page)
      Expect.to_have_url!(page, "/navigation/a")

      # the reply has arrived by now, but must not restore the fragment
      Page.wait_for_timeout!(page, 1500)
      Expect.to_have_url!(page, "/navigation/a")
      page |> Page.get_by_role(:heading, name: "This is page A") |> Expect.to_be_visible!()
    end
  end

  test "canceling back keeps a pending fragment-only navigation", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    Page.evaluate!(page, """
    () => {
      window.canceledPops = 0;
      window.addEventListener("phx:before-navigate", (event) => {
        if (event.detail.pop) {
          window.canceledPops++;
          event.preventDefault();
        }
      });
      window.liveSocket.enableLatencySim(500);
    }
    """)

    page |> Page.get_by_role(:link, name: "Patch to fragment") |> Locator.click!()
    Expect.to_have_url!(page, "/navigation/a#fragment")
    Page.go_back!(page)

    Page.wait_for_timeout!(page, 1500)
    Expect.to_have_url!(page, "/navigation/a#fragment")
    assert Page.evaluate!(page, "() => window.canceledPops") == 1
  end

  test "live links to another origin fall back to http navigation", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "Other origin") |> Locator.click!()

    Expect.to_have_url!(page, "http://127.0.0.1:4004/navigation/dead")
    page |> Page.get_by_role(:heading, name: "Dead view") |> Expect.to_be_visible!()
  end

  test "falls back to http navigation when navigating between live sessions", %{
    page: page,
    events: events
  } do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    clear(events, :network_events)
    clear(events, :web_socket_events)

    # live navigation to page in another live session
    page |> Page.get_by_role(:link, name: "LiveView (other session)") |> Locator.click!()
    sync_lv(page)

    assert %{method: "GET", url: "http://localhost:4004/stream"} in get(events, :network_events)

    web_socket_events = get(events, :web_socket_events)
    assert has_frame?(web_socket_events, "sent", "phx_leave")
    assert has_frame?(web_socket_events, "sent", "phx_join")
    assert has_frame?(web_socket_events, "received", ~r/error.*unauthorized/)
  end

  test "restores scroll position after navigation", %{page: page} do
    Page.goto!(page, "/navigation/b")
    sync_lv(page)

    page |> Page.locator("#items") |> Expect.to_contain_text!("Item 42")

    assert Page.evaluate!(page, "() => document.documentElement.scrollTop") == 0

    offset =
      (page |> Page.locator("#items-item-42") |> Locator.evaluate!("(el) => el.offsetTop")) - 200

    Page.evaluate!(page, "(offset) => window.scrollTo(0, offset)", offset)
    # LiveView only updates the scroll position every 100ms
    Page.wait_for_timeout!(page, 150)

    page |> Page.get_by_role(:link, name: "Item 42") |> Locator.click!()
    sync_lv(page)

    Page.go_back!(page)
    sync_lv(page)

    # scroll position is restored
    to_pass(
      fn ->
        assert Page.evaluate!(page, "() => document.documentElement.scrollTop") == offset,
               "scrollTop not restored"
      end,
      timeout: 5000
    )
  end

  test "does not restore scroll position on custom container after navigation", %{page: page} do
    Page.goto!(page, "/navigation/b?container=1")
    sync_lv(page)

    page |> Page.locator("#items") |> Expect.to_contain_text!("Item 42")

    assert page
           |> Page.locator("#my-scroll-container")
           |> Locator.evaluate!("(el) => el.scrollTop") == 0

    offset =
      (page |> Page.locator("#items-item-42") |> Locator.evaluate!("(el) => el.offsetTop")) - 200

    page
    |> Page.locator("#my-scroll-container")
    |> Locator.evaluate!("(el, offset) => el.scrollTo(0, offset)", offset)

    page |> Page.get_by_role(:link, name: "Item 42") |> Locator.click!()
    sync_lv(page)

    Page.go_back!(page)
    sync_lv(page)

    # scroll position is not restored
    to_pass(
      fn ->
        assert page
               |> Page.locator("#my-scroll-container")
               |> Locator.evaluate!("(el) => el.scrollTop") == 0,
               "scrollTop not restored"
      end,
      timeout: 5000
    )
  end

  test "scrolls hash el into view", %{page: page} do
    Page.goto!(page, "/navigation/b")
    sync_lv(page)

    page |> Page.locator("#items") |> Expect.to_contain_text!("Item 42")

    assert page
           |> Page.locator("#my-scroll-container")
           |> Locator.evaluate!("(el) => el.scrollTop") == 0

    offset =
      (page |> Page.locator("#items-item-42") |> Locator.evaluate!("(el) => el.offsetTop")) - 200

    page |> Page.get_by_role(:link, name: "Go to 42") |> Locator.click!()
    Expect.to_have_url!(page, "/navigation/b#items-item-42")

    scroll_top = Page.evaluate!(page, "() => document.documentElement.scrollTop")
    assert scroll_top != 0
    assert scroll_top >= offset - 500
    assert scroll_top <= offset + 500

    Page.goto!(page, "/navigation/a")
    Page.goto!(page, "/navigation/b#items-item-42")

    scroll_top = Page.evaluate!(page, "() => document.documentElement.scrollTop")
    assert scroll_top != 0
    assert scroll_top >= offset - 500
    assert scroll_top <= offset + 500
  end

  test "scrolls hash el into view after live navigation (issue #3452)", %{page: page} do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)

    page |> Page.get_by_role(:link, name: "Navigate to 42") |> Locator.click!()
    Expect.to_have_url!(page, "/navigation/b#items-item-42")
    # the URL is updated on click, before the new LiveView is rendered
    page |> Page.get_by_role(:heading, name: "This is page B") |> Expect.to_be_visible!()

    offset =
      (page |> Page.locator("#items-item-42") |> Locator.evaluate!("(el) => el.offsetTop")) - 200

    to_pass(
      fn ->
        assert Page.evaluate!(page, "() => document.documentElement.scrollTop") >= offset - 500
      end,
      timeout: 5000
    )

    scroll_top = Page.evaluate!(page, "() => document.documentElement.scrollTop")
    assert scroll_top <= offset + 500
  end

  test "restores scroll position when navigating from dead view", %{page: page} do
    Page.goto!(page, "/navigation/b")
    sync_lv(page)

    page |> Page.locator("#items") |> Expect.to_contain_text!("Item 42")

    assert Page.evaluate!(page, "() => document.documentElement.scrollTop") == 0

    offset =
      (page |> Page.locator("#items-item-42") |> Locator.evaluate!("(el) => el.offsetTop")) - 200

    Page.evaluate!(page, "(offset) => window.scrollTo(0, offset)", offset)
    # LiveView only updates the scroll position every 100ms
    Page.wait_for_timeout!(page, 150)

    page |> Page.get_by_role(:link, name: "Dead") |> Locator.click!()
    Page.wait_for_url!(page, "/navigation/dead")
    # live navigation updates the URL before falling back to a page load
    page |> Page.get_by_role(:heading, name: "Dead view") |> Expect.to_be_visible!()

    Page.go_back!(page)
    sync_lv(page)

    # scroll position is restored
    to_pass(
      fn ->
        assert Page.evaluate!(page, "() => document.documentElement.scrollTop") == offset,
               "scrollTop not restored"
      end,
      timeout: 5000
    )
  end

  test "navigating all the way back works without remounting (only patching)", %{
    page: page,
    events: events
  } do
    Page.goto!(page, "/navigation/a")
    sync_lv(page)
    clear(events, :network_events)
    page |> Page.get_by_role(:link, name: "Patch this LiveView") |> Locator.click!()
    sync_lv(page)
    Page.go_back!(page)
    sync_lv(page)
    assert get(events, :network_events) == []
    # we only expect patch navigation
    assert events
           |> get(:web_socket_events)
           |> Enum.filter(&String.contains?(&1.payload, "phx_leave"))
           |> length() == 0

    # we patched 2 times
    assert events
           |> get(:web_socket_events)
           |> Enum.filter(&String.contains?(&1.payload, "live_patch"))
           |> length() == 2
  end

  # see https://github.com/phoenixframework/phoenix_live_view/pull/3513
  # see https://github.com/phoenixframework/phoenix_live_view/issues/3536
  test "back and forward navigation types are tracked", %{page: page, events: events} do
    {:ok, console_messages} = Agent.start(fn -> [] end)

    Page.on(page, :console, fn msg ->
      Agent.update(console_messages, &(&1 ++ [ConsoleMessage.text(msg)]))
    end)

    get_navigation_event = fn ->
      ev =
        Agent.get_and_update(console_messages, fn messages ->
          {Enum.find(messages, &String.starts_with?(&1, "navigate event")), []}
        end)

      ev |> String.slice(15..-1//1) |> JSON.decode!()
    end

    # initial page visit
    Page.goto!(page, "/navigation/b")
    sync_lv(page)
    Agent.update(console_messages, fn _ -> [] end)
    clear(events, :network_events)
    # type: redirect
    page |> Page.get_by_role(:link, name: "LiveView A") |> Locator.click!()
    sync_lv(page)

    assert get_navigation_event.() == %{
             "href" => "http://localhost:4004/navigation/a",
             "patch" => false,
             "pop" => false,
             "direction" => "forward"
           }

    # type: patch
    page |> Page.get_by_role(:link, name: "Patch this LiveView") |> Locator.click!()
    sync_lv(page)

    assert %{"href" => href, "patch" => true, "pop" => false, "direction" => "forward"} =
             event = get_navigation_event.()

    assert map_size(event) == 4
    assert href =~ ~r/\/navigation\/a\?param=.*/
    # back should also be type: patch
    Page.go_back!(page)
    Expect.to_have_url!(page, "/navigation/a")

    assert get_navigation_event.() == %{
             "href" => "http://localhost:4004/navigation/a",
             "patch" => true,
             "pop" => true,
             "direction" => "backward"
           }

    Page.go_back!(page)
    Expect.to_have_url!(page, "/navigation/b")

    assert get_navigation_event.() == %{
             "href" => "http://localhost:4004/navigation/b",
             "patch" => false,
             "pop" => true,
             "direction" => "backward"
           }

    Page.go_forward!(page)
    Expect.to_have_url!(page, "/navigation/a")

    assert get_navigation_event.() == %{
             "href" => "http://localhost:4004/navigation/a",
             "patch" => false,
             "pop" => true,
             "direction" => "forward"
           }

    Page.go_forward!(page)
    Expect.to_have_url!(page, ~r/\/navigation\/a\?param=.*/)

    assert %{"href" => href, "patch" => true, "pop" => true, "direction" => "forward"} =
             event = get_navigation_event.()

    assert map_size(event) == 4
    assert href =~ ~r/\/navigation\/a\?param=.*/
    # we don't expect any full page reloads
    assert get(events, :network_events) == []
    # we only expect 3 navigate navigations (from b to a, back from a to b, back to a)
    assert events
           |> get(:web_socket_events)
           |> Enum.filter(&String.contains?(&1.payload, "phx_leave"))
           |> length() == 3

    # we expect 3 patches (a to a with param, back to a, back to a with param)
    assert events
           |> get(:web_socket_events)
           |> Enum.filter(&String.contains?(&1.payload, "live_patch"))
           |> length() == 3
  end

  # `xs.push(event)`, `xs` and `xs = []` on upstream's module-level arrays
  defp push(events, key, event),
    do: Agent.update(events, &Map.update!(&1, key, fn xs -> xs ++ [event] end))

  defp get(events, key), do: Agent.get(events, &Map.fetch!(&1, key))
  defp clear(events, key), do: Agent.update(events, &Map.put(&1, key, []))

  # expect(webSocketEvents).toEqual(expect.arrayContaining([{ type, payload: expect.stringContaining(s) }]))
  # (or expect.stringMatching(re)), one element at a time
  defp has_frame?(web_socket_events, type, pattern) do
    Enum.any?(web_socket_events, fn
      %{type: ^type, payload: payload} = event when map_size(event) == 2 and is_binary(payload) ->
        payload =~ pattern

      _ ->
        false
    end)
  end
end
