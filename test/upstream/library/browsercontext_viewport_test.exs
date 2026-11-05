defmodule PlaywrightEx.Library.BrowsercontextViewportTest do
  @upstream "tests/library/browsercontext-viewport.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import PlaywrightEx.Utils, only: [verify_viewport: 3]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright

  @moduletag :page

  test "should get the proper default viewport size", %{page: page} do
    verify_viewport(page, 1280, 720)
  end

  test "should set the proper viewport size", %{page: page} do
    verify_viewport(page, 1280, 720)
    Page.set_viewport_size!(page, %{width: 345, height: 456})
    verify_viewport(page, 345, 456)
  end

  test "should return correct outerWidth and outerHeight", %{page: page} do
    Page.set_viewport_size!(page, %{width: 410, height: 420})

    size =
      Page.evaluate!(page, """
      () => {
        return {
          innerWidth: window.innerWidth,
          innerHeight: window.innerHeight,
          outerWidth: window.outerWidth,
          outerHeight: window.outerHeight,
        };
      }
      """)

    assert size["innerWidth"] == 410
    assert size["innerHeight"] == 420
    assert size["outerWidth"] >= size["innerWidth"]
    assert size["outerHeight"] >= size["innerHeight"]
  end

  # deviceDescriptors (server-side registry): the same descriptors as `playwright.devices`.
  test "landscape viewport should have width larger than height", %{playwright: playwright} do
    for {device, configuration} <- Playwright.devices(playwright) do
      if String.contains?(device, "landscape") or String.contains?(device, "Landscape"),
        do: assert(configuration.viewport.width > configuration.viewport.height)
    end
  end

  test "should emulate device width", %{page: page} do
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
    Page.set_viewport_size!(page, %{width: 300, height: 300})
    assert Page.evaluate!(page, "() => window.screen.width") == 300
    assert Page.evaluate!(page, "() => matchMedia('(min-device-width: 200px)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(min-device-width: 400px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(max-device-width: 200px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(max-device-width: 400px)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(device-width: 600px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(device-width: 300px)').matches") == true
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    assert Page.evaluate!(page, "() => window.screen.width") == 500
    assert Page.evaluate!(page, "() => matchMedia('(min-device-width: 400px)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(min-device-width: 600px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(max-device-width: 400px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(max-device-width: 600px)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(device-width: 200px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(device-width: 500px)').matches") == true
  end

  test "should emulate device height", %{page: page} do
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
    Page.set_viewport_size!(page, %{width: 300, height: 300})
    assert Page.evaluate!(page, "() => window.screen.height") == 300
    assert Page.evaluate!(page, "() => matchMedia('(min-device-height: 200px)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(min-device-height: 400px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(max-device-height: 200px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(max-device-height: 400px)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(device-height: 600px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(device-height: 300px)').matches") == true
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    assert Page.evaluate!(page, "() => window.screen.height") == 500
    assert Page.evaluate!(page, "() => matchMedia('(min-device-height: 400px)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(min-device-height: 600px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(max-device-height: 400px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(max-device-height: 600px)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(device-height: 200px)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(device-height: 500px)').matches") == true
  end

  test "should emulate availWidth and availHeight", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 600})
    assert Page.evaluate!(page, "() => window.screen.availWidth") == 500
    assert Page.evaluate!(page, "() => window.screen.availHeight") == 600
  end

  test "should not have touch by default", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/mobile.html")
    assert Page.evaluate!(page, "() => 'ontouchstart' in window") == false
  end

  test "should throw on tap if hasTouch is not enabled", %{page: page} do
    Page.set_content!(page, "<div>a</div>")

    {:error, error} = Page.tap(page, "div")
    assert error
    assert Exception.message(error) =~ "The page does not support tap"

    {:error, error} = page |> Page.locator("div") |> Locator.tap()
    assert error
    assert Exception.message(error) =~ "The page does not support tap"
  end

  test "should support touch with null viewport", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: :null, has_touch: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/mobile.html")
    assert Page.evaluate!(page, "() => 'ontouchstart' in window") == true
    BrowserContext.close!(context)
  end

  test "should keep touch emulation after screenshot beyond viewport", %{browser: browser, server: server} do
    # browserTest.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42607' });
    context = Browser.new_context!(browser, viewport: %{width: 393, height: 727}, has_touch: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<div id="tall" style="height:3000px">tall</div>))

    probe = fn ->
      Page.evaluate!(page, """
      () => ({
        ontouchstart: 'ontouchstart' in window,
        maxTouchPoints: navigator.maxTouchPoints,
        coarse: matchMedia('(pointer: coarse)').matches,
      })
      """)
    end

    expected = probe.()
    assert expected["ontouchstart"] == true
    Page.screenshot!(page, full_page: true)
    assert probe.() == expected
    page |> Page.locator("#tall") |> Locator.screenshot!()
    assert probe.() == expected
    Page.goto!(page, server.empty_page)
    assert probe.() == expected
    BrowserContext.close!(context)
  end

  test "should set both screen and viewport options", %{context_factory: context_factory} do
    context =
      context_factory.(
        screen: %{width: 1280, height: 720},
        viewport: %{width: 1000, height: 600}
      )

    page = BrowserContext.new_page!(context)
    screen = Page.evaluate!(page, "() => ({ w: screen.width, h: screen.height })")
    assert screen == %{"w" => 1280, "h" => 720}
    inner = Page.evaluate!(page, "() => ({ w: window.innerWidth, h: window.innerHeight })")
    assert inner == %{"w" => 1000, "h" => 600}
  end

  test "should report null viewportSize when given null viewport", %{browser: browser} do
    context = Browser.new_context!(browser, viewport: :null)
    page = BrowserContext.new_page!(context)
    assert Page.viewport_size(page) == nil
    BrowserContext.close!(context)
  end

  test "should drag with high dpi", %{browser: browser, server: server} do
    # browserTest.skip(!headless, 'Stray mouse events mess up the test');  -- we run headless

    page = Browser.new_page!(browser, device_scale_factor: 2)
    Page.goto!(page, server.prefix <> "/drag-n-drop.html")
    Page.hover!(page, "#source")
    Mouse.down!(Page.mouse(page))
    Page.hover!(page, "#target")
    Mouse.up!(Page.mouse(page))

    # could not find source in target
    assert Page.eval_on_selector!(page, "#target", "target => target.contains(document.querySelector('#source'))") ==
             true

    Page.close!(page)
  end

  # it.skip(browserName !== 'webkit' || headless || !isWindows, 'Not relevant for this browser');
  @tag skip:
         if(@browser_name != "webkit" or PlaywrightEx.TestBrowser.headless() or !match?({:win32, _}, :os.type()),
           do: "upstream skip: Not relevant for this browser (webkit headed on Windows only)"
         )
  test "WebKit Windows headed should have a minimal viewport", %{browser: browser, context_factory: context_factory} do
    {:error, error} = Browser.new_context(browser, viewport: %{width: 100, height: 100})
    assert error.message =~ "WebKit on Windows has a minimal viewport of 250x240."

    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    {:error, error} = Page.set_viewport_size(page, %{width: 100, height: 100})
    assert error.message =~ "WebKit on Windows has a minimal viewport of 250x240."
    BrowserContext.close!(context)
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream skip: Desktop webkit dont support orientation API")
  test "should be able to get correct orientation angle on non-mobile devices", %{
    browser: browser,
    server: server
  } do
    # browserTest.skip(browserName === 'webkit', 'Desktop webkit dont support orientation API');
    context = Browser.new_context!(browser, viewport: %{width: 300, height: 400}, is_mobile: false)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/index.html")
    assert Page.evaluate!(page, "() => window.screen.orientation.angle") == 0
    Page.set_viewport_size!(page, %{width: 400, height: 300})
    assert Page.evaluate!(page, "() => window.screen.orientation.angle") == 0
    BrowserContext.close!(context)
  end

  test "should set window.screen.orientation.type for mobile devices", %{
    context_factory: context_factory,
    server: server,
    playwright: playwright
  } do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/31151' });
    context = context_factory.(Map.to_list(Playwright.devices(playwright)["iPhone 14"]))
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/index.html")
    assert Page.evaluate!(page, "() => window.screen.orientation.type") == "portrait-primary"
    BrowserContext.close!(context)
  end
end
