defmodule PlaywrightEx.Library.BrowsercontextBasicTest do
  @upstream "tests/library/browsercontext-basic.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  import PlaywrightEx.Utils, only: [verify_viewport: 3]

  # expect.poll(fun).toEqual(expected)
  defp poll(fun, expected, tries \\ 100) do
    cond do
      fun.() == expected -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(fun, expected, tries - 1)
    end
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

  test "should be able to click across browser contexts", %{browser: browser} do
    assert Browser.contexts(browser) == []

    create_page = fn ->
      page = Browser.new_page!(browser)
      Page.set_content!(page, "<button>Click me</button>")

      Locator.evaluate!(Page.locator(page, "button"), """
      button => {
        window['clicks'] = 0;
        button.addEventListener('click', () => ++window['clicks'], false);
      }
      """)

      page
    end

    click_in_page = fn page, count ->
      for _ <- 1..count//1, do: Locator.click!(Page.locator(page, "button"))
    end

    get_clicks = fn page -> Page.evaluate!(page, "() => window['clicks']") end

    page1 = create_page.()
    page2 = create_page.()

    click_count = 20

    Task.await_many(
      [
        Task.async(fn -> click_in_page.(page1, click_count) end),
        Task.async(fn -> click_in_page.(page2, click_count) end)
      ],
      30_000
    )

    assert get_clicks.(page1) == click_count
    assert get_clicks.(page2) == click_count

    Page.close!(page1)
    Page.close!(page2)
  end

  test "should be able to hover across browser contexts in parallel", %{browser: browser} do
    # it.fixme(browserName === 'firefox' && !headless, 'Hover is flaky in headed Firefox');
    html = """
    <style>
      [role="tooltip"] { display: none; }
      [role="tooltip"].visible { display: block; }
    </style>
    <button>Hover me</button>
    <div role="tooltip">Tooltip content</div>
    <script>
      const button = document.querySelector('button');
      const tooltip = document.querySelector('[role="tooltip"]');
      button.addEventListener('pointerenter', () => tooltip.classList.add('visible'));
      button.addEventListener('pointerleave', () => tooltip.classList.remove('visible'));
    </script>
    """

    # Promise.all has no timeout of its own: the test's.
    pages =
      [1, 2, 3, 4, 5]
      |> Enum.map(fn _ ->
        Task.async(fn ->
          context = Browser.new_context!(browser)
          page = BrowserContext.new_page!(context)
          Page.set_content!(page, html)
          page
        end)
      end)
      |> Task.await_many(:infinity)

    # expect.soft(..., `Tooltip for page ${index + 1} should be visible`): a plain assertion (no soft asserts).
    pages
    |> Enum.map(fn page ->
      Task.async(fn ->
        page |> Page.get_by_role("button", name: "Hover me") |> Locator.hover!()
        Expect.to_be_visible!(Page.get_by_role(page, "tooltip"))
      end)
    end)
    |> Task.await_many(:infinity)

    pages
    |> Enum.map(&Task.async(fn -> BrowserContext.close!(Page.context(&1)) end))
    |> Task.await_many(:infinity)
  end

  test "window.open should use parent tab context", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "url => window.open(url)", server.empty_page) end)
    assert Page.context(popup) == context
    BrowserContext.close!(context)
  end

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
    Task.await_many(
      [
        Task.async(fn -> BrowserContext.close!(context1) end),
        Task.async(fn -> BrowserContext.close!(context2) end)
      ],
      :infinity
    )

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

  test "close() should abort waitForEvent", %{browser: browser} do
    context = Browser.new_context!(browser)
    promise = BrowserContext.wait_for_event(context, :page)
    BrowserContext.close!(context)
    {:error, error} = PlaywrightEx.Promise.await(promise)
    assert Exception.message(error) =~ "Target page, context or browser has been closed"
  end

  test "close() should be callable twice", %{browser: browser} do
    context = Browser.new_context!(browser)
    BrowserContext.close!(context)
    BrowserContext.close!(context)
  end

  test "should pass self to close event", %{browser: browser} do
    new_context = Browser.new_context!(browser)
    closed_context = BrowserContext.expect_event!(new_context, :close, fn -> BrowserContext.close!(new_context) end)
    assert closed_context == new_context
  end

  test "should not report frameless pages on error", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    TestServer.set_route(server, "/empty.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s(<a href="#{server.empty_page}" target="_blank">Click me</a>))
    end)

    test = self()
    BrowserContext.on(context, :page, fn p -> send(test, {:popup, p}) end)
    Page.goto!(page, server.empty_page)
    Page.click!(page, ~s("Click me"))
    BrowserContext.close!(context)

    popup =
      receive do
        {:popup, p} -> p
      after
        0 -> nil
      end

    if popup do
      # This races on Firefox :/
      assert Page.is_closed(popup)
      assert Page.main_frame(popup)
    end
  end

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

  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: firefox (non-BiDi)")
  test "should not hang on promises after disabling javascript", %{context_factory: context_factory} do
    context = context_factory.(java_script_enabled: false)
    page = BrowserContext.new_page!(context)
    assert Page.evaluate!(page, "() => 1") == 1
    assert Page.evaluate!(page, "async () => 2") == 2
  end

  test "setContent should work after disabling javascript", %{context_factory: context_factory} do
    context = context_factory.(java_script_enabled: false)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<h1>Hello</h1>")
    Expect.to_have_text!(Page.locator(page, "h1"), "Hello")
  end

  test "should retry click after disabling javascript", %{context_factory: context_factory} do
    context = context_factory.(java_script_enabled: false)
    page = BrowserContext.new_page!(context)

    Page.set_content!(page, """
      <details><summary>Continue</summary>Details</details>
      <div id="cover" style="position: fixed; inset: 0;"></div>
    """)

    click_promise = Task.async(fn -> Locator.click!(Page.locator(page, "summary")) end)
    # Give it enough time to go through a few retries while the button is covered.
    Page.wait_for_timeout!(page, 2000)
    clicked = Task.yield(click_promise, 0) != nil
    assert clicked == false
    Locator.evaluate!(Page.locator(page, "#cover"), "e => e.remove()")
    Task.await(click_promise, :infinity)
    Expect.to_have_attribute!(Page.locator(page, "details"), "open", "")
  end

  test "should work with offline option", %{browser: browser, server: server, browser_name: browser_name} do
    context = Browser.new_context!(browser, offline: true)
    page = BrowserContext.new_page!(context)

    if browser_name == "firefox" do
      # Firefox navigates to an error page, and this navigation might conflict with the
      # next navigation we do in test.
      # So we need to wait for the navigation explicitly.
      navigated = Page.wait_for_event(page, :frame_navigated)
      assert {:error, _} = Page.goto(page, server.empty_page)
      Promise.await!(navigated)
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

  test "should emulate navigator.onLine across navigations", %{
    browser: browser,
    server: server,
    browser_name: browser_name
  } do
    browser_major_version = browser |> Browser.version() |> String.split(".") |> hd() |> String.to_integer()

    # it.skip(browserName === 'chromium' && browserMajorVersion < 155, 'does not survive cross-process navgiation');
    if !(browser_name == "chromium" and browser_major_version < 155) do
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      assert Page.evaluate!(page, "() => window.navigator.onLine") == true
      BrowserContext.set_offline!(context, true)
      assert Page.evaluate!(page, "() => window.navigator.onLine") == false

      Page.goto!(page, "about:blank")
      assert Page.evaluate!(page, "() => window.navigator.onLine") == false
      Page.goto!(page, "data:text/html,<title>offline</title>")
      assert Page.evaluate!(page, "() => window.navigator.onLine") == false

      if browser_name == "chromium" do
        # Try a cross-process navigation in Chromium, which allows routing while offline.
        Page.route!(page, "**/*", &Route.fulfill(&1, content_type: "text/html", body: "<html></html>"))
        Page.goto!(page, server.cross_process_prefix <> "/empty.html")
        assert Page.evaluate!(page, "() => window.navigator.onLine") == false
      end

      BrowserContext.set_offline!(context, false)
      assert Page.evaluate!(page, "() => window.navigator.onLine") == true
      BrowserContext.close!(context)
    end
  end

  test "should emulate offline event", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    events =
      Page.evaluate_handle!(page, """
      () => {
        const events = [];
        window.addEventListener('offline', () => events.push('offline'));
        window.addEventListener('online', () => events.push('online'));
        return events;
      }
      """)

    BrowserContext.set_offline!(context, true)
    # await expect.poll(() => events.jsonValue()).toEqual([...])
    assert poll(fn -> JSHandle.json_value!(events) end, ["offline"])
    BrowserContext.set_offline!(context, false)
    assert poll(fn -> JSHandle.json_value!(events) end, ["offline", "online"])
    BrowserContext.close!(context)
  end

  test "should emulate media in popup", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, color_scheme: :dark)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_event!(page, :popup, fn ->
        Page.evaluate!(page, "url => { window.open(url); }", server.empty_page)
      end)

    assert Page.evaluate!(popup, "() => matchMedia('(prefers-color-scheme: light)').matches") == false
    assert Page.evaluate!(popup, "() => matchMedia('(prefers-color-scheme: dark)').matches") == true
    BrowserContext.close!(context)

    page = Browser.new_page!(browser, color_scheme: :light)
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_event!(page, :popup, fn ->
        Page.evaluate!(page, "url => { window.open(url); }", server.empty_page)
      end)

    assert Page.evaluate!(popup, "() => matchMedia('(prefers-color-scheme: light)').matches") == true
    assert Page.evaluate!(popup, "() => matchMedia('(prefers-color-scheme: dark)').matches") == false
    Page.close!(page)
  end

  test "should emulate media in cross-process iframe", %{browser: browser, server: server} do
    page = Browser.new_page!(browser, color_scheme: :dark)
    Page.goto!(page, server.empty_page)
    Utils.attach_frame(page, "frame1", server.cross_process_prefix <> "/empty.html")
    frame = Enum.at(Page.frames(page), 1)
    assert Frame.evaluate!(frame, "() => matchMedia('(prefers-color-scheme: dark)').matches") == true
    Page.close!(page)
  end

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

    Task.await_many(
      [
        Task.async(fn -> BrowserContext.new_page!(context1) end),
        Task.async(fn -> BrowserContext.new_page!(context1) end),
        Task.async(fn -> BrowserContext.new_page!(context2) end),
        Task.async(fn -> BrowserContext.new_page!(context2) end)
      ],
      :infinity
    )

    BrowserContext.close!(context1)
    BrowserContext.close!(context2)
    context3 = Browser.new_context!(browser)

    Task.await_many(
      [
        Task.async(fn -> BrowserContext.new_page!(context3) end),
        Task.async(fn -> BrowserContext.new_page!(context3) end)
      ],
      :infinity
    )

    BrowserContext.close!(context3)
  end
end
