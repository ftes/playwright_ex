defmodule PlaywrightEx.Library.BrowsercontextPageEventTest do
  @upstream "tests/library/browsercontext-page-event.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  test "should have url", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    other_page =
      BrowserContext.expect_event!(context, :page, fn ->
        Page.evaluate!(page, "url => window.open(url)", server.empty_page)
      end)

    assert Page.url(other_page) == server.empty_page
    BrowserContext.close!(context)
  end

  test "should have url after domcontentloaded", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    other_page =
      BrowserContext.expect_event!(context, :page, fn ->
        Page.evaluate!(page, "url => window.open(url)", server.empty_page)
      end)

    Page.wait_for_load_state!(other_page, :domcontentloaded)
    assert Page.url(other_page) == server.empty_page
    BrowserContext.close!(context)
  end

  test "should have about:blank url with domcontentloaded", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    other_page =
      BrowserContext.expect_event!(context, :page, fn ->
        Page.evaluate!(page, "url => window.open(url)", "about:blank")
      end)

    Page.wait_for_load_state!(other_page, :domcontentloaded)
    assert Page.url(other_page) == "about:blank"
    BrowserContext.close!(context)
  end

  test "should have about:blank for empty url with domcontentloaded", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    other_page =
      BrowserContext.expect_event!(context, :page, fn ->
        Page.evaluate!(page, "() => window.open()")
      end)

    Page.wait_for_load_state!(other_page, :domcontentloaded)
    assert Page.url(other_page) == "about:blank"
    BrowserContext.close!(context)
  end

  test "should report when a new page is created and closed", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    other_page =
      BrowserContext.expect_event!(context, :page, fn ->
        Page.evaluate!(page, "url => window.open(url)", server.cross_process_prefix <> "/empty.html")
      end)

    # The url is about:blank in FF when 'page' event is fired.
    assert Page.url(other_page) =~ server.cross_process_prefix
    assert Page.evaluate!(other_page, "() => ['Hello', 'world'].join(' ')") == "Hello world"
    assert Page.query_selector!(other_page, "body")

    all_pages = BrowserContext.pages(context)
    assert page in all_pages
    assert other_page in all_pages

    test_pid = self()
    Page.once(other_page, :close, fn _ -> send(test_pid, :close_event_received) end)
    Page.close!(other_page)
    assert_received :close_event_received

    all_pages = BrowserContext.pages(context)
    assert page in all_pages
    refute other_page in all_pages
    BrowserContext.close!(context)
  end

  test "should report initialized pages", %{browser: browser} do
    context = Browser.new_context!(browser)
    page_promise = BrowserContext.wait_for_event(context, :page)
    # void context.newPage()
    new_page_task = Runtime.Promise.async(fn -> BrowserContext.new_page(context) end)
    new_page = Promise.await!(page_promise)
    assert Page.url(new_page) == "about:blank"

    popup_promise = BrowserContext.wait_for_event(context, :page)
    evaluate_task = Runtime.Promise.async(fn -> Page.evaluate!(new_page, "() => window.open('about:blank')") end)
    popup = Promise.await!(popup_promise)
    assert Page.url(popup) == "about:blank"
    Runtime.Promise.await(evaluate_task)
    Runtime.Promise.await(new_page_task)
    BrowserContext.close!(context)
  end

  test "should not crash while redirecting of original request was missed", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    test_pid = self()

    # `server.setRoute(path, (req, res) => serverResponse = res)`: the request process hands
    # itself to the test, which issues the redirect later.
    TestServer.set_route(server, "/one-style.css", fn conn ->
      send(test_pid, {:server_response, self()})

      receive do
        {:redirect, location} ->
          conn
          |> Plug.Conn.put_resp_header("location", location)
          |> Plug.Conn.send_resp(302, "")
      after
        30_000 -> conn
      end
    end)

    # Open a new page. Use window.open to connect to the page later.
    page_promise = BrowserContext.wait_for_event(context, :page)
    request = TestServer.wait_for_request(server, "/one-style.css")
    Page.evaluate!(page, "url => window.open(url)", server.prefix <> "/one-style.html")
    new_page = Promise.await!(page_promise)
    Task.await(request, :infinity)
    assert_receive {:server_response, server_response}, 5000
    # Issue a redirect.
    send(server_response, {:redirect, "/injectedstyle.css"})
    Page.wait_for_load_state!(new_page, :domcontentloaded)
    assert Page.url(new_page) == server.prefix <> "/one-style.html"
    # Cleanup.
    BrowserContext.close!(context)
  end

  test "should have an opener", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup =
      BrowserContext.expect_event!(context, :page, fn ->
        Page.goto!(page, server.prefix <> "/popup/window-open.html")
      end)

    assert Page.url(popup) == server.prefix <> "/popup/popup.html"
    assert Page.opener!(popup) == page
    assert Page.opener!(page) == nil
    BrowserContext.close!(context)
  end

  test "should fire page lifecycle events", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    {:ok, events} = Agent.start_link(fn -> [] end)

    BrowserContext.on(context, :page, fn page ->
      Agent.update(events, &(&1 ++ ["CREATED: " <> Page.url(page)]))
      Page.on(page, :close, fn _ -> Agent.update(events, &(&1 ++ ["DESTROYED: " <> Page.url(page)])) end)
    end)

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.close!(page)

    assert Agent.get(events, & &1) == [
             "CREATED: about:blank",
             "DESTROYED: #{server.empty_page}"
           ]

    BrowserContext.close!(context)
  end

  test "should work with Shift-clicking", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a href="/one-style.html">yo</a>))

    popup =
      BrowserContext.expect_event!(context, :page, fn ->
        Page.click!(page, "a", modifiers: [:shift])
      end)

    assert Page.opener!(popup) == nil
    BrowserContext.close!(context)
  end

  test "should work with Ctrl-clicking", %{browser: browser, server: server, browser_name: browser_name} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a href="/one-style.html">yo</a>))

    popup =
      BrowserContext.expect_event!(context, :page, fn ->
        Page.click!(page, "a", modifiers: [:control_or_meta])
      end)

    assert Page.opener!(popup) == if(browser_name == "firefox", do: page, else: nil)
    BrowserContext.close!(context)
  end
end
