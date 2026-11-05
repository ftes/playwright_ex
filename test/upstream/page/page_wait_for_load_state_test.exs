defmodule PlaywrightEx.Page.PageWaitForLoadStateTest do
  @upstream "tests/page/page-wait-for-load-state.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp hang(_conn), do: Process.sleep(:infinity)

  # `server.setRoute(path, (req, res) => response = res)`: the handler waits for `{:end, status, body}`.
  defp stall_route(server, path) do
    test = self()

    TestServer.set_route(server, path, fn conn ->
      send(test, {:response, self()})

      receive do
        {:end, status, body} -> Plug.Conn.send_resp(conn, status, body)
      end
    end)
  end

  # `promise.then(() => resolved = true)`: whether the task has finished, without waiting.
  defp resolved?(task), do: Task.yield(task, 0) != nil

  test "should pick up ongoing navigation", %{page: page, server: server} do
    stall_route(server, "/one-style.css")
    request = TestServer.wait_for_request(server, "/one-style.css")
    Page.goto!(page, server.prefix <> "/one-style.html", wait_until: :domcontentloaded)
    Task.await(request, :infinity)
    wait_promise = Task.async(fn -> Page.wait_for_load_state!(page) end)
    assert_receive {:response, response}
    send(response, {:end, 404, "Not found"})
    Task.await(wait_promise, :infinity)
  end

  test "should respect timeout", %{page: page, server: server} do
    TestServer.set_route(server, "/one-style.css", &hang/1)
    Page.goto!(page, server.prefix <> "/one-style.html", wait_until: :domcontentloaded)

    {error, stacktrace} =
      try do
        Page.wait_for_load_state!(page, :load, timeout: 1)
        {nil, nil}
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert Exception.message(error) =~ "page.waitForLoadState: Timeout 1ms exceeded."
    # error.stack: the Elixir stacktrace.
    assert Exception.format(:error, error, stacktrace) =~ Path.relative_to_cwd(__ENV__.file)
  end

  test "should resolve immediately if loaded", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/one-style.html")
    Page.wait_for_load_state!(page)
  end

  test "should throw for bad state", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/one-style.html")
    # Deviation: the facade rejects the invalid state before the call (upstream: the client's
    # verifyLoadState).
    error = assert_raise ArgumentError, fn -> Page.wait_for_load_state(page, :bad) end
    assert Exception.message(error) =~ "expected one of :domcontentloaded, :load, :networkidle"
  end

  test "should resolve immediately if load state matches", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/one-style.css", &hang/1)
    Page.goto!(page, server.prefix <> "/one-style.html", wait_until: :domcontentloaded)
    Page.wait_for_load_state!(page, :domcontentloaded)
  end

  test "should work with pages that have loaded before being connected to", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "() => window['_popup'] = window.open(document.location.href)")
      end)

    # The url is about:blank in FF.
    # expect(popup.url()).toBe(server.EMPTY_PAGE);
    Page.wait_for_load_state!(popup)
    assert Page.url(popup) == server.empty_page
  end

  test "should wait for load state of empty url popup", %{page: page} do
    popup_promise = Page.wait_for_event(page, :popup)

    ready_state =
      Page.evaluate!(page, """
      () => {
        const popup = window.open('');
        return popup.document.readyState;
      }
      """)

    popup = Promise.await!(popup_promise)
    Page.wait_for_load_state!(popup)
    # isOldFirefox (browserMajorVersion < 148)  -- not ported: the pinned Firefox is newer
    assert ready_state == "complete"
    assert Page.evaluate!(popup, "() => document.readyState") == "complete"
  end

  test "should wait for load state of about:blank popup ", %{page: page} do
    popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window.open('about:blank') && 1") end)
    Page.wait_for_load_state!(popup)
    assert Page.evaluate!(popup, "() => document.readyState") == "complete"
  end

  test "should wait for load state of about:blank popup with noopener ", %{page: page} do
    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "() => window.open('about:blank', null, 'noopener') && 1")
      end)

    Page.wait_for_load_state!(popup)
    assert Page.evaluate!(popup, "() => document.readyState") == "complete"
  end

  test "should wait for load state of popup with network url ", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => window.open(url) && 1", server.empty_page)
      end)

    Page.wait_for_load_state!(popup)
    assert Page.evaluate!(popup, "() => document.readyState") == "complete"
  end

  test "should wait for load state of popup with network url and noopener ", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => window.open(url, null, 'noopener') && 1", server.empty_page)
      end)

    Page.wait_for_load_state!(popup)
    assert Page.evaluate!(popup, "() => document.readyState") == "complete"
  end

  test "should work with clicking target=_blank", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a target=_blank rel="opener" href="/one-style.html">yo</a>))
    popup = Page.expect_popup!(page, fn -> Page.click!(page, "a") end)
    Page.wait_for_load_state!(popup)
    assert Page.evaluate!(popup, "() => document.readyState") == "complete"
  end

  test "should wait for load state of newPage", %{page: page} do
    context = Page.context(page)
    new_page = BrowserContext.expect_page!(context, fn -> BrowserContext.new_page!(context) end)
    Page.wait_for_load_state!(new_page)
    assert Page.evaluate!(new_page, "() => document.readyState") == "complete"
  end

  test "should resolve after popup load", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    # Stall the 'load' by delaying css.
    stall_route(server, "/one-style.css")
    css_request = TestServer.wait_for_request(server, "/one-style.css")

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => window['popup'] = window.open(url)", server.prefix <> "/one-style.html")
      end)

    Task.await(css_request, :infinity)
    assert_receive {:response, css_response}
    load_sate_promise = Task.async(fn -> Page.wait_for_load_state!(popup) end)
    # Round trips!
    for _ <- 1..5, do: Page.evaluate!(page, "window")
    refute resolved?(load_sate_promise)
    send(css_response, {:end, 200, ""})
    Task.await(load_sate_promise, :infinity)
    assert Page.url(popup) == server.prefix <> "/one-style.html"
  end

  test "should work for frame", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    frame = Enum.at(Page.frames(page), 1)

    test = self()
    Page.route!(page, server.prefix <> "/one-style.css", &send(test, {:route, &1}))
    Frame.goto!(frame, server.prefix <> "/one-style.html", wait_until: :domcontentloaded)
    assert_receive {:route, request}
    load_promise = Task.async(fn -> Frame.wait_for_load_state!(frame) end)
    # give the promise a chance to resolve, even though it shouldn't
    Page.evaluate!(page, "1")
    refute resolved?(load_promise)
    Route.continue!(request)
    Task.await(load_promise, :infinity)
  end

  test "should work with javascript: iframe", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<iframe src="javascript:false"></iframe>), wait_until: :commit)
    Page.wait_for_load_state!(page, :domcontentloaded)
    Page.wait_for_load_state!(page, :load)
    Page.wait_for_load_state!(page, :networkidle)
  end

  test "should work with broken data-url iframe", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<iframe src="data:text/html"></iframe>), wait_until: :commit)
    Page.wait_for_load_state!(page, :domcontentloaded)
    Page.wait_for_load_state!(page, :load)
    Page.wait_for_load_state!(page, :networkidle)
  end

  test "should work with broken blob-url iframe", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<iframe src="blob:"></iframe>), wait_until: :commit)
    Page.wait_for_load_state!(page, :domcontentloaded)
    Page.wait_for_load_state!(page, :load)
    Page.wait_for_load_state!(page, :networkidle)
  end
end
