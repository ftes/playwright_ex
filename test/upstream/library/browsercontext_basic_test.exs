defmodule PlaywrightEx.Library.BrowsercontextBasicTest do
  @upstream "tests/library/browsercontext-basic.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Page
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer

  # tests/config/utils.ts verifyViewport
  defp verify_viewport(page, width, height) do
    assert Page.viewport_size(page).width == width
    assert Page.viewport_size(page).height == height
    assert Page.evaluate!(page, "window.innerWidth") == width
    assert Page.evaluate!(page, "window.innerHeight") == height
  end

  test "should create new context @smoke", %{browser: browser} do
    assert Browser.contexts(browser) == []
    context = Browser.new_context!(browser)
    assert Browser.contexts(browser) == [context]
    assert browser == BrowserContext.browser(context)
    context2 = Browser.new_context!(browser)
    assert Browser.contexts(browser) == [context, context2]
    BrowserContext.close!(context)
    assert Browser.contexts(browser) == [context2]
    assert browser == BrowserContext.browser(context)
    BrowserContext.close!(context2)
  end

  @tag skip: "not ported: Locator"
  test "should be able to click across browser contexts"

  @tag skip: "not ported: Locator"
  test "should be able to hover across browser contexts in parallel"

  @tag skip: "not ported: waitForEvent"
  test "window.open should use parent tab context"

  test "should isolate localStorage and cookies @smoke", %{browser: browser, server: server} do
    # Create two incognito contexts.
    context1 = Browser.new_context!(browser)
    context2 = Browser.new_context!(browser)
    assert BrowserContext.pages(context1) == []
    assert BrowserContext.pages(context2) == []

    # Create a page in first incognito context.
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.empty_page)

    Page.evaluate!(page1, """
    () => {
      localStorage.setItem('name', 'page1');
      document.cookie = 'name=page1';
    }
    """)

    assert length(BrowserContext.pages(context1)) == 1
    assert BrowserContext.pages(context2) == []

    # Create a page in second incognito context.
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)

    Page.evaluate!(page2, """
    () => {
      localStorage.setItem('name', 'page2');
      document.cookie = 'name=page2';
    }
    """)

    assert length(BrowserContext.pages(context1)) == 1
    assert length(BrowserContext.pages(context2)) == 1
    assert hd(BrowserContext.pages(context1)) == page1
    assert hd(BrowserContext.pages(context2)) == page2

    # Make sure pages don't share localstorage or cookies.
    assert Page.evaluate!(page1, "() => localStorage.getItem('name')") == "page1"
    assert Page.evaluate!(page1, "() => document.cookie") == "name=page1"
    assert Page.evaluate!(page2, "() => localStorage.getItem('name')") == "page2"
    assert Page.evaluate!(page2, "() => document.cookie") == "name=page2"

    # Cleanup contexts.
    Task.await_many([
      Task.async(fn -> BrowserContext.close!(context1) end),
      Task.async(fn -> BrowserContext.close!(context2) end)
    ])

    assert Browser.contexts(browser) == []
  end

  test "should propagate default viewport to the page", %{browser: browser} do
    context = Browser.new_context!(browser, viewport: %{width: 456, height: 789})
    page = BrowserContext.new_page!(context)
    verify_viewport(page, 456, 789)
    BrowserContext.close!(context)
  end

  # Elixir maps are immutable: `viewport.width = 567` rebinds a copy.
  test "should make a copy of default viewport", %{browser: browser} do
    viewport = %{width: 456, height: 789}
    context = Browser.new_context!(browser, viewport: viewport)
    _viewport = %{viewport | width: 567}
    page = BrowserContext.new_page!(context)
    verify_viewport(page, 456, 789)
    BrowserContext.close!(context)
  end

  test "should respect deviceScaleFactor", %{browser: browser} do
    context = Browser.new_context!(browser, device_scale_factor: 3)
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "window.devicePixelRatio") == 3
    BrowserContext.close!(context)
  end

  test "should not allow deviceScaleFactor with null viewport", %{browser: browser} do
    {:error, error} = Browser.new_context(browser, viewport: :null, device_scale_factor: 1)
    assert Exception.message(error) =~ ~s("deviceScaleFactor" option is not supported with null "viewport")
  end

  test "should not allow isMobile with null viewport", %{browser: browser} do
    {:error, error} = Browser.new_context(browser, viewport: :null, is_mobile: true)
    assert Exception.message(error) =~ ~s("isMobile" option is not supported with null "viewport")
  end

  test "close() should work for empty context", %{browser: browser} do
    context = Browser.new_context!(browser)
    BrowserContext.close!(context)
  end

  @tag skip: "not ported: waitForEvent"
  test "close() should abort waitForEvent"

  test "close() should be callable twice", %{browser: browser} do
    context = Browser.new_context!(browser)
    BrowserContext.close!(context)
    BrowserContext.close!(context)
  end

  @tag skip: "not ported: waitForEvent"
  test "should pass self to close event"

  @tag skip: "not ported: Locator"
  test "should not report frameless pages on error"

  test "should return all of the pages", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    second = BrowserContext.new_page!(context)
    all_pages = BrowserContext.pages(context)
    assert length(all_pages) == 2
    assert page in all_pages
    assert second in all_pages
    BrowserContext.close!(context)
  end

  test "should close all belonging pages once closing context", %{browser: browser} do
    context = Browser.new_context!(browser)
    BrowserContext.new_page!(context)
    assert length(BrowserContext.pages(context)) == 1

    BrowserContext.close!(context)
    assert BrowserContext.pages(context) == []
  end

  test "should disable javascript", %{browser: browser, browser_name: browser_name} do
    context = Browser.new_context!(browser, java_script_enabled: false)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, ~s(data:text/html, <script>var something = "forbidden"</script>))
    {:error, error} = Page.evaluate(page, "something")

    if browser_name == "webkit",
      do: assert(Exception.message(error) =~ "Can't find variable: something"),
      else: assert(Exception.message(error) =~ "something is not defined")

    BrowserContext.close!(context)

    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, ~s(data:text/html, <script>var something = "forbidden"</script>))
    assert Page.evaluate!(page, "something") == "forbidden"
    BrowserContext.close!(context)
  end

  test "should be able to navigate after disabling javascript", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, java_script_enabled: false)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    BrowserContext.close!(context)
  end

  test "should not hang on promises after disabling javascript", %{context_factory: context_factory} do
    context = context_factory.(java_script_enabled: false)
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "() => 1") == 1
    assert Page.evaluate!(page, "async () => 2") == 2
  end

  @tag skip: "not ported: Locator, expect"
  test "setContent should work after disabling javascript"

  @tag skip: "not ported: Locator, expect"
  test "should retry click after disabling javascript"

  test "should work with offline option", %{browser: browser, server: server, browser_name: browser_name} do
    context = Browser.new_context!(browser, offline: true)
    page = BrowserContext.new_page!(context)

    if browser_name == "firefox" do
      # Firefox navigates to an error page, and this navigation might conflict with the
      # next navigation we do in test.
      # So we need to wait for the navigation explicitly.
      test = self()
      Page.once(page, :frame_navigated, fn _ -> send(test, :navigated) end)
      assert {:error, _} = Page.goto(page, server.empty_page)
      assert_receive :navigated
    else
      assert {:error, _} = Page.goto(page, server.empty_page)
    end

    BrowserContext.set_offline!(context, false)
    response = Page.goto!(page, server.empty_page)
    assert Response.status(response) == 200
    BrowserContext.close!(context)
  end

  test "fetch with keepalive should throw when offline", %{context_factory: context_factory, server: server} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    url = server.prefix <> "/fetch"

    TestServer.set_route(server, "/fetch", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!("hello"))
    end)

    ok_response =
      Page.evaluate!(
        page,
        "url => fetch(url, { cache: 'no-store', keepalive: true }).then(response => response.json())",
        url
      )

    assert ok_response == "hello"

    BrowserContext.set_offline!(context, true)

    offline_response =
      Page.evaluate!(
        page,
        """
        async url => {
          try {
            const response = await fetch(url, { cache: 'no-store', keepalive: true });
            return await response.json();
          } catch {
            return 'error';
          }
        }
        """,
        url
      )

    assert offline_response == "error"
  end

  test "should emulate navigator.onLine", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "() => window.navigator.onLine") == true
    BrowserContext.set_offline!(context, true)
    assert Page.evaluate!(page, "() => window.navigator.onLine") == false
    BrowserContext.set_offline!(context, false)
    assert Page.evaluate!(page, "() => window.navigator.onLine") == true
    BrowserContext.close!(context)
  end

  @tag skip: "not ported: route"
  test "should emulate navigator.onLine across navigations"

  @tag skip: "not ported: evaluateHandle, expect.poll"
  test "should emulate offline event"

  @tag skip: "not ported: waitForEvent"
  test "should emulate media in popup"

  @tag skip: "not ported: evaluateHandle (attachFrame)"
  test "should emulate media in cross-process iframe"

  # `(browser as any)._channel.defaultUserAgentForTest()`: the client's channel call.
  @tag :page
  test "default user agent", %{browser: browser, page: page} do
    %{userAgent: user_agent} =
      PlaywrightEx.Runtime.Api.call(nil, browser, fn ->
        ChannelOwner.channel_call(browser, :defaultUserAgentForTest, %{})
      end)

    assert Page.evaluate!(page, "() => navigator.userAgent") == user_agent
  end

  test "should create two pages in parallel in various contexts", %{browser: browser} do
    context1 = Browser.new_context!(browser)
    context2 = Browser.new_context!(browser)

    Task.await_many([
      Task.async(fn -> BrowserContext.new_page!(context1) end),
      Task.async(fn -> BrowserContext.new_page!(context1) end),
      Task.async(fn -> BrowserContext.new_page!(context2) end),
      Task.async(fn -> BrowserContext.new_page!(context2) end)
    ])

    BrowserContext.close!(context1)
    BrowserContext.close!(context2)
    context3 = Browser.new_context!(browser)

    Task.await_many([
      Task.async(fn -> BrowserContext.new_page!(context3) end),
      Task.async(fn -> BrowserContext.new_page!(context3) end)
    ])

    BrowserContext.close!(context3)
  end
end
