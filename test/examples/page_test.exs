defmodule PlaywrightEx.Examples.PageTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.{ConsoleMessage, Dialog, ElementHandle, FileChooser, JSHandle, Promise, Screencast}
  alias PlaywrightEx.{WebMCP, WebSocketRoute, WebStorage}

  @chromium_only if PlaywrightEx.TestBrowser.name() != "chromium", do: "chromium only"
  @own_browser "launches a browser of its own"
  @own_page "navigates a page of its own: not offline"

  example "Page.waitForNavigation",
    js: ~S"""
    // Start waiting for navigation before clicking. Note no await.
    const navigationPromise = page.waitForNavigation();
    await page.getByText('Navigate after timeout').click();
    await navigationPromise;
    """,
    html: ~s{<button onclick="setTimeout(() => location.href = '/next', 100)">Navigate after timeout</button>} do
    # Start waiting for navigation before clicking: a promise, awaited after.
    navigation_promise = Page.wait_for_navigation(page)
    Page.get_by_text(page, "Navigate after timeout") |> Locator.click!()
    Promise.await!(navigation_promise)
  end

  example "Page",
    js: ~S"""
    const { webkit } = require('playwright');  // Or 'chromium' or 'firefox'.

    (async () => {
      const browser = await webkit.launch();
      const context = await browser.newContext();
      const page = await context.newPage();
      await page.goto('https://example.com');
      await page.screenshot({ path: 'screenshot.png' });
      await browser.close();
    })();
    """,
    skip: "#{@own_browser}, navigates it: not offline" do
    # Or Playwright.chromium/1 or Playwright.firefox/1.
    browser = Playwright.webkit(playwright) |> BrowserType.launch!()
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com")
    Page.screenshot!(page, path: "screenshot.png")
    Browser.close!(browser)
  end

  example "Page",
    js: ~S"""
    page.once('load', () => console.log('Page loaded!'));
    """ do
    Page.once(page, :load, fn _page -> IO.puts("Page loaded!") end)
  end

  example "Page",
    js: ~S"""
    function logRequest(interceptedRequest) {
      console.log('A request was made:', interceptedRequest.url());
    }
    page.on('request', logRequest);
    // Sometime later...
    page.removeListener('request', logRequest);
    """ do
    log_request = fn intercepted_request ->
      IO.puts("A request was made: #{Request.url(intercepted_request)}")
    end

    Page.on(page, :request, log_request)
    # Sometime later...
    Page.remove_listener(page, :request, log_request)
  end

  example "Page.console",
    js: ~S"""
    page.on('console', async msg => {
      const values = [];
      for (const arg of msg.args())
        values.push(await arg.jsonValue());
      console.log(...values);
    });
    await page.evaluate(() => console.log('hello', 5, { foo: 'bar' }));
    """,
    # The listener's `json_value!` calls would outlive the test.
    after: Page.remove_all_listeners!(page, :console, behavior: :wait) do
    Page.on(page, :console, fn msg ->
      values = for arg <- ConsoleMessage.args(msg), do: JSHandle.json_value!(arg)
      IO.puts(inspect(values))
    end)

    Page.evaluate!(page, "() => console.log('hello', 5, { foo: 'bar' })")
  end

  example "Page.crash",
    js: ~S"""
    try {
      // Crash might happen during a click.
      await page.click('button');
      // Or while waiting for an event.
      await page.waitForEvent('popup');
    } catch (e) {
      // When the page crashes, exception message contains 'crash'.
    }
    """,
    html: ~s{<button onclick="setTimeout(() => window.open('/popup'), 100)">Open</button>} do
    try do
      # Crash might happen during a click.
      Page.click!(page, "button")
      # Or while waiting for an event.
      Page.wait_for_event!(page, :popup)
    rescue
      e ->
        # When the page crashes, exception message contains "crash".
        Exception.message(e)
    end
  end

  example "Page.dialog",
    js: ~S"""
    page.on('dialog', dialog => dialog.accept());
    """ do
    Page.on(page, :dialog, &Dialog.accept/1)
  end

  example "Page.fileChooser",
    js: ~S"""
    page.on('filechooser', async fileChooser => {
      await fileChooser.setFiles(path.join(__dirname, '/tmp/myfile.pdf'));
    });
    """ do
    Page.on(page, :file_chooser, fn file_chooser ->
      FileChooser.set_files!(file_chooser, Path.join(__DIR__, "/tmp/myfile.pdf"))
    end)
  end

  example "Page.pageError",
    js: ~S"""
    // Log all uncaught errors to the terminal
    page.on('pageerror', exception => {
      console.log(`Uncaught exception: "${exception}"`);
    });

    // Navigate to a page with an exception.
    await page.goto('data:text/html,<script>throw new Error("Test")</script>');
    """ do
    # Log all uncaught errors to the terminal
    Page.on(page, :page_error, fn exception ->
      IO.puts("Uncaught exception: \"#{Exception.message(exception)}\"")
    end)

    # Navigate to a page with an exception.
    Page.goto!(page, ~s{data:text/html,<script>throw new Error("Test")</script>})
  end

  example "Page.popup",
    js: ~S"""
    // Start waiting for popup before clicking. Note no await.
    const popupPromise = page.waitForEvent('popup');
    await page.getByText('open the popup').click();
    const popup = await popupPromise;
    console.log(await popup.evaluate('location.href'));
    """,
    html: ~s(<a href="/popup" target="_blank">open the popup</a>) do
    # Start waiting for popup before clicking: a promise, awaited after.
    popup_promise = Page.wait_for_event(page, :popup)
    Page.get_by_text(page, "open the popup") |> Locator.click!()
    popup = Promise.await!(popup_promise)
    IO.puts(Page.evaluate!(popup, "location.href"))
  end

  example "Page.requestFailed",
    js: ~S"""
    page.on('requestfailed', request => {
      console.log(request.url() + ' ' + request.failure().errorText);
    });
    """ do
    Page.on(page, :request_failed, fn request ->
      IO.puts(Request.url(request) <> " " <> Request.failure(request).errorText)
    end)
  end

  example "Page.addInitScript",
    js: ~S"""
    // In your playwright script, assuming the preload.js file is in same directory
    await page.addInitScript({ path: './preload.js' });
    """,
    given: [_preload: File.write!("preload.js", "window.preloaded = true;")],
    writes: ["preload.js"] do
    # In your playwright script, assuming the preload.js file is in same directory
    Page.add_init_script!(page, %{path: "./preload.js"})
  end

  example "Page.addInitScript",
    js: ~S"""
    await page.addInitScript(mock => {
      window.mock = mock;
    }, mock);
    """,
    given: [mock: %{"answer" => 42}] do
    Page.add_init_script!(page, "mock => { window.mock = mock; }", mock)
  end

  example "Page.dispatchEvent",
    js: ~S"""
    await page.dispatchEvent('button#submit', 'click');
    """,
    html: ~s(<button id="submit">Submit</button>) do
    Page.dispatch_event!(page, "button#submit", "click")
  end

  example "Page.dispatchEvent",
    js: ~S"""
    // Note you can only create DataTransfer in Chromium and Firefox
    const dataTransfer = await page.evaluateHandle(() => new DataTransfer());
    await page.dispatchEvent('#source', 'dragstart', { dataTransfer });
    """,
    html: ~s(<div id="source" draggable="true">Drag me</div>) do
    # Note you can only create DataTransfer in Chromium and Firefox
    data_transfer = Page.evaluate_handle!(page, "() => new DataTransfer()")
    Page.dispatch_event!(page, "#source", "dragstart", %{dataTransfer: data_transfer})
  end

  example "Page.dragAndDrop",
    js: ~S"""
    await page.dragAndDrop('#source', '#target');
    // or specify exact positions relative to the top-left corners of the elements:
    await page.dragAndDrop('#source', '#target', {
      sourcePosition: { x: 34, y: 7 },
      targetPosition: { x: 10, y: 20 },
    });
    """,
    html: """
    <div id="source" draggable="true" style="width: 100px; height: 50px">source</div>
    <div id="target" style="width: 100px; height: 50px">target</div>
    """ do
    Page.drag_and_drop!(page, "#source", "#target")
    # or specify exact positions relative to the top-left corners of the elements:
    Page.drag_and_drop!(page, "#source", "#target",
      source_position: %{x: 34, y: 7},
      target_position: %{x: 10, y: 20}
    )
  end

  example "Page.emulateMedia",
    js: ~S"""
    await page.evaluate(() => matchMedia('screen').matches);
    // → true
    await page.evaluate(() => matchMedia('print').matches);
    // → false

    await page.emulateMedia({ media: 'print' });
    await page.evaluate(() => matchMedia('screen').matches);
    // → false
    await page.evaluate(() => matchMedia('print').matches);
    // → true

    await page.emulateMedia({});
    await page.evaluate(() => matchMedia('screen').matches);
    // → true
    await page.evaluate(() => matchMedia('print').matches);
    // → false
    """ do
    Page.evaluate!(page, "() => matchMedia('screen').matches")
    # => true
    Page.evaluate!(page, "() => matchMedia('print').matches")
    # => false

    Page.emulate_media!(page, media: :print)
    Page.evaluate!(page, "() => matchMedia('screen').matches")
    # => false
    Page.evaluate!(page, "() => matchMedia('print').matches")
    # => true

    # `:null` (JS `null`) removes the emulation, leaving `:media` out keeps it.
    Page.emulate_media!(page, media: :null)
    Page.evaluate!(page, "() => matchMedia('screen').matches")
    # => true
    Page.evaluate!(page, "() => matchMedia('print').matches")
    # => false
  end

  example "Page.emulateMedia",
    js: ~S"""
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.evaluate(() => matchMedia('(prefers-color-scheme: dark)').matches);
    // → true
    await page.evaluate(() => matchMedia('(prefers-color-scheme: light)').matches);
    // → false
    """ do
    Page.emulate_media!(page, color_scheme: :dark)
    Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches")
    # => true
    Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: light)').matches")
    # => false
  end

  example "Page.evalOnSelector",
    js: ~S"""
    const searchValue = await page.$eval('#search', el => el.value);
    const preloadHref = await page.$eval('link[rel=preload]', el => el.href);
    const html = await page.$eval('.main-container', (e, suffix) => e.outerHTML + suffix, 'hello');
    // In TypeScript, this example requires an explicit type annotation (HTMLLinkElement) on el:
    const preloadHrefTS = await page.$eval('link[rel=preload]', (el: HTMLLinkElement) => el.href);
    """,
    html: """
    <link rel="preload" href="/style.css" as="style">
    <input id="search" value="playwright">
    <div class="main-container">main</div>
    """ do
    search_value = Page.eval_on_selector!(page, "#search", "el => el.value")
    preload_href = Page.eval_on_selector!(page, "link[rel=preload]", "el => el.href")
    html = Page.eval_on_selector!(page, ".main-container", "(e, suffix) => e.outerHTML + suffix", "hello")
  end

  example "Page.evalOnSelectorAll",
    js: ~S"""
    const divCounts = await page.$$eval('div', (divs, min) => divs.length >= min, 10);
    """,
    html: "<div>one</div><div>two</div>" do
    div_counts = Page.eval_on_selector_all!(page, "div", "(divs, min) => divs.length >= min", 10)
  end

  example "Page.evaluate",
    js: ~S"""
    const result = await page.evaluate(([x, y]) => {
      return Promise.resolve(x * y);
    }, [7, 8]);
    console.log(result); // prints "56"
    """ do
    result = Page.evaluate!(page, "([x, y]) => Promise.resolve(x * y)", [7, 8])
    # prints "56"
    IO.puts(result)
  end

  example "Page.evaluate",
    js: ~S"""
    console.log(await page.evaluate('1 + 2')); // prints "3"
    const x = 10;
    console.log(await page.evaluate(`1 + ${x}`)); // prints "11"
    """ do
    # prints "3"
    IO.puts(Page.evaluate!(page, "1 + 2"))
    x = 10
    # prints "11"
    IO.puts(Page.evaluate!(page, "1 + #{x}"))
  end

  example "Page.evaluate",
    js: ~S"""
    const bodyHandle = await page.evaluateHandle('document.body');
    const html = await page.evaluate<string, HTMLElement>(([body, suffix]) =>
      body.innerHTML + suffix, [bodyHandle, 'hello']
    );
    await bodyHandle.dispose();
    """ do
    body_handle = Page.evaluate_handle!(page, "document.body")
    html = Page.evaluate!(page, "([body, suffix]) => body.innerHTML + suffix", [body_handle, "hello"])
    JSHandle.dispose!(body_handle)
  end

  example "Page.evaluateHandle",
    js: ~S"""
    // Handle for the window object.
    const aWindowHandle = await page.evaluateHandle(() => Promise.resolve(window));
    """ do
    # Handle for the window object.
    a_window_handle = Page.evaluate_handle!(page, "() => Promise.resolve(window)")
  end

  example "Page.evaluateHandle",
    js: ~S"""
    const aHandle = await page.evaluateHandle('document'); // Handle for the 'document'
    """ do
    # Handle for the "document"
    a_handle = Page.evaluate_handle!(page, "document")
  end

  example "Page.evaluateHandle",
    js: ~S"""
    const aHandle = await page.evaluateHandle(() => document.body);
    const resultHandle = await page.evaluateHandle(body => body.innerHTML, aHandle);
    console.log(await resultHandle.jsonValue());
    await resultHandle.dispose();
    """,
    html: "<p>Hello</p>" do
    a_handle = Page.evaluate_handle!(page, "() => document.body")
    result_handle = Page.evaluate_handle!(page, "body => body.innerHTML", a_handle)
    IO.puts(JSHandle.json_value!(result_handle))
    JSHandle.dispose!(result_handle)
  end

  example "Page.exposeBinding",
    js: ~S"""
    const { webkit } = require('playwright');  // Or 'chromium' or 'firefox'.

    (async () => {
      const browser = await webkit.launch({ headless: false });
      const context = await browser.newContext();
      const page = await context.newPage();
      await page.exposeBinding('pageURL', ({ page }) => page.url());
      await page.setContent(`
        <script>
          async function onClick() {
            document.querySelector('div').textContent = await window.pageURL();
          }
        </script>
        <button onclick="onClick()">Click me</button>
        <div></div>
      `);
      await page.click('button');
    })();
    """,
    skip: "#{@own_browser}, headed" do
    # Or Playwright.chromium/1 or Playwright.firefox/1.
    browser = Playwright.webkit(playwright) |> BrowserType.launch!(headless: false)
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.expose_binding!(page, "pageURL", fn %{page: page} -> Page.url(page) end)

    Page.set_content!(page, """
    <script>
      async function onClick() {
        document.querySelector('div').textContent = await window.pageURL();
      }
    </script>
    <button onclick="onClick()">Click me</button>
    <div></div>
    """)

    Page.click!(page, "button")
  end

  example "Page.exposeFunction",
    js: ~S"""
    const { webkit } = require('playwright');  // Or 'chromium' or 'firefox'.
    const crypto = require('crypto');

    (async () => {
      const browser = await webkit.launch({ headless: false });
      const page = await browser.newPage();
      await page.exposeFunction('sha256', text =>
        crypto.createHash('sha256').update(text).digest('hex'),
      );
      await page.setContent(`
        <script>
          async function onClick() {
            document.querySelector('div').textContent = await window.sha256('PLAYWRIGHT');
          }
        </script>
        <button onclick="onClick()">Click me</button>
        <div></div>
      `);
      await page.click('button');
    })();
    """,
    skip: "#{@own_browser}, headed" do
    # Or Playwright.chromium/1 or Playwright.firefox/1.
    browser = Playwright.webkit(playwright) |> BrowserType.launch!(headless: false)
    page = Browser.new_page!(browser)

    Page.expose_function!(page, "sha256", fn text ->
      :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    end)

    Page.set_content!(page, """
    <script>
      async function onClick() {
        document.querySelector('div').textContent = await window.sha256('PLAYWRIGHT');
      }
    </script>
    <button onclick="onClick()">Click me</button>
    <div></div>
    """)

    Page.click!(page, "button")
  end

  example "Page.frame",
    js: ~S"""
    const frame = page.frame('frame-name');
    """,
    html: ~s(<iframe name="frame-name"></iframe>) do
    frame = Page.frame(page, "frame-name")
  end

  example "Page.frame",
    js: ~S"""
    const frame = page.frame({ url: /.*domain.*/ });
    """ do
    frame = Page.frame(page, %{url: ~r/.*domain.*/})
  end

  example "Page.frameLocator",
    js: ~S"""
    const locator = page.frameLocator('#my-iframe').getByText('Submit');
    await locator.click();
    """,
    html: ~s(<iframe id="my-iframe" srcdoc="<button>Submit</button>"></iframe>) do
    locator = Page.frame_locator(page, "#my-iframe") |> FrameLocator.get_by_text("Submit")
    Locator.click!(locator)
  end

  example "Page.frameLocator",
    js: ~S"""
    const locator = page.frameLocator().getByRole('button');
    await locator.click();
    """,
    html: ~s(<iframe srcdoc="<button>Submit</button>"></iframe>) do
    locator = Page.frame_locator(page) |> FrameLocator.get_by_role(:button)
    Locator.click!(locator)
  end

  example "Page.getByRef",
    js: ~S"""
    await page.getByRef('e2').click();
    """,
    html: "<button>Submit</button>",
    given: [_snapshot: Page.aria_snapshot!(page, mode: :ai)] do
    Page.get_by_ref(page, "e2") |> Locator.click!()
  end

  example "Page.requestGC",
    js: ~S"""
    // 1. In your page, save a WeakRef for the "suspect".
    await page.evaluate(() => globalThis.suspectWeakRef = new WeakRef(suspect));
    // 2. Request garbage collection.
    await page.requestGC();
    // 3. Check that weak ref does not deref to the original object.
    expect(await page.evaluate(() => !globalThis.suspectWeakRef.deref())).toBe(true);
    """,
    # A new object each time, held by nothing but the WeakRef.
    html: """
    <script>Object.defineProperty(globalThis, 'suspect', { get: () => ({}) });</script>
    """ do
    # 1. In your page, save a WeakRef for the "suspect".
    Page.evaluate!(page, "() => globalThis.suspectWeakRef = new WeakRef(suspect)")
    # 2. Request garbage collection.
    Page.request_gc!(page)
    # 3. Check that weak ref does not deref to the original object.
    assert Page.evaluate!(page, "() => !globalThis.suspectWeakRef.deref()") == true
  end

  example "Page.localStorage",
    js: ~S"""
    await page.localStorage.setItem('token', 'abc');
    const token = await page.localStorage.getItem('token');
    """ do
    Page.local_storage(page) |> WebStorage.set_item!("token", "abc")
    token = Page.local_storage(page) |> WebStorage.get_item!("token")
  end

  example "Page.sessionStorage",
    js: ~S"""
    await page.sessionStorage.setItem('flag', '1');
    const flag = await page.sessionStorage.getItem('flag');
    """ do
    Page.session_storage(page) |> WebStorage.set_item!("flag", "1")
    flag = Page.session_storage(page) |> WebStorage.get_item!("flag")
  end

  example "Page.pdf",
    js: ~S"""
    // Generates a PDF with 'screen' media type.
    await page.emulateMedia({ media: 'screen' });
    await page.pdf({ path: 'page.pdf' });
    """,
    skip: @chromium_only,
    writes: ["page.pdf"] do
    # Generates a PDF with "screen" media type.
    Page.emulate_media!(page, media: :screen)
    Page.pdf!(page, path: "page.pdf")
  end

  example "Page.pickLocator",
    js: ~S"""
    const locator = await page.pickLocator();
    console.log(locator);
    """,
    skip: "waits for the user to pick an element" do
    locator = Page.pick_locator!(page)
    IO.puts(Locator.to_string(locator))
  end

  example "Page.press",
    js: ~S"""
    const page = await browser.newPage();
    await page.goto('https://keycode.info');
    await page.press('body', 'A');
    await page.screenshot({ path: 'A.png' });
    await page.press('body', 'ArrowLeft');
    await page.screenshot({ path: 'ArrowLeft.png' });
    await page.press('body', 'Shift+O');
    await page.screenshot({ path: 'O.png' });
    await browser.close();
    """,
    skip: @own_page do
    page = Browser.new_page!(browser)
    Page.goto!(page, "https://keycode.info")
    Page.press!(page, "body", "A")
    Page.screenshot!(page, path: "A.png")
    Page.press!(page, "body", "ArrowLeft")
    Page.screenshot!(page, path: "ArrowLeft.png")
    Page.press!(page, "body", "Shift+O")
    Page.screenshot!(page, path: "O.png")
    Browser.close!(browser)
  end

  example "Page.addLocatorHandler",
    js: ~S"""
    // Setup the handler.
    await page.addLocatorHandler(page.getByText('Sign up to the newsletter'), async () => {
      await page.getByRole('button', { name: 'No thanks' }).click();
    });

    // Write the test as usual.
    await page.goto('https://example.com');
    await page.getByRole('button', { name: 'Start here' }).click();
    """,
    html: """
    <div id="overlay">Sign up to the newsletter <button onclick="overlay.remove()">No thanks</button></div>
    <button>Start here</button>
    """ do
    # Setup the handler.
    Page.add_locator_handler!(page, Page.get_by_text(page, "Sign up to the newsletter"), fn ->
      Page.get_by_role(page, :button, name: "No thanks") |> Locator.click!()
    end)

    # Write the test as usual.
    Page.goto!(page, "https://example.com")
    Page.get_by_role(page, :button, name: "Start here") |> Locator.click!()
  end

  example "Page.addLocatorHandler",
    js: ~S"""
    // Setup the handler.
    await page.addLocatorHandler(page.getByText('Confirm your security details'), async () => {
      await page.getByRole('button', { name: 'Remind me later' }).click();
    });

    // Write the test as usual.
    await page.goto('https://example.com');
    await page.getByRole('button', { name: 'Start here' }).click();
    """,
    html: """
    <div id="overlay">Confirm your security details <button onclick="overlay.remove()">Remind me later</button></div>
    <button>Start here</button>
    """ do
    # Setup the handler.
    Page.add_locator_handler!(page, Page.get_by_text(page, "Confirm your security details"), fn ->
      Page.get_by_role(page, :button, name: "Remind me later") |> Locator.click!()
    end)

    # Write the test as usual.
    Page.goto!(page, "https://example.com")
    Page.get_by_role(page, :button, name: "Start here") |> Locator.click!()
  end

  example "Page.addLocatorHandler",
    js: ~S"""
    // Setup the handler.
    await page.addLocatorHandler(page.locator('body'), async () => {
      await page.evaluate(() => window.removeObstructionsForTestIfNeeded());
    }, { noWaitAfter: true });

    // Write the test as usual.
    await page.goto('https://example.com');
    await page.getByRole('button', { name: 'Start here' }).click();
    """,
    html: """
    <script>window.removeObstructionsForTestIfNeeded = () => {};</script>
    <button>Start here</button>
    """ do
    # Setup the handler.
    Page.add_locator_handler!(
      page,
      Page.locator(page, "body"),
      fn -> Page.evaluate!(page, "() => window.removeObstructionsForTestIfNeeded()") end,
      no_wait_after: true
    )

    # Write the test as usual.
    Page.goto!(page, "https://example.com")
    Page.get_by_role(page, :button, name: "Start here") |> Locator.click!()
  end

  example "Page.addLocatorHandler",
    js: ~S"""
    await page.addLocatorHandler(page.getByLabel('Close'), async locator => {
      await locator.click();
    }, { times: 1 });
    """ do
    Page.add_locator_handler!(page, Page.get_by_label(page, "Close"), &Locator.click!/1, times: 1)
  end

  example "Page.removeAllListeners",
    js: ~S"""
    page.on('request', async request => {
      const response = await request.response();
      const body = await response.body();
      console.log(body.byteLength);
    });
    await page.goto('https://playwright.dev', { waitUntil: 'domcontentloaded' });
    // Waits for all the reported 'request' events to resolve.
    await page.removeAllListeners('request', { behavior: 'wait' });
    """ do
    Page.on(page, :request, fn request ->
      response = Request.response!(request)
      body = Response.body!(response)
      IO.puts(byte_size(body))
    end)

    Page.goto!(page, "https://playwright.dev", wait_until: :domcontentloaded)
    # Waits for all the reported :request events to resolve.
    Page.remove_all_listeners!(page, :request, behavior: :wait)
  end

  example "Page.route",
    js: ~S"""
    const page = await browser.newPage();
    await page.route('**/*.{png,jpg,jpeg}', route => route.abort());
    await page.goto('https://example.com');
    await browser.close();
    """,
    skip: @own_page do
    page = Browser.new_page!(browser)
    Page.route!(page, "**/*.{png,jpg,jpeg}", &Route.abort/1)
    Page.goto!(page, "https://example.com")
    Browser.close!(browser)
  end

  example "Page.route",
    js: ~S"""
    const page = await browser.newPage();
    await page.route(/(\.png$)|(\.jpg$)/, route => route.abort());
    await page.goto('https://example.com');
    await browser.close();
    """,
    skip: @own_page do
    page = Browser.new_page!(browser)
    Page.route!(page, ~r/(\.png$)|(\.jpg$)/, &Route.abort/1)
    Page.goto!(page, "https://example.com")
    Browser.close!(browser)
  end

  example "Page.route",
    js: ~S"""
    await page.route('/api/**', async route => {
      if (route.request().postData().includes('my-string'))
        await route.fulfill({ body: 'mocked-data' });
      else
        await route.continue();
    });
    """ do
    Page.route!(page, "/api/**", fn route ->
      if Route.request(route) |> Request.post_data() |> String.contains?("my-string") do
        Route.fulfill!(route, body: "mocked-data")
      else
        Route.continue!(route)
      end
    end)
  end

  example "Page.routeWebSocket",
    js: ~S"""
    await page.routeWebSocket('/ws', ws => {
      ws.onMessage(message => {
        if (message === 'request')
          ws.send('response');
      });
    });
    """ do
    Page.route_web_socket!(page, "/ws", fn ws ->
      WebSocketRoute.on_message(ws, fn message ->
        if message == "request", do: WebSocketRoute.send(ws, "response")
      end)
    end)
  end

  example "Page.screencast",
    js: ~S"""
    page.screencast.on('screencastFrame', data => {
      console.log('received frame, jpeg size:', data.length);
    });
    await page.screencast.start();
    // ... perform actions ...
    await page.screencast.stop();
    """ do
    # Frames go to the `:on_frame` callback (Screencast has no events).
    screencast = Page.screencast(page)

    Screencast.start!(screencast,
      on_frame: fn %{data: data} -> IO.puts("received frame, jpeg size: #{byte_size(data)}") end
    )

    # ... perform actions ...
    Screencast.stop!(screencast)
  end

  example "Page.selectOption",
    js: ~S"""
    // Single selection matching the value or label
    page.selectOption('select#colors', 'blue');

    // single selection matching the label
    page.selectOption('select#colors', { label: 'Blue' });

    // multiple selection
    page.selectOption('select#colors', ['red', 'green', 'blue']);
    """,
    html: """
    <select id="colors" multiple>
      <option value="red">Red</option>
      <option value="green">Green</option>
      <option value="blue">Blue</option>
    </select>
    """ do
    # Single selection matching the value or label
    Page.select_option!(page, "select#colors", "blue")

    # single selection matching the label
    Page.select_option!(page, "select#colors", %{label: "Blue"})

    # multiple selection
    Page.select_option!(page, "select#colors", ["red", "green", "blue"])
  end

  example "Page.setViewportSize",
    js: ~S"""
    const page = await browser.newPage();
    await page.setViewportSize({
      width: 640,
      height: 480,
    });
    await page.goto('https://example.com');
    """,
    skip: @own_page do
    page = Browser.new_page!(browser)
    Page.set_viewport_size!(page, %{width: 640, height: 480})
    Page.goto!(page, "https://example.com")
  end

  example "Page.waitForEvent",
    js: ~S"""
    // Start waiting for download before clicking. Note no await.
    const downloadPromise = page.waitForEvent('download');
    await page.getByText('Download file').click();
    const download = await downloadPromise;
    """,
    html: ~s(<a href="/file.txt" download>Download file</a>) do
    # Start waiting for download before clicking: a promise, awaited after.
    download_promise = Page.wait_for_event(page, :download)
    Page.get_by_text(page, "Download file") |> Locator.click!()
    download = Promise.await!(download_promise)
  end

  example "Page.waitForFunction",
    js: ~S"""
    const { webkit } = require('playwright');  // Or 'chromium' or 'firefox'.

    (async () => {
      const browser = await webkit.launch();
      const page = await browser.newPage();
      const watchDog = page.waitForFunction(() => window.innerWidth < 100);
      await page.setViewportSize({ width: 50, height: 50 });
      await watchDog;
      await browser.close();
    })();
    """,
    skip: @own_browser do
    # Or Playwright.chromium/1 or Playwright.firefox/1.
    browser = Playwright.webkit(playwright) |> BrowserType.launch!()
    page = Browser.new_page!(browser)
    watch_dog = Task.async(fn -> Page.wait_for_function!(page, "() => window.innerWidth < 100") end)
    Page.set_viewport_size!(page, %{width: 50, height: 50})
    Task.await(watch_dog)
    Browser.close!(browser)
  end

  example "Page.waitForFunction",
    js: ~S"""
    const selector = '.foo';
    await page.waitForFunction(selector => !!document.querySelector(selector), selector);
    """,
    html: ~s(<div class="foo"></div>) do
    selector = ".foo"
    Page.wait_for_function!(page, "selector => !!document.querySelector(selector)", selector)
  end

  example "Page.waitForLoadState",
    js: ~S"""
    await page.getByRole('button').click(); // Click triggers navigation.
    await page.waitForLoadState(); // The promise resolves after 'load' event.
    """,
    html: ~s(<button onclick="location.href = '/next'">Go</button>) do
    # Click triggers navigation.
    Page.get_by_role(page, :button) |> Locator.click!()
    # Returns after the "load" event.
    Page.wait_for_load_state!(page)
  end

  example "Page.waitForLoadState",
    js: ~S"""
    const popupPromise = page.waitForEvent('popup');
    await page.getByRole('button').click(); // Click triggers a popup.
    const popup = await popupPromise;
    await popup.waitForLoadState('domcontentloaded'); // Wait for the 'DOMContentLoaded' event.
    console.log(await popup.title()); // Popup is ready to use.
    """,
    html: ~s{<button onclick="window.open('/popup')">Open</button>} do
    popup_promise = Page.wait_for_event(page, :popup)
    # Click triggers a popup.
    Page.get_by_role(page, :button) |> Locator.click!()
    popup = Promise.await!(popup_promise)
    # Wait for the "DOMContentLoaded" event.
    Page.wait_for_load_state!(popup, :domcontentloaded)
    # Popup is ready to use.
    IO.puts(Page.title!(popup))
  end

  example "Page.waitForRequest",
    js: ~S"""
    // Start waiting for request before clicking. Note no await.
    const requestPromise = page.waitForRequest('https://example.com/resource');
    await page.getByText('trigger request').click();
    const request = await requestPromise;

    // Alternative way with a predicate. Note no await.
    const requestPromise = page.waitForRequest(request =>
      request.url() === 'https://example.com' && request.method() === 'GET',
    );
    await page.getByText('trigger request').click();
    const request = await requestPromise;
    """,
    html: ~s{<button onclick="fetch('/resource'); fetch('/')">trigger request</button>} do
    # Start waiting for request before clicking: a promise, awaited after.
    request_promise = Page.wait_for_request(page, "https://example.com/resource")
    Page.get_by_text(page, "trigger request") |> Locator.click!()
    first_request = Promise.await!(request_promise)

    # Alternative way with a predicate.
    request_promise =
      Page.wait_for_request(page, fn request ->
        Request.url(request) == "https://example.com/" and Request.method(request) == "GET"
      end)

    Page.get_by_text(page, "trigger request") |> Locator.click!()
    second_request = Promise.await!(request_promise)
  end

  example "Page.waitForResponse",
    js: ~S"""
    // Start waiting for response before clicking. Note no await.
    const responsePromise = page.waitForResponse('https://example.com/resource');
    await page.getByText('trigger response').click();
    const response = await responsePromise;

    // Alternative way with a predicate. Note no await.
    const responsePromise = page.waitForResponse(response =>
      response.url() === 'https://example.com' && response.status() === 200
          && response.request().method() === 'GET'
    );
    await page.getByText('trigger response').click();
    const response = await responsePromise;
    """,
    html: ~s{<button onclick="fetch('/resource'); fetch('/')">trigger response</button>} do
    # Start waiting for response before clicking: a promise, awaited after.
    response_promise = Page.wait_for_response(page, "https://example.com/resource")
    Page.get_by_text(page, "trigger response") |> Locator.click!()
    first_response = Promise.await!(response_promise)

    # Alternative way with a predicate.
    response_promise =
      Page.wait_for_response(page, fn response ->
        Response.url(response) == "https://example.com/" and Response.status(response) == 200 and
          Request.method(Response.request(response)) == "GET"
      end)

    Page.get_by_text(page, "trigger response") |> Locator.click!()
    second_response = Promise.await!(response_promise)
  end

  example "Page.waitForSelector",
    js: ~S"""
    const { chromium } = require('playwright');  // Or 'firefox' or 'webkit'.

    (async () => {
      const browser = await chromium.launch();
      const page = await browser.newPage();
      for (const currentURL of ['https://google.com', 'https://bbc.com']) {
        await page.goto(currentURL);
        const element = await page.waitForSelector('img');
        console.log('Loaded image: ' + await element.getAttribute('src'));
      }
      await browser.close();
    })();
    """,
    skip: "#{@own_browser}, navigates it: not offline" do
    # Or Playwright.firefox/1 or Playwright.webkit/1.
    browser = Playwright.chromium(playwright) |> BrowserType.launch!()
    page = Browser.new_page!(browser)

    for current_url <- ["https://google.com", "https://bbc.com"] do
      Page.goto!(page, current_url)
      element = Page.wait_for_selector!(page, "img")
      IO.puts("Loaded image: " <> ElementHandle.get_attribute!(element, "src"))
    end

    Browser.close!(browser)
  end

  example "Page.waitForTimeout",
    js: ~S"""
    // wait for 1 second
    await page.waitForTimeout(1000);
    """ do
    # wait for 1 second
    Page.wait_for_timeout!(page, 1000)
  end

  example "Page.waitForURL",
    js: ~S"""
    await page.click('a.delayed-navigation'); // Clicking the link will indirectly cause a navigation
    await page.waitForURL('**/target.html');
    """,
    html:
      ~s{<a class="delayed-navigation" href="#" onclick="setTimeout(() => location.href = '/target.html', 100)">Go</a>} do
    # Clicking the link will indirectly cause a navigation
    Page.click!(page, "a.delayed-navigation")
    Page.wait_for_url!(page, "**/target.html")
  end

  example "Page.webmcp",
    js: ~S"""
    const tools = await page.webmcp.tools();
    const result = await page.webmcp.callTool('add', { a: 2, b: 40 });
    """,
    skip: "needs a browser launched with WebMCP enabled and a page that registers the tool" do
    tools = Page.webmcp(page) |> WebMCP.tools!()
    result = Page.webmcp(page) |> WebMCP.call_tool!("add", %{a: 2, b: 40})
  end
end
