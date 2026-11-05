defmodule PlaywrightEx.Library.Chromium.SessionTest do
  @upstream "tests/library/chromium/session.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.CDPSession
  alias PlaywrightEx.Coverage
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  @moduletag skip: if(System.get_env("BROWSER", "chromium") != "chromium", do: "upstream skip: Chromium only")

  # tests/config/errors.ts
  @k_target_closed_error_message "Target page, context or browser has been closed"

  @tag :page
  test "should work", %{page: page} do
    client = BrowserContext.new_cdp_session!(Page.context(page), page)

    Task.await_many([
      Task.async(fn -> CDPSession.send!(client, "Runtime.enable") end),
      Task.async(fn -> CDPSession.send!(client, "Runtime.evaluate", %{expression: ~s[window.foo = "bar"]}) end)
    ])

    foo = Page.evaluate!(page, "() => window['foo']")
    assert foo == "bar"
  end

  @tag :page
  test "should send events", %{page: page, server: server} do
    client = BrowserContext.new_cdp_session!(Page.context(page), page)
    CDPSession.send!(client, "Network.enable")
    test_pid = self()
    CDPSession.on(client, "Network.requestWillBeSent", fn event -> send(test_pid, {:event, event}) end)
    Page.goto!(page, server.empty_page)
    assert_received {:event, _}
    refute_received {:event, _}
  end

  @tag :page
  test "should only accept a page or frame", %{page: page} do
    {:error, error} = BrowserContext.new_cdp_session(Page.context(page), Page.context(page))
    assert Exception.message(error) =~ "page: expected Page or Frame"

    # non-channelable types hit validation at a different layer
    {:error, error_alt} = BrowserContext.new_cdp_session(Page.context(page), %{})
    assert Exception.message(error_alt) =~ "page: expected Page or Frame"
  end

  @tag :page
  test "should enable and disable domains independently", %{page: page} do
    client = BrowserContext.new_cdp_session!(Page.context(page), page)
    CDPSession.send!(client, "Runtime.enable")
    CDPSession.send!(client, "Debugger.enable")
    # JS coverage enables and then disables Debugger domain.
    Coverage.start_js_coverage!(Page.coverage(page))
    Coverage.stop_js_coverage!(Page.coverage(page))
    # generate a script in page and wait for the event.
    test_pid = self()

    CDPSession.on(client, "Debugger.scriptParsed", fn event ->
      if event["url"] == "foo.js", do: send(test_pid, :script_parsed)
    end)

    Page.evaluate!(page, "//# sourceURL=foo.js")
    assert_receive :script_parsed
  end

  @tag :page
  test "should be able to detach session", %{page: page} do
    client = BrowserContext.new_cdp_session!(Page.context(page), page)
    CDPSession.send!(client, "Runtime.enable")
    eval_response = CDPSession.send!(client, "Runtime.evaluate", %{expression: "1 + 2", returnByValue: true})
    assert eval_response["result"]["value"] == 3
    CDPSession.detach!(client)
    {:error, error} = CDPSession.send(client, "Runtime.evaluate", %{expression: "3 + 1", returnByValue: true})
    assert Exception.message(error) =~ "Target page, context or browser has been closed"
  end

  @tag :page
  test "should throw nice errors", %{page: page} do
    client = BrowserContext.new_cdp_session!(Page.context(page), page)
    {:error, error} = the_source_of_the_problems(client)

    # expect(error.stack).toContain('theSourceOfTheProblems');  -- not ported: error stack rewriting (error.stack is the server's)
    assert Exception.message(error) =~ "ThisCommand.DoesNotExist"
  end

  defp the_source_of_the_problems(client) do
    CDPSession.send(client, "ThisCommand.DoesNotExist")
  end

  @tag :page
  test "should work with main frame", %{page: page} do
    client = BrowserContext.new_cdp_session!(Page.context(page), Page.main_frame(page))

    Task.await_many([
      Task.async(fn -> CDPSession.send!(client, "Runtime.enable") end),
      Task.async(fn -> CDPSession.send!(client, "Runtime.evaluate", %{expression: ~s[window.foo = "bar"]}) end)
    ])

    foo = Page.evaluate!(page, "() => window['foo']")
    assert foo == "bar"
  end

  @tag :page
  test "should throw if target is part of main", %{server: server, page: page} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    assert Frame.url(Enum.at(Page.frames(page), 0)) =~ "/frames/one-frame.html"
    assert Frame.url(Enum.at(Page.frames(page), 1)) =~ "/frames/frame.html"

    {:error, error} = BrowserContext.new_cdp_session(Page.context(page), Enum.at(Page.frames(page), 1))

    assert Exception.message(error) =~
             "This frame does not have a separate CDP session, it is a part of the parent frame's session"
  end

  test "should not break page.close()", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    session = BrowserContext.new_cdp_session!(Page.context(page), page)
    CDPSession.detach!(session)
    Page.close!(page)
    BrowserContext.close!(context)
  end

  test "should detach when page closes", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    session = BrowserContext.new_cdp_session!(context, page)
    Page.close!(page)
    {:error, error} = CDPSession.detach(session)
    assert error
    BrowserContext.close!(context)
  end

  test "should reject protocol calls when page closes", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    session = BrowserContext.new_cdp_session!(context, page)

    promise =
      Task.async(fn ->
        CDPSession.send(session, "Runtime.evaluate", %{expression: "new Promise(() => {})", awaitPromise: true})
      end)

    # Let the call reach the driver before the page closes (JS sends it synchronously).
    Process.sleep(100)
    Page.close!(page)
    {:error, error1} = Task.await(promise)
    assert Exception.message(error1) =~ @k_target_closed_error_message

    {:error, error2} =
      CDPSession.send(session, "Runtime.evaluate", %{expression: "new Promise(() => {})", awaitPromise: true})

    assert Exception.message(error2) =~ "Target page, context or browser has been closed"
    BrowserContext.close!(context)
  end

  @tag :page
  test "should emit event for each CDP event", %{page: page, server: server} do
    client = BrowserContext.new_cdp_session!(Page.context(page), page)
    CDPSession.send!(client, "Network.enable")
    test_pid = self()
    CDPSession.on(client, :event, fn event -> send(test_pid, {:event, event}) end)
    Page.goto!(page, server.empty_page)
    events = received_events()
    assert events != []
    request_event = Enum.find(events, &(&1.method == "Network.requestWillBeSent"))
    assert request_event
    assert request_event.params["request"]["url"] == server.empty_page
  end

  defp received_events do
    receive do
      {:event, event} -> [event | received_events()]
    after
      0 -> []
    end
  end

  @tag :page
  test "should emit close event when session is detached", %{page: page} do
    client = BrowserContext.new_cdp_session!(Page.context(page), page)
    test_pid = self()
    CDPSession.on(client, :close, fn session -> send(test_pid, {:closed, session}) end)
    CDPSession.detach!(client)
    assert_received {:closed, closed_session}
    assert closed_session == client
  end

  test "should emit close event when page closes", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    session = BrowserContext.new_cdp_session!(context, page)
    test_pid = self()
    CDPSession.on(session, :close, fn session -> send(test_pid, {:closed, session}) end)
    Page.close!(page)
    assert_receive {:closed, closed_session}
    assert closed_session == session
    BrowserContext.close!(context)
  end

  test "should work with newBrowserCDPSession", %{browser: browser} do
    session = Browser.new_browser_cdp_session!(browser)

    version = CDPSession.send!(session, "Browser.getVersion")
    assert version["userAgent"]

    test_pid = self()
    CDPSession.on(session, "Target.targetCreated", fn _ -> send(test_pid, :got_event) end)
    CDPSession.send!(session, "Target.setDiscoverTargets", %{discover: true})
    page = Browser.new_page!(browser)
    assert_received :got_event
    Page.close!(page)

    CDPSession.detach!(session)
  end
end
