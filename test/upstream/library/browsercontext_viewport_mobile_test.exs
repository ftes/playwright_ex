defmodule PlaywrightEx.Library.BrowsercontextViewportMobileTest do
  @upstream "tests/library/browsercontext-viewport-mobile.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Route

  describe "mobile viewport" do
    # it.skip(({ browserName, isBidi }) => browserName === 'firefox' && !isBidi)
    if System.get_env("BROWSER", "chromium") == "firefox", do: @describetag(skip: "upstream skip: firefox (non-BiDi)")

    test "should support mobile emulation", %{playwright: playwright, browser: browser, server: server} do
      iphone = Playwright.devices(playwright)["iPhone 6"]
      context = Browser.new_context!(browser, iphone)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => window.innerWidth") == 375
      Page.set_viewport_size!(page, %{width: 400, height: 300})
      assert Page.evaluate!(page, "() => window.innerWidth") == 400
      BrowserContext.close!(context)
    end

    test "should support touch emulation", %{playwright: playwright, browser: browser, server: server} do
      iphone = Playwright.devices(playwright)["iPhone 6"]
      context = Browser.new_context!(browser, iphone)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => 'ontouchstart' in window") == true

      dispatch_touch = """
      function dispatchTouch() {
        let fulfill;
        const promise = new Promise(x => fulfill = x);
        window.ontouchstart = function(e) {
          fulfill('Received touch');
        };
        window.dispatchEvent(new Event('touchstart'));

        fulfill('Did not receive touch');

        return promise;
      }
      """

      assert Page.evaluate!(page, dispatch_touch) == "Received touch"
      BrowserContext.close!(context)
    end

    test "should be detectable", %{playwright: playwright, browser: browser} do
      iphone = Playwright.devices(playwright)["iPhone 6"]
      context = Browser.new_context!(browser, iphone)
      page = BrowserContext.new_page!(context)
      assert Page.evaluate!(page, "() => 'ontouchstart' in window || !!window.TouchEvent") == true
      BrowserContext.close!(context)
    end

    test "should detect touch when applying viewport with touches", %{browser: browser, server: server} do
      context = Browser.new_context!(browser, viewport: %{width: 800, height: 600}, has_touch: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      assert Page.evaluate!(page, "() => 'ontouchstart' in window || !!window.TouchEvent") == true
      BrowserContext.close!(context)
    end

    test "should support landscape emulation", %{playwright: playwright, browser: browser, server: server} do
      iphone = Playwright.devices(playwright)["iPhone 6"]
      iphone_landscape = Playwright.devices(playwright)["iPhone 6 landscape"]
      context1 = Browser.new_context!(browser, iphone)
      page1 = BrowserContext.new_page!(context1)
      Page.goto!(page1, server.prefix <> "/mobile.html")
      assert Page.evaluate!(page1, "() => matchMedia('(orientation: landscape)').matches") == false
      context2 = Browser.new_context!(browser, iphone_landscape)
      page2 = BrowserContext.new_page!(context2)
      assert Page.evaluate!(page2, "() => matchMedia('(orientation: landscape)').matches") == true
      BrowserContext.close!(context1)
      BrowserContext.close!(context2)
    end

    test "should support window.orientation emulation", %{browser: browser, server: server} do
      context = Browser.new_context!(browser, viewport: %{width: 300, height: 400}, is_mobile: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => window.orientation") == 0
      Page.set_viewport_size!(page, %{width: 400, height: 300})
      assert Page.evaluate!(page, "() => window.orientation") == 90
      BrowserContext.close!(context)
    end

    test "should preserve window.orientation override after navigation", %{browser: browser, server: server} do
      # it.skip(isFrozenWebkit)  -- no frozen WebKit
      context = Browser.new_context!(browser, viewport: %{width: 400, height: 300}, is_mobile: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => window.orientation") == 90
      Page.goto!(page, server.cross_process_prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => window.orientation") == 90
      BrowserContext.close!(context)
    end

    test "should preserve screen.orientation.type override after navigation", %{browser: browser, server: server} do
      # it.skip(isFrozenWebkit)  -- no frozen WebKit
      context = Browser.new_context!(browser, viewport: %{width: 300, height: 400}, is_mobile: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => window.screen.orientation.type") == "portrait-primary"
      Page.goto!(page, server.cross_process_prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => window.screen.orientation.type") == "portrait-primary"
      BrowserContext.close!(context)
    end

    test "should fire orientationchange event", %{browser: browser, server: server} do
      context = Browser.new_context!(browser, viewport: %{width: 300, height: 400}, is_mobile: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/mobile.html")

      Page.evaluate!(page, """
      () => {
        let counter = 0;
        window.addEventListener('orientationchange', () => console.log(++counter));
      }
      """)

      event1 = Page.wait_for_event(page, :console)
      Page.set_viewport_size!(page, %{width: 400, height: 300})
      assert ConsoleMessage.text(Promise.await!(event1)) == "1"

      event2 = Page.wait_for_event(page, :console)
      Page.set_viewport_size!(page, %{width: 300, height: 400})
      assert ConsoleMessage.text(Promise.await!(event2)) == "2"
      BrowserContext.close!(context)
    end

    test "default mobile viewports to 980 width", %{browser: browser, server: server} do
      context = Browser.new_context!(browser, viewport: %{width: 320, height: 480}, is_mobile: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/empty.html")
      assert Page.evaluate!(page, "() => window.innerWidth") == 980
      BrowserContext.close!(context)
    end

    test "respect meta viewport tag", %{browser: browser, server: server} do
      context = Browser.new_context!(browser, viewport: %{width: 320, height: 480}, is_mobile: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => window.innerWidth") == 320
      BrowserContext.close!(context)
    end

    test "should emulate the hover media feature", %{playwright: playwright, browser: browser} do
      iphone = Playwright.devices(playwright)["iPhone 6"]
      mobilepage = Browser.new_page!(browser, iphone)
      assert Page.evaluate!(mobilepage, "() => matchMedia('(hover: hover)').matches") == false
      assert Page.evaluate!(mobilepage, "() => matchMedia('(hover: none)').matches") == true
      assert Page.evaluate!(mobilepage, "() => matchMedia('(any-hover: hover)').matches") == false
      assert Page.evaluate!(mobilepage, "() => matchMedia('(any-hover: none)').matches") == true
      assert Page.evaluate!(mobilepage, "() => matchMedia('(pointer: coarse)').matches") == true
      assert Page.evaluate!(mobilepage, "() => matchMedia('(pointer: fine)').matches") == false
      assert Page.evaluate!(mobilepage, "() => matchMedia('(any-pointer: coarse)').matches") == true
      assert Page.evaluate!(mobilepage, "() => matchMedia('(any-pointer: fine)').matches") == false
      Page.close!(mobilepage)

      desktop_page = Browser.new_page!(browser)
      assert Page.evaluate!(desktop_page, "() => matchMedia('(hover: none)').matches") == false
      assert Page.evaluate!(desktop_page, "() => matchMedia('(hover: hover)').matches") == true
      assert Page.evaluate!(desktop_page, "() => matchMedia('(any-hover: none)').matches") == false
      assert Page.evaluate!(desktop_page, "() => matchMedia('(any-hover: hover)').matches") == true
      assert Page.evaluate!(desktop_page, "() => matchMedia('(pointer: coarse)').matches") == false
      assert Page.evaluate!(desktop_page, "() => matchMedia('(pointer: fine)').matches") == true
      assert Page.evaluate!(desktop_page, "() => matchMedia('(any-pointer: coarse)').matches") == false
      assert Page.evaluate!(desktop_page, "() => matchMedia('(any-pointer: fine)').matches") == true
      Page.close!(desktop_page)
    end

    test "mouse should work with mobile viewports and cross process navigations", %{browser: browser, server: server} do
      # @see https://crbug.com/929806
      context = Browser.new_context!(browser, viewport: %{width: 360, height: 640}, is_mobile: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      Page.goto!(page, server.cross_process_prefix <> "/mobile.html")

      Page.evaluate!(page, """
      () => {
        document.addEventListener('click', event => {
          window['result'] = { x: event.clientX, y: event.clientY };
        });
      }
      """)

      Mouse.click!(Page.mouse(page), 30, 40)

      assert Page.evaluate!(page, "result") == %{"x" => 30, "y" => 40}
      BrowserContext.close!(context)
    end

    test "should scroll when emulating a mobile viewport", %{
      browser: browser,
      server: server,
      browser_name: browser_name
    } do
      context = Browser.new_context!(browser, viewport: %{width: 1000, height: 600}, is_mobile: true)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/input/scrollable.html")
      Mouse.move!(Page.mouse(page), 50, 60)
      result = Mouse.wheel(Page.mouse(page), 0, 100)

      if browser_name == "webkit" do
        {:error, error} = result
        assert Exception.message(error) =~ "Mouse wheel is not supported in mobile WebKit"
      else
        Page.wait_for_function!(page, "window.scrollY === 100")
      end

      BrowserContext.close!(context)
    end

    test "should scroll mobile page with background-attachment: fixed", %{
      playwright: playwright,
      browser: browser,
      server: server
    } do
      iphone = Playwright.devices(playwright)["iPhone 12"]
      context = Browser.new_context!(browser, iphone)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/input/background-fixed.html")
      Locator.click!(Page.get_by_role(page, "button"))
      assert Page.evaluate!(page, "() => window.scrollY") > 1000
      BrowserContext.close!(context)
    end

    test "view scale should reset after navigation", %{browser: browser} do
      context = Browser.new_context!(browser, viewport: %{width: 390, height: 664}, is_mobile: true)
      page = BrowserContext.new_page!(context)

      Page.goto!(
        page,
        "data:text/html,<meta name='viewport' content='device-width, initial-scale=1'><button>Mobile Viewport</button>"
      )

      Page.route!(page, "**/button.html", fn route ->
        Route.fulfill(route,
          body: """
          <body>
            <button>Click me</button>
            <script>
              window.clicks = [];
              document.addEventListener('click', e => {
                const dot = document.createElement('div');
                dot.style.position = 'absolute';
                dot.style.width = '10px';
                dot.style.height = '10px';
                dot.style.borderRadius = '5px';
                dot.style.backgroundColor = 'red';
                dot.style.left = e.pageX + 'px';
                dot.style.top = e.pageY + 'px';
                dot.textContent = 'x: ' + e.pageX + ' y: ' + e.pageY;
                document.body.appendChild(dot);
                window.clicks.push({ x: e.pageX, y: e.pageY });
              });
            </script>
          </body>
          """,
          content_type: "text/html"
        )
      end)

      Page.goto!(page, "http://localhost/button.html")
      Locator.click!(Page.get_by_text(page, "Click me"), force: true)
      box = Locator.bounding_box!(Page.locator(page, "button"))
      clicks = Page.evaluate!(page, "() => window.clicks")
      assert length(clicks) == 1
      [%{"x" => x, "y" => y}] = clicks
      is_click_inside_button = box.x <= x and x <= box.x + box.width and box.y <= y and y <= box.y + box.height
      assert is_click_inside_button == true
      BrowserContext.close!(context)
    end
  end
end
