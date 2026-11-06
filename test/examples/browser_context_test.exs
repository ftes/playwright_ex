defmodule PlaywrightEx.Examples.BrowserContextTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.{ConsoleMessage, Dialog, JSHandle, Promise, WebSocketRoute}

  # The examples that launch webkit run where it is the browser under test.
  @browser PlaywrightEx.TestBrowser.name()
  @webkit_only if(@browser != "webkit", do: "launches webkit, not the browser under test")

  example "BrowserContext",
    js: ~S"""
    // Create a new incognito browser context
    const context = await browser.newContext();
    // Create a new page inside context.
    const page = await context.newPage();
    await page.goto('https://example.com');
    // Dispose context once it's no longer needed.
    await context.close();
    """ do
    # Create a new incognito browser context
    context = Browser.new_context!(browser)
    # Create a new page inside context.
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com")
    # Dispose context once it's no longer needed.
    BrowserContext.close!(context)
  end

  example "BrowserContext.console",
    js: ~S"""
    context.on('console', async msg => {
      const values = [];
      for (const arg of msg.args())
        values.push(await arg.jsonValue());
      console.log(...values);
    });
    await page.evaluate(() => console.log('hello', 5, { foo: 'bar' }));
    """,
    # The listener's `json_value!` calls outlive the body: wait for them before the context closes.
    given: [_: on_exit(fn -> BrowserContext.remove_all_listeners(context, :console, behavior: :wait) end)] do
    BrowserContext.on(context, :console, fn msg ->
      values = for arg <- ConsoleMessage.args(msg), do: JSHandle.json_value!(arg)
      IO.puts(inspect(values))
    end)

    Page.evaluate!(page, "() => console.log('hello', 5, { foo: 'bar' })")
  end

  example "BrowserContext.dialog",
    js: ~S"""
    context.on('dialog', dialog => {
      dialog.accept();
    });
    """ do
    BrowserContext.on(context, :dialog, fn dialog ->
      Dialog.accept(dialog)
    end)
  end

  example "BrowserContext.page",
    js: ~S"""
    const newPagePromise = context.waitForEvent('page');
    await page.getByText('open new page').click();
    const newPage = await newPagePromise;
    console.log(await newPage.evaluate('location.href'));
    """,
    html: ~s(<a href="https://example.com/new" target="_blank">open new page</a>) do
    new_page_promise = BrowserContext.wait_for_event(context, :page)
    Page.get_by_text(page, "open new page") |> Locator.click!()
    new_page = Promise.await!(new_page_promise)
    IO.puts(Page.evaluate!(new_page, "location.href"))
  end

  example "BrowserContext.addCookies",
    js: ~S"""
    await browserContext.addCookies([cookieObject1, cookieObject2]);
    """,
    given: [
      browser_context: context,
      cookie_object1: %{name: "session-id", value: "1234", url: "https://example.com"},
      cookie_object2: %{name: "theme", value: "dark", domain: "example.com", path: "/"}
    ] do
    BrowserContext.add_cookies!(browser_context, [cookie_object1, cookie_object2])
  end

  example "BrowserContext.addInitScript",
    js: ~S"""
    // In your playwright script, assuming the preload.js file is in same directory.
    await browserContext.addInitScript({
      path: 'preload.js'
    });
    """,
    given: [browser_context: context, _: File.write!("preload.js", "Math.random = () => 42;")],
    writes: ["preload.js"] do
    # In your playwright script, assuming the preload.js file is in same directory.
    BrowserContext.add_init_script!(browser_context, %{path: "preload.js"})
  end

  example "BrowserContext.clearCookies",
    js: ~S"""
    await context.clearCookies();
    await context.clearCookies({ name: 'session-id' });
    await context.clearCookies({ domain: 'my-origin.com' });
    await context.clearCookies({ domain: /.*my-origin\.com/ });
    await context.clearCookies({ path: '/api/v1' });
    await context.clearCookies({ name: 'session-id', domain: 'my-origin.com' });
    """ do
    BrowserContext.clear_cookies!(context)
    BrowserContext.clear_cookies!(context, name: "session-id")
    BrowserContext.clear_cookies!(context, domain: "my-origin.com")
    BrowserContext.clear_cookies!(context, domain: ~r/.*my-origin\.com/)
    BrowserContext.clear_cookies!(context, path: "/api/v1")
    BrowserContext.clear_cookies!(context, name: "session-id", domain: "my-origin.com")
  end

  example "BrowserContext.clearPermissions",
    js: ~S"""
    const context = await browser.newContext();
    await context.grantPermissions(['clipboard-read']);
    // do stuff ..
    context.clearPermissions();
    """,
    skip: if(@browser == "firefox", do: "Firefox has no clipboard-read permission") do
    context = Browser.new_context!(browser)
    BrowserContext.grant_permissions!(context, ["clipboard-read"])
    # do stuff ..
    BrowserContext.clear_permissions(context)
  end

  # `headless: false` left out: the example is about the binding.
  example "BrowserContext.exposeBinding",
    js: ~S"""
    const { webkit } = require('playwright');  // Or 'chromium' or 'firefox'.

    (async () => {
      const browser = await webkit.launch({ headless: false });
      const context = await browser.newContext();
      await context.exposeBinding('pageURL', ({ page }) => page.url());
      const page = await context.newPage();
      await page.setContent(`
        <script>
          async function onClick() {
            document.querySelector('div').textContent = await window.pageURL();
          }
        </script>
        <button onclick="onClick()">Click me</button>
        <div></div>
      `);
      await page.getByRole('button').click();
    })();
    """,
    skip: @webkit_only do
    # Or Playwright.chromium/1 or Playwright.firefox/1.
    browser = BrowserType.launch!(Playwright.webkit(playwright))
    context = Browser.new_context!(browser)
    BrowserContext.expose_binding!(context, "pageURL", fn %{page: page} -> Page.url(page) end)
    page = BrowserContext.new_page!(context)

    Page.set_content!(page, """
    <script>
      async function onClick() {
        document.querySelector('div').textContent = await window.pageURL();
      }
    </script>
    <button onclick="onClick()">Click me</button>
    <div></div>
    """)

    Page.get_by_role(page, :button) |> Locator.click!()
  end

  # `headless: false` left out: the example is about the function.
  example "BrowserContext.exposeFunction",
    js: ~S"""
    const { webkit } = require('playwright');  // Or 'chromium' or 'firefox'.
    const crypto = require('crypto');

    (async () => {
      const browser = await webkit.launch({ headless: false });
      const context = await browser.newContext();
      await context.exposeFunction('sha256', text =>
        crypto.createHash('sha256').update(text).digest('hex'),
      );
      const page = await context.newPage();
      await page.setContent(`
        <script>
          async function onClick() {
            document.querySelector('div').textContent = await window.sha256('PLAYWRIGHT');
          }
        </script>
        <button onclick="onClick()">Click me</button>
        <div></div>
      `);
      await page.getByRole('button').click();
    })();
    """,
    skip: @webkit_only do
    # Or Playwright.chromium/1 or Playwright.firefox/1.
    browser = BrowserType.launch!(Playwright.webkit(playwright))
    context = Browser.new_context!(browser)

    BrowserContext.expose_function!(context, "sha256", fn text ->
      :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    end)

    page = BrowserContext.new_page!(context)

    Page.set_content!(page, """
    <script>
      async function onClick() {
        document.querySelector('div').textContent = await window.sha256('PLAYWRIGHT');
      }
    </script>
    <button onclick="onClick()">Click me</button>
    <div></div>
    """)

    Page.get_by_role(page, :button) |> Locator.click!()
  end

  example "BrowserContext.route",
    js: ~S"""
    const context = await browser.newContext();
    await context.route('**/*.{png,jpg,jpeg}', route => route.abort());
    const page = await context.newPage();
    await page.goto('https://example.com');
    await browser.close();
    """,
    given: [browser: own_browser(playwright)] do
    context = Browser.new_context!(browser)
    BrowserContext.route!(context, "**/*.{png,jpg,jpeg}", &Route.abort/1)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com")
    Browser.close!(browser)
  end

  example "BrowserContext.route",
    js: ~S"""
    const context = await browser.newContext();
    await context.route(/(\.png$)|(\.jpg$)/, route => route.abort());
    const page = await context.newPage();
    await page.goto('https://example.com');
    await browser.close();
    """,
    given: [browser: own_browser(playwright)] do
    context = Browser.new_context!(browser)
    BrowserContext.route!(context, ~r/(\.png$)|(\.jpg$)/, &Route.abort/1)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com")
    Browser.close!(browser)
  end

  example "BrowserContext.route",
    js: ~S"""
    await context.route('/api/**', async route => {
      if (route.request().postData().includes('my-string'))
        await route.fulfill({ body: 'mocked-data' });
      else
        await route.continue();
    });
    """ do
    BrowserContext.route!(context, "/api/**", fn route ->
      if Route.request(route) |> Request.post_data() |> String.contains?("my-string") do
        Route.fulfill!(route, body: "mocked-data")
      else
        Route.continue!(route)
      end
    end)
  end

  # Upstream's example calls `ws.routeSend()` and `ws.connect()`, which WebSocketRoute doesn't
  # have; this is the same handler with `connect_to_server/1` and `on_message/2`.
  example "BrowserContext.routeWebSocket",
    js: ~S"""
    await context.routeWebSocket('/ws', async ws => {
      ws.routeSend(message => {
        if (message === 'to-be-blocked')
          return;
        ws.send(message);
      });
      await ws.connect();
    });
    """ do
    BrowserContext.route_web_socket!(context, "/ws", fn ws ->
      server = WebSocketRoute.connect_to_server(ws)

      WebSocketRoute.on_message(ws, fn message ->
        if message != "to-be-blocked", do: WebSocketRoute.send(server, message)
      end)
    end)
  end

  example "BrowserContext.setGeolocation",
    js: ~S"""
    await browserContext.setGeolocation({ latitude: 59.95, longitude: 30.31667 });
    """,
    given: [browser_context: context] do
    BrowserContext.set_geolocation!(browser_context, %{latitude: 59.95, longitude: 30.31667})
  end

  example "BrowserContext.setStorageState",
    js: ~S"""
    // Load storage state from a file and apply it to the context.
    await context.setStorageState('state.json');
    """,
    given: [_: File.write!("state.json", ~s({"cookies": [], "origins": []}))],
    writes: ["state.json"] do
    # Load storage state from a file and apply it to the context.
    BrowserContext.set_storage_state!(context, "state.json")
  end

  example "BrowserContext.waitForEvent",
    js: ~S"""
    const pagePromise = context.waitForEvent('page');
    await page.getByRole('button').click();
    const page = await pagePromise;
    """,
    html: ~s{<button onclick="window.open('https://example.com/new')">Open</button>} do
    page_promise = BrowserContext.wait_for_event(context, :page)
    Page.get_by_role(page, :button) |> Locator.click!()
    page = Promise.await!(page_promise)
  end

  # A browser of the example's own, as it closes it.
  defp own_browser(playwright), do: BrowserType.launch!(PlaywrightEx.TestBrowser.browser_type(playwright))
end
