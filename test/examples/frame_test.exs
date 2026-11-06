defmodule PlaywrightEx.Examples.FrameTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.TestBrowser

  @select """
  <select id="colors" multiple>
    <option value="red">Red</option>
    <option value="green">Green</option>
    <option value="blue">Blue</option>
  </select>
  """

  example "Frame",
    js: ~S"""
    const { firefox } = require('playwright');  // Or 'chromium' or 'webkit'.

    (async () => {
      const browser = await firefox.launch();
      const page = await browser.newPage();
      await page.goto('https://www.google.com/chrome/browser/canary.html');
      dumpFrameTree(page.mainFrame(), '');
      await browser.close();

      function dumpFrameTree(frame, indent) {
        console.log(indent + frame.url());
        for (const child of frame.childFrames())
          dumpFrameTree(child, indent + '  ');
      }
    })();
    """,
    skip: "navigates a browser of its own: not offline" do
    dump_frame_tree = fn dump_frame_tree, frame, indent ->
      IO.puts(indent <> Frame.url(frame))
      for child <- Frame.child_frames(frame), do: dump_frame_tree.(dump_frame_tree, child, indent <> "  ")
    end

    # Or Playwright.chromium/1 or Playwright.webkit/1.
    browser = Playwright.firefox(playwright) |> BrowserType.launch!()
    page = Browser.new_page!(browser)
    Page.goto!(page, "https://www.google.com/chrome/browser/canary.html")
    dump_frame_tree.(dump_frame_tree, Page.main_frame(page), "")
    Browser.close!(browser)
  end

  example "Frame.dispatchEvent",
    js: ~S"""
    await frame.dispatchEvent('button#submit', 'click');
    """,
    html: ~s(<button id="submit">Submit</button>),
    given: [frame: Page.main_frame(page)] do
    Frame.dispatch_event!(frame, "button#submit", "click")
  end

  example "Frame.dispatchEvent",
    js: ~S"""
    // Note you can only create DataTransfer in Chromium and Firefox
    const dataTransfer = await frame.evaluateHandle(() => new DataTransfer());
    await frame.dispatchEvent('#source', 'dragstart', { dataTransfer });
    """,
    html: ~s(<div id="source" draggable="true">Drag me</div>),
    given: [frame: Page.main_frame(page)] do
    # Note you can only create DataTransfer in Chromium and Firefox
    data_transfer = Frame.evaluate_handle!(frame, "() => new DataTransfer()")
    Frame.dispatch_event!(frame, "#source", "dragstart", %{dataTransfer: data_transfer})
  end

  example "Frame.evalOnSelector",
    js: ~S"""
    const searchValue = await frame.$eval('#search', el => el.value);
    const preloadHref = await frame.$eval('link[rel=preload]', el => el.href);
    const html = await frame.$eval('.main-container', (e, suffix) => e.outerHTML + suffix, 'hello');
    """,
    html: """
    <link rel="preload" href="/style.css" as="style">
    <input id="search" value="playwright">
    <div class="main-container">Main</div>
    """,
    given: [frame: Page.main_frame(page)] do
    search_value = Frame.eval_on_selector!(frame, "#search", "el => el.value")
    preload_href = Frame.eval_on_selector!(frame, "link[rel=preload]", "el => el.href")
    html = Frame.eval_on_selector!(frame, ".main-container", "(e, suffix) => e.outerHTML + suffix", "hello")
  end

  example "Frame.evalOnSelectorAll",
    js: ~S"""
    const divsCounts = await frame.$$eval('div', (divs, min) => divs.length >= min, 10);
    """,
    html: "<div>one</div><div>two</div>",
    given: [frame: Page.main_frame(page)] do
    divs_counts = Frame.eval_on_selector_all!(frame, "div", "(divs, min) => divs.length >= min", 10)
  end

  example "Frame.evaluate",
    js: ~S"""
    const result = await frame.evaluate(([x, y]) => {
      return Promise.resolve(x * y);
    }, [7, 8]);
    console.log(result); // prints "56"
    """,
    given: [frame: Page.main_frame(page)] do
    result = Frame.evaluate!(frame, "([x, y]) => Promise.resolve(x * y)", [7, 8])
    # prints "56"
    IO.puts(result)
  end

  example "Frame.evaluate",
    js: ~S"""
    console.log(await frame.evaluate('1 + 2')); // prints "3"
    """,
    given: [frame: Page.main_frame(page)] do
    # prints "3"
    IO.puts(Frame.evaluate!(frame, "1 + 2"))
  end

  example "Frame.evaluate",
    js: ~S"""
    const bodyHandle = await frame.evaluateHandle('document.body');
    const html = await frame.evaluate(([body, suffix]) =>
      body.innerHTML + suffix, [bodyHandle, 'hello'],
    );
    await bodyHandle.dispose();
    """,
    given: [frame: Page.main_frame(page)] do
    body_handle = Frame.evaluate_handle!(frame, "document.body")
    html = Frame.evaluate!(frame, "([body, suffix]) => body.innerHTML + suffix", [body_handle, "hello"])
    JSHandle.dispose!(body_handle)
  end

  example "Frame.evaluateHandle",
    js: ~S"""
    // Handle for the window object
    const aWindowHandle = await frame.evaluateHandle(() => Promise.resolve(window));
    """,
    given: [frame: Page.main_frame(page)] do
    # Handle for the window object
    a_window_handle = Frame.evaluate_handle!(frame, "() => Promise.resolve(window)")
  end

  example "Frame.evaluateHandle",
    js: ~S"""
    const aHandle = await frame.evaluateHandle('document'); // Handle for the 'document'.
    """,
    given: [frame: Page.main_frame(page)] do
    # Handle for the 'document'.
    a_handle = Frame.evaluate_handle!(frame, "document")
  end

  example "Frame.evaluateHandle",
    js: ~S"""
    const aHandle = await frame.evaluateHandle(() => document.body);
    const resultHandle = await frame.evaluateHandle(([body, suffix]) =>
      body.innerHTML + suffix, [aHandle, 'hello'],
    );
    console.log(await resultHandle.jsonValue());
    await resultHandle.dispose();
    """,
    given: [frame: Page.main_frame(page)] do
    a_handle = Frame.evaluate_handle!(frame, "() => document.body")
    result_handle = Frame.evaluate_handle!(frame, "([body, suffix]) => body.innerHTML + suffix", [a_handle, "hello"])
    IO.puts(JSHandle.json_value!(result_handle))
    JSHandle.dispose!(result_handle)
  end

  example "Frame.frameElement",
    js: ~S"""
    const frameElement = await frame.frameElement();
    const contentFrame = await frameElement.contentFrame();
    console.log(frame === contentFrame);  // -> true
    """,
    html: ~s(<iframe srcdoc="<p>Hello</p>"></iframe>),
    given: [frame: Page.main_frame(page) |> Frame.child_frames() |> hd()] do
    frame_element = Frame.frame_element!(frame)
    content_frame = ElementHandle.content_frame!(frame_element)
    # -> true
    IO.puts(frame == content_frame)
  end

  example "Frame.frameLocator",
    js: ~S"""
    const locator = frame.frameLocator('#my-iframe').getByText('Submit');
    await locator.click();
    """,
    html: ~s(<iframe id="my-iframe" srcdoc="<button>Submit</button>"></iframe>),
    given: [frame: Page.main_frame(page)] do
    locator = Frame.frame_locator(frame, "#my-iframe") |> FrameLocator.get_by_text("Submit")
    Locator.click!(locator)
  end

  example "Frame.frameLocator",
    js: ~S"""
    const locator = frame.frameLocator().getByRole('button');
    await locator.click();
    """,
    html: ~s(<iframe srcdoc="<button>Submit</button>"></iframe>),
    given: [frame: Page.main_frame(page)] do
    locator = Frame.frame_locator(frame) |> FrameLocator.get_by_role(:button)
    Locator.click!(locator)
  end

  example "Frame.selectOption",
    js: ~S"""
    // Single selection matching the value or label
    frame.selectOption('select#colors', 'blue');

    // single selection matching both the value and the label
    frame.selectOption('select#colors', { label: 'Blue' });

    // multiple selection
    frame.selectOption('select#colors', 'red', 'green', 'blue');
    """,
    html: @select,
    given: [frame: Page.main_frame(page)] do
    # Single selection matching the value or label
    Frame.select_option!(frame, "select#colors", "blue")

    # single selection matching both the value and the label
    Frame.select_option!(frame, "select#colors", %{label: "Blue"})

    # multiple selection
    Frame.select_option!(frame, "select#colors", ["red", "green", "blue"])
  end

  example "Frame.waitForFunction",
    js: ~S"""
    const { firefox } = require('playwright');  // Or 'chromium' or 'webkit'.

    (async () => {
      const browser = await firefox.launch();
      const page = await browser.newPage();
      const watchDog = page.mainFrame().waitForFunction('window.innerWidth < 100');
      await page.setViewportSize({ width: 50, height: 50 });
      await watchDog;
      await browser.close();
    })();
    """,
    skip: TestBrowser.name() != "firefox" && "launches Firefox: runs with BROWSER=firefox" do
    # Or Playwright.chromium/1 or Playwright.webkit/1.
    browser = Playwright.firefox(playwright) |> BrowserType.launch!()
    page = Browser.new_page!(browser)
    watch_dog = Task.async(fn -> Page.main_frame(page) |> Frame.wait_for_function!("window.innerWidth < 100") end)
    Page.set_viewport_size!(page, %{width: 50, height: 50})
    Task.await(watch_dog)
    Browser.close!(browser)
  end

  example "Frame.waitForFunction",
    js: ~S"""
    const selector = '.foo';
    await frame.waitForFunction(selector => !!document.querySelector(selector), selector);
    """,
    html: ~s(<div class="foo"></div>),
    given: [frame: Page.main_frame(page)] do
    selector = ".foo"
    Frame.wait_for_function!(frame, "selector => !!document.querySelector(selector)", selector)
  end

  example "Frame.waitForLoadState",
    js: ~S"""
    await frame.click('button'); // Click triggers navigation.
    await frame.waitForLoadState(); // Waits for 'load' state by default.
    """,
    html: ~s{<button onclick="location.href = '/next'">Next</button>},
    given: [frame: Page.main_frame(page)] do
    # Click triggers navigation.
    Frame.click!(frame, "button")
    # Waits for 'load' state by default.
    Frame.wait_for_load_state!(frame)
  end

  example "Frame.waitForSelector",
    js: ~S"""
    const { chromium } = require('playwright');  // Or 'firefox' or 'webkit'.

    (async () => {
      const browser = await chromium.launch();
      const page = await browser.newPage();
      for (const currentURL of ['https://google.com', 'https://bbc.com']) {
        await page.goto(currentURL);
        const element = await page.mainFrame().waitForSelector('img');
        console.log('Loaded image: ' + await element.getAttribute('src'));
      }
      await browser.close();
    })();
    """,
    skip: "navigates a browser of its own: not offline" do
    # Or Playwright.firefox/1 or Playwright.webkit/1.
    browser = Playwright.chromium(playwright) |> BrowserType.launch!()
    page = Browser.new_page!(browser)

    for current_url <- ["https://google.com", "https://bbc.com"] do
      Page.goto!(page, current_url)
      element = Page.main_frame(page) |> Frame.wait_for_selector!("img")
      IO.puts("Loaded image: " <> ElementHandle.get_attribute!(element, "src"))
    end

    Browser.close!(browser)
  end

  example "Frame.waitForURL",
    js: ~S"""
    await frame.click('a.delayed-navigation'); // Clicking the link will indirectly cause a navigation
    await frame.waitForURL('**/target.html');
    """,
    html: ~s{<a class="delayed-navigation" onclick="setTimeout(() => location.href = '/target.html', 100)">Go</a>},
    given: [frame: Page.main_frame(page)] do
    # Clicking the link will indirectly cause a navigation
    Frame.click!(frame, "a.delayed-navigation")
    Frame.wait_for_url!(frame, "**/target.html")
  end
end
