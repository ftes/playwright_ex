defmodule PlaywrightEx.Library.MulticlientTest do
  @upstream "tests/library/multiclient.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [ensure_some_frames: 1, poll: 2]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Clock
  alias PlaywrightEx.Coverage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.RemoteServer.LaunchServer
  alias PlaywrightEx.Route
  alias PlaywrightEx.Screencast
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Tracing

  @browser_name System.get_env("BROWSER", "chromium")

  @k_target_closed_error_message "Target page, context or browser has been closed"

  # test.slow(true, 'All connect tests are slow'); test.skip(mode !== 'default')  -- always default mode

  @moduletag :remote_server

  # The `remoteServer` fixture: `browserType.launchServer({ _sharedBrowser: true })`, closed after
  # the test (`launch_server`, the driver's `launch-server` command); not for tests tagged
  # `remote_server: false` (upstream creates fixtures lazily).
  setup %{launch_server: launch_server} = tags do
    if tags[:remote_server] do
      {:ok, remote_server} = launch_server.(%{_sharedBrowser: true})
      on_exit(fn -> LaunchServer.close(remote_server) end)
      %{remote_server: remote_server}
    else
      :ok
    end
  end

  # The `connect` fixture: the connected browsers are closed after the test.
  setup %{browser_type: browser_type} do
    connect = fn ws_endpoint ->
      browser = BrowserType.connect!(browser_type, ws_endpoint)
      on_exit(fn -> Browser.close(browser) end)
      browser
    end

    %{connect: connect}
  end

  # The `twoPages` fixture, for tests tagged `:two_pages`.
  setup %{connect: connect} = tags do
    if tags[:two_pages] do
      remote_server = tags.remote_server

      browser_a = connect.(LaunchServer.ws_endpoint(remote_server))
      context_a = Browser.new_context!(browser_a)
      page_a = BrowserContext.new_page!(context_a)

      browser_b = connect.(LaunchServer.ws_endpoint(remote_server))
      context_b = hd(Browser.contexts(browser_b))
      page_b = hd(BrowserContext.pages(context_b))

      %{page_a: page_a, page_b: page_b}
    else
      :ok
    end
  end

  defp disconnect(page) do
    page |> Page.context() |> BrowserContext.browser() |> Browser.close!()
    # Give disconnect some time to cleanup.
    Process.sleep(1000)
  end

  test "should connect two clients", %{connect: connect, remote_server: remote_server, server: server} do
    browser_a = connect.(LaunchServer.ws_endpoint(remote_server))
    assert Browser.contexts(browser_a) == []
    context_a1 = Browser.new_context!(browser_a)
    page_a1 = BrowserContext.new_page!(context_a1)
    Page.goto!(page_a1, server.empty_page)

    browser_b = connect.(LaunchServer.ws_endpoint(remote_server))
    assert length(Browser.contexts(browser_b)) == 1
    context_b1 = hd(Browser.contexts(browser_b))
    assert length(BrowserContext.pages(context_b1)) == 1
    page_b1 = hd(BrowserContext.pages(context_b1))
    Expect.to_have_url!(page_b1, server.empty_page)

    context_b2 = Browser.new_context!(browser_b, base_url: server.prefix)
    assert Browser.contexts(browser_b) == [context_b1, context_b2]
    poll(fn -> length(Browser.contexts(browser_a)) end, &assert(&1 == 2))
    context_a2 = Enum.at(Browser.contexts(browser_a), 1)
    assert Browser.contexts(browser_a) == [context_a1, context_a2]

    test = self()
    BrowserContext.once(context_b2, :page, fn page -> send(test, {:page, page}) end)
    page_a2 = BrowserContext.new_page!(context_a2)
    assert_receive {:page, page_b2}
    Page.goto!(page_a2, "/frames/frame.html")
    Expect.to_have_url!(page_b2, "/frames/frame.html")

    # Both contexts and pages should be still operational after any client disconnects.
    disconnect(page_a1)

    Expect.to_have_url!(page_b1, server.empty_page)
    Expect.to_have_url!(page_b2, server.prefix <> "/frames/frame.html")
  end

  test "should fire context event on remote newContext", %{connect: connect, remote_server: remote_server} do
    browser_a = connect.(LaunchServer.ws_endpoint(remote_server))
    {:ok, events} = Agent.start_link(fn -> [] end)
    Browser.on(browser_a, :context, fn ctx -> Agent.update(events, &(&1 ++ [ctx])) end)

    browser_b = connect.(LaunchServer.ws_endpoint(remote_server))
    context_b = Browser.new_context!(browser_b)

    [event] = poll(fn -> Agent.get(events, & &1) end, &assert(length(&1) == 1))
    assert Browser.contexts(browser_a) == [event]
    assert event != context_b
  end

  @tag :two_pages
  test "should have separate default timeouts", %{page_a: page_a, page_b: page_b} do
    Page.set_default_timeout(page_a, 500)
    Page.set_default_timeout(page_b, 600)

    [{:error, error_a}, {:error, error_b}] =
      Task.await_many(
        [
          Task.async(fn -> Page.click(page_a, "div") end),
          Task.async(fn -> Page.click(page_b, "div") end)
        ],
        :infinity
      )

    assert Exception.message(error_a) =~ "Timeout 500ms exceeded"
    assert Exception.message(error_b) =~ "Timeout 600ms exceeded"
  end

  @tag :two_pages
  test "should receive viewport size changes", %{page_a: page_a, page_b: page_b} do
    Page.set_viewport_size!(page_a, %{width: 567, height: 456})
    assert Page.viewport_size(page_a) == %{width: 567, height: 456}
    poll(fn -> Page.viewport_size(page_b) end, &assert(&1 == %{width: 567, height: 456}))

    Page.set_viewport_size!(page_b, %{width: 456, height: 567})
    assert Page.viewport_size(page_b) == %{width: 456, height: 567}
    poll(fn -> Page.viewport_size(page_a) end, &assert(&1 == %{width: 456, height: 567}))
  end

  @tag :two_pages
  @tag skip: if(@browser_name != "chromium", do: "upstream skip: Chromium only")
  test "should not allow parallel js coverage and cleanup upon disconnect", %{page_a: page_a, page_b: page_b} do
    Coverage.start_js_coverage!(Page.coverage(page_a))
    {:error, error} = Coverage.start_js_coverage(Page.coverage(page_b))
    assert Exception.message(error) =~ "JSCoverage is already enabled"

    # Should cleanup coverage on disconnect and allow another client to start it.
    disconnect(page_a)
    Coverage.start_js_coverage!(Page.coverage(page_b))
  end

  @tag :two_pages
  @tag skip: if(@browser_name != "chromium", do: "upstream skip: Chromium only")
  test "should not allow parallel css coverage", %{page_a: page_a, page_b: page_b} do
    Coverage.start_css_coverage!(Page.coverage(page_a))
    {:error, error} = Coverage.start_css_coverage(Page.coverage(page_b))
    assert Exception.message(error) =~ "CSSCoverage is already enabled"

    # Should cleanup coverage on disconnect and allow another client to start it.
    disconnect(page_a)
    Coverage.start_css_coverage!(Page.coverage(page_b))
  end

  @tag :two_pages
  test "should unpause clock", %{page_a: page_a, page_b: page_b} do
    Clock.install!(Page.clock(page_a), time: 1000)
    Clock.pause_at!(Page.clock(page_a), 2000)
    promise = Task.async(fn -> Page.evaluate!(page_b, "() => new Promise(f => setTimeout(f, 1000))") end)
    disconnect(page_a)
    Task.await(promise, :infinity)
  end

  @tag :two_pages
  test "last emulateMedia wins", %{page_a: page_a, page_b: page_b} do
    Page.emulate_media!(page_a, media: :print)
    assert Page.evaluate!(page_b, "() => window.matchMedia('screen').matches") == false
    assert Page.evaluate!(page_a, "() => window.matchMedia('print').matches") == true
    Page.emulate_media!(page_b, media: :screen)
    assert Page.evaluate!(page_b, "() => window.matchMedia('screen').matches") == true
    assert Page.evaluate!(page_a, "() => window.matchMedia('print').matches") == false
  end

  @tag :two_pages
  test "should chain routes", %{page_a: page_a, page_b: page_b, server: server} do
    html = fn body ->
      fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", "text/html") |> Plug.Conn.send_resp(200, body)
      end
    end

    TestServer.set_route(server, "/foo", html.("<div>server-foo</div>"))
    TestServer.set_route(server, "/bar", html.("<div>server-bar</div>"))
    TestServer.set_route(server, "/qux", html.("<div>server-qux</div>"))

    test = self()
    {:ok, stall} = Agent.start_link(fn -> false end)

    Page.route!(page_a, "**/foo", fn route ->
      if Agent.get(stall, & &1),
        do: send(test, :stalled),
        else: Route.fallback!(route)
    end)

    Page.route!(page_a, "**/bar", fn route ->
      Route.fulfill!(route, body: "<div>intercepted-bar</div>", content_type: "text/html")
    end)

    Page.route!(page_b, "**/foo", fn route ->
      Route.fulfill!(route, body: "<div>intercepted2-foo</div>", content_type: "text/html")
    end)

    Page.route!(page_b, "**/bar", fn route ->
      Route.fulfill!(route, body: "<div>intercepted2-bar</div>", content_type: "text/html")
    end)

    Page.route!(page_b, "**/qux", fn route ->
      Route.fulfill!(route, body: "<div>intercepted2-qux</div>", content_type: "text/html")
    end)

    Page.goto!(page_a, server.prefix <> "/foo")
    Expect.to_have_text!(Page.locator(page_b, "div"), "intercepted2-foo")

    Page.goto!(page_a, server.prefix <> "/bar")
    Expect.to_have_text!(Page.locator(page_b, "div"), "intercepted-bar")

    Page.goto!(page_a, server.prefix <> "/qux")
    Expect.to_have_text!(Page.locator(page_b, "div"), "intercepted2-qux")

    Agent.update(stall, fn _ -> true end)
    goto = Task.async(fn -> Page.goto!(page_b, server.prefix <> "/foo") end)
    assert_receive :stalled
    page_a |> Page.context() |> BrowserContext.browser() |> Browser.close!()

    Task.await(goto, :infinity)
    Expect.to_have_text!(Page.locator(page_b, "div"), "intercepted2-foo")

    Page.goto!(page_b, server.prefix <> "/bar")
    Expect.to_have_text!(Page.locator(page_b, "div"), "intercepted2-bar")
  end

  @tag skip: "upstream fixme: test.fixme (no reason given)"
  test "should chain routes with changed url"

  @tag :two_pages
  test "should remove exposed bindings upon disconnect", %{page_a: page_a, page_b: page_b} do
    Page.expose_binding!(page_a, "pageBindingA", fn _source -> "pageBindingAResult" end)
    Page.evaluate!(page_a, "() => { window.pageBindingACopy = window.pageBindingA; }")
    assert Page.evaluate!(page_b, "() => window.pageBindingA()") == "pageBindingAResult"
    assert Page.evaluate!(page_b, "() => !!window.pageBindingACopy") == true

    BrowserContext.expose_binding!(Page.context(page_a), "contextBindingA", fn _source -> "contextBindingAResult" end)
    assert Page.evaluate!(page_b, "() => window.contextBindingA()") == "contextBindingAResult"

    Page.expose_binding!(page_b, "pageBindingB", fn _source -> "pageBindingBResult" end)
    assert Page.evaluate!(page_a, "() => window.pageBindingB()") == "pageBindingBResult"
    BrowserContext.expose_binding!(Page.context(page_b), "contextBindingB", fn _source -> "contextBindingBResult" end)
    assert Page.evaluate!(page_a, "() => window.contextBindingB()") == "contextBindingBResult"

    disconnect(page_a)

    assert Page.evaluate!(page_b, "() => window.pageBindingA") == nil
    assert Page.evaluate!(page_b, "() => window.contextBindingA") == nil
    {:error, error} = Page.evaluate(page_b, "() => window.pageBindingACopy()")
    assert Exception.message(error) =~ ~s(binding "pageBindingA" has been removed)

    assert Page.evaluate!(page_b, "() => window.pageBindingB()") == "pageBindingBResult"
  end

  @tag :two_pages
  test "should unroute websockets", %{page_a: page_a, page_b: page_b, server: server} do
    Page.goto!(page_a, server.empty_page)
    Page.route_web_socket!(page_a, ~r/.*/, fn _ -> nil end)
    Page.route_web_socket!(page_a, ~r/.*/, fn _ -> nil end)
    Page.route_web_socket!(page_a, ~r/.*/, fn _ -> nil end)

    {:error, error} = Page.route_web_socket(page_b, ~r/.*/, fn _ -> nil end)
    assert Exception.message(error) =~ "Another client is already routing WebSockets"

    disconnect(page_a)

    test = self()
    Page.route_web_socket!(page_b, ~r/.*/, fn ws -> send(test, {:resolved, ws}) end)
    Page.goto!(page_b, server.empty_page)
    Page.evaluate!(page_b, "host => window.ws = new WebSocket('ws://' + host + '/ws')", server.host)
    assert_receive {:resolved, _}
  end

  # Function scripts are JS source: `() => window.pageValueA = 'pageValueA'` is called.
  @tag :two_pages
  test "should remove init scripts upon disconnect", %{page_a: page_a, page_b: page_b, server: server} do
    Page.add_init_script!(page_a, "(() => window.pageValueA = 'pageValueA')()")
    BrowserContext.add_init_script!(Page.context(page_a), "(() => window.contextValueA = 'contextValueA')()")
    Page.goto!(page_b, server.empty_page)
    assert Page.evaluate!(page_b, "() => window.pageValueA") == "pageValueA"
    assert Page.evaluate!(page_b, "() => window.contextValueA") == "contextValueA"

    Page.add_init_script!(page_b, "(() => window.pageValueB = 'pageValueB')()")
    BrowserContext.add_init_script!(Page.context(page_b), "(() => window.contextValueB = 'contextValueB')()")
    Page.goto!(page_a, server.empty_page)
    assert Page.evaluate!(page_a, "() => window.pageValueB") == "pageValueB"
    assert Page.evaluate!(page_a, "() => window.contextValueB") == "contextValueB"

    disconnect(page_b)

    Page.goto!(page_a, server.empty_page)
    assert Page.evaluate!(page_a, "() => window.pageValueB") == nil
    assert Page.evaluate!(page_a, "() => window.contextValueB") == nil
    assert Page.evaluate!(page_a, "() => window.pageValueA") == "pageValueA"
    assert Page.evaluate!(page_a, "() => window.contextValueA") == "contextValueA"
  end

  @tag :two_pages
  test "should remove locator handlers upon disconnect", %{page_a: page_a, page_b: page_b, server: server} do
    Page.goto!(page_a, server.prefix <> "/input/handle-locator.html")

    test = self()

    Page.add_locator_handler!(page_a, Page.get_by_text(page_a, "This interstitial covers the button"), fn _ ->
      send(test, :called)
      Locator.click!(Page.locator(page_a, "#close"))
    end)

    Locator.hover!(Page.locator(page_a, "#aside"))

    Page.evaluate!(page_a, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('mouseover', 1);
    }
    """)

    Locator.click!(Page.locator(page_a, "#target"))
    # expect(count).toBe(1)
    assert_received :called
    refute_received :called
    assert Page.evaluate!(page_b, "window.clicked") == 1
    Expect.not_to_be_visible!(Page.locator(page_b, "#interstitial"))

    Locator.hover!(Page.locator(page_a, "#aside"))

    Page.evaluate!(page_a, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('mouseover', 1);
    }
    """)

    disconnect(page_a)

    {:error, error} = Locator.click(Page.locator(page_b, "#target"), timeout: 3000)
    assert Exception.message(error) =~ "Timeout 3000ms exceeded"
    assert Exception.message(error) =~ "intercepts pointer events"
    refute Exception.message(error) =~ "locator handler"
  end

  @tag remote_server: false
  test "should launch persistent", %{browser_type: browser_type, launch_server: launch_server} do
    {:ok, browser_server} = launch_server.(%{_userDataDir: "", _sharedBrowser: true})
    browser = BrowserType.connect!(browser_type, LaunchServer.ws_endpoint(browser_server))
    assert length(Browser.contexts(browser)) == 1
    Browser.close!(browser)
    LaunchServer.close(browser_server)
  end

  @tag :two_pages
  test "should avoid side effects upon disconnect", %{page_a: page_a, page_b: page_b} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Page.on(page_b, :console, fn _ -> Agent.update(counter, &(&1 + 1)) end)

    promise =
      Task.async(fn ->
        Page.wait_for_function(
          page_a,
          """
          () => {
            window['counter'] = (window['counter'] || 0) + 1;
            console.log(window['counter']);
          }
          """,
          %{},
          polling: 1,
          timeout: 10_000
        )
      end)

    disconnect(page_a)
    {:error, error} = Task.await(promise, :infinity)
    saved_counter = Agent.get(counter, & &1)

    # Give it some time to produce more logs.
    Page.wait_for_timeout(page_b, 2000)

    assert Exception.message(error) =~ @k_target_closed_error_message
    assert Agent.get(counter, & &1) == saved_counter
  end

  # test.skip(trace === 'on' / video === 'on')  -- never on
  @tag :two_pages
  test "screencast should deliver cached last frame to a new client", %{page_a: page_a, page_b: page_b, server: server} do
    Page.goto!(page_a, server.empty_page)
    Page.evaluate!(page_a, "() => document.body.style.backgroundColor = 'red'")

    {:ok, frames_a} = Agent.start_link(fn -> [] end)

    Screencast.start!(Page.screencast(page_a),
      on_frame: fn %{data: data} -> Agent.update(frames_a, &(&1 ++ [data])) end,
      size: %{width: 320, height: 240}
    )

    ensure_some_frames(page_a)
    assert Agent.get(frames_a, & &1) != []
    last_frame_a = List.last(Agent.get(frames_a, & &1))

    {:ok, frames_b} = Agent.start_link(fn -> [] end)

    Screencast.start!(Page.screencast(page_b),
      on_frame: fn %{data: data} -> Agent.update(frames_b, &(&1 ++ [data])) end
    )

    # Second client should receive the cached last frame without waiting for a browser repaint.
    [first_b | _] = poll(fn -> Agent.get(frames_b, & &1) end, &assert(&1 != []))
    assert first_b == last_frame_a

    Screencast.stop!(Page.screencast(page_a))
    Screencast.stop!(Page.screencast(page_b))
  end

  # test.skip(trace === 'on')  -- never on
  @tag :two_pages
  test "should stop tracing upon disconnect", %{page_a: page_a, page_b: page_b} do
    Tracing.start!(BrowserContext.tracing(Page.context(page_a)))
    {:error, error} = Tracing.start(BrowserContext.tracing(Page.context(page_b)))
    assert Exception.message(error) =~ "Tracing has been already started"

    disconnect(page_a)

    Tracing.start!(BrowserContext.tracing(Page.context(page_b)))
  end
end
