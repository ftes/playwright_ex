defmodule PlaywrightEx.Library.PopupTest do
  @upstream "tests/library/popup.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  defp req_header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  test "should inherit user agent from browser context @smoke", %{browser: browser, server: server} do
    # it.skip(isFrozenWebkit)
    context = Browser.new_context!(browser, user_agent: "hey")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a target=_blank rel=noopener href="/popup/popup.html">link</a>))
    request_promise = TestServer.wait_for_request(server, "/popup/popup.html")
    popup = BrowserContext.expect_event!(context, :page, fn -> Page.click!(page, "a") end)
    Page.wait_for_load_state!(popup, "domcontentloaded")
    user_agent = Page.evaluate!(popup, "() => window['initialUserAgent']")
    request = Task.await(request_promise, :infinity)
    BrowserContext.close!(context)
    assert user_agent == "hey"
    assert req_header(request, "user-agent") == "hey"
  end

  test "should respect routes from browser context", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a target=_blank rel=noopener href="empty.html">link</a>))
    test = self()

    BrowserContext.route!(context, "**/empty.html", fn route ->
      Route.continue(route)
      send(test, :intercepted)
    end)

    BrowserContext.expect_event!(context, :page, fn -> Page.click!(page, "a") end)
    BrowserContext.close!(context)
    assert_received :intercepted
  end

  test "should inherit extra headers from browser context", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, extra_http_headers: %{"foo" => "bar"})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    request_promise = TestServer.wait_for_request(server, "/dummy.html")
    Page.evaluate!(page, "url => { window['_popup'] = window.open(url); }", server.prefix <> "/dummy.html")
    request = Task.await(request_promise, :infinity)
    BrowserContext.close!(context)
    assert req_header(request, "foo") == "bar"
  end

  test "should inherit offline from browser context", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    BrowserContext.set_offline!(context, true)

    online =
      Page.evaluate!(
        page,
        """
        url => {
          const win = window.open(url);
          return win.navigator.onLine;
        }
        """,
        server.prefix <> "/dummy.html"
      )

    BrowserContext.close!(context)
    assert online == false
  end

  test "should inherit http credentials from browser context", %{browser: browser, server: server} do
    TestServer.set_auth(server, "/title.html", "user", "pass")
    context = Browser.new_context!(browser, http_credentials: %{username: "user", password: "pass"})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => { window['_popup'] = window.open(url); }", server.prefix <> "/title.html")
      end)

    Page.wait_for_load_state!(popup, "domcontentloaded")
    assert Page.title!(popup) == "Woof-Woof"
    BrowserContext.close!(context)
  end

  test "should inherit touch support from browser context", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: %{width: 400, height: 500}, has_touch: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    has_touch =
      Page.evaluate!(page, """
      () => {
        const win = window.open('');
        return 'ontouchstart' in win;
      }
      """)

    BrowserContext.close!(context)
    assert has_touch == true
  end

  test "should inherit viewport size from browser context", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: %{width: 400, height: 500})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    size =
      Page.evaluate!(page, """
      () => {
        const win = window.open('about:blank');
        return { width: win.innerWidth, height: win.innerHeight };
      }
      """)

    BrowserContext.close!(context)
    assert size == %{"width" => 400, "height" => 500}
  end

  test "should use viewport size from window features", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: %{width: 700, height: 700})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    popup_promise = Page.wait_for_event(page, :popup)

    size =
      Page.evaluate!(page, """
      async () => {
        const win = window.open(window.location.href, 'Title', 'toolbar=no,location=no,directories=no,status=no,menubar=no,scrollbars=yes,resizable=yes,width=600,height=300,top=0,left=0');
        await new Promise(resolve => {
          const interval = window.builtins.setInterval(() => {
            if (win.innerWidth === 600 && win.innerHeight === 300) {
              window.builtins.clearInterval(interval);
              resolve();
            }
          }, 10);
        });
        return { width: win.innerWidth, height: win.innerHeight };
      }
      """)

    popup = Promise.await!(popup_promise)
    Page.set_viewport_size!(popup, %{width: 500, height: 400})
    Page.wait_for_load_state!(popup)
    resized = Page.evaluate!(popup, "() => ({ width: window.innerWidth, height: window.innerHeight })")
    BrowserContext.close!(context)
    assert size == %{"width" => 600, "height" => 300}
    assert resized == %{"width" => 500, "height" => 400}
  end

  test "should respect routes from browser context when using window.open", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    test = self()

    BrowserContext.route!(context, "**/empty.html", fn route ->
      Route.continue(route)
      send(test, :intercepted)
    end)

    Page.expect_popup!(page, fn ->
      Page.evaluate!(page, "url => { window['__popup'] = window.open(url); }", server.empty_page)
    end)

    assert_received :intercepted
    BrowserContext.close!(context)
  end

  test "BrowserContext.addInitScript should apply to an in-process popup", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    BrowserContext.add_init_script!(context, "window['injected'] = 123")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    injected =
      Page.evaluate!(page, """
      () => {
        const win = window.open('about:blank');
        return win['injected'];
      }
      """)

    BrowserContext.close!(context)
    assert injected == 123
  end

  test "BrowserContext.addInitScript should apply to a cross-process popup", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    BrowserContext.add_init_script!(context, "window['injected'] = 123")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => { window.open(url); }", server.cross_process_prefix <> "/title.html")
      end)

    assert Page.evaluate!(popup, "injected") == 123
    Page.reload!(popup)
    assert Page.evaluate!(popup, "injected") == 123
    BrowserContext.close!(context)
  end

  test "should expose function from browser context", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    test = self()

    BrowserContext.expose_function!(context, "add", fn a, b ->
      send(test, {:message, "binding"})
      a + b
    end)

    page = BrowserContext.new_page!(context)
    BrowserContext.on(context, :page, fn _ -> send(test, {:message, "page"}) end)
    Page.goto!(page, server.empty_page)

    added =
      Page.evaluate!(page, """
      async () => {
        const win = window.open('about:blank');
        return win['add'](9, 4);
      }
      """)

    BrowserContext.close!(context)
    assert added == 13
    assert_received {:message, first}
    assert_received {:message, second}
    assert Enum.join([first, second], "|") == "page|binding"
  end

  test "should not dispatch binding on a closed page", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    test = self()

    BrowserContext.expose_binding!(context, "add", fn source, a, b ->
      send(test, {:was_closed, Page.is_closed(source.page)})
      a + b
    end)

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Page.expect_popup!(page, fn ->
      Page.evaluate!(page, """
      async () => {
        const win = window.open('about:blank');
        win['add'](9, 4);
        win.close();
      }
      """)
    end)

    # Give it a chance to dispatch the binding on the closed page.
    Page.wait_for_timeout!(page, 1000)
    BrowserContext.close!(context)
    refute_received {:was_closed, true}
  end

  @tag :page
  test "should not throttle rAF in the opener page", %{page: page, server: server} do
    # annotation: https://github.com/microsoft/playwright/issues/14557
    Page.goto!(page, server.empty_page)
    popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => { window.open('about:blank'); }") end)

    Task.await_many(
      [
        Task.async(fn -> wait_for_rafs(page, 30) end),
        Task.async(fn -> wait_for_rafs(popup, 30) end)
      ],
      :infinity
    )
  end

  @tag :page
  # it.fixme(browserName === 'firefox', 'locator.click: Target page, context or browser has been closed');
  @tag skip:
         if(@browser_name == "firefox",
           do: "upstream fixme: locator.click: Target page, context or browser has been closed"
         )
  test "should not throw when click closes popup", %{browser_name: browser_name, page: page, server: server} do
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(
          page,
          """
          async browserName => {
            const w = window.open('about:blank');
            if (browserName === 'firefox')
              await new Promise(x => w.onload = x);
            w.document.body.innerHTML = `<button onclick="window.close()">close</button>`;
          }
          """,
          browser_name
        )
      end)

    popup |> Page.get_by_role("button") |> Locator.click!()
  end

  defp wait_for_rafs(page, count) do
    Page.evaluate!(
      page,
      """
      count => new Promise(resolve => {
        const onRaf = () => {
          --count;
          if (!count)
            resolve();
          else
            window.builtins.requestAnimationFrame(onRaf);
        };
        window.builtins.requestAnimationFrame(onRaf);
      })
      """,
      count
    )
  end
end
