defmodule PlaywrightEx.Library.BrowsercontextDeviceTest do
  @upstream "tests/library/browsercontext-device.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright

  @lorem "Lorem ipsum dolor sit amet consectetur adipiscing elit proin, integer curabitur imperdiet rhoncus cursus tincidunt bibendum, consequat sed magnis laoreet luctus mollis tellus. Nisl parturient mus accumsan feugiat sem laoreet magnis nisi, aptent per sollicitudin gravida orci ac blandit, viverra eros praesent auctor vivamus semper bibendum. Consequat sed habitasse luctus dictumst gravida platea semper phasellus, nascetur ridiculus purus est varius quisque et scelerisque, id vehicula eleifend montes sollicitudin dis velit. Pellentesque ridiculus per natoque et eleifend taciti nunc, laoreet auctor at condimentum imperdiet ante, conubia mi cubilia scelerisque sociosqu sem.</p> <p>Curabitur magna per felis primis mauris non dapibus luctus ultricies eros, quis et egestas condimentum lobortis eget semper montes litora purus, ridiculus elementum sollicitudin imperdiet dictum lacinia parturient cras eu. Risus cum varius rhoncus eros torquent pretium taciti id erat dis egestas, nibh tristique montes convallis metus lacus phasellus blandit ut auctor bibendum semper, facilisis mi integer eget ultrices lobortis odio viverra duis dui. Risus ullamcorper lacinia in venenatis sodales fusce tortor potenti volutpat quis, dictum vulputate suspendisse velit mollis torquent sociis aptent morbi, senectus nascetur justo maecenas conubia magnis viverra gravida fames. Phasellus sed nec gravida nibh class augue lectus, blandit quis turpis orci diam nam pellentesque, ultricies metus imperdiet hendrerit lacinia lacus.</p> <p>Inceptos facilisi montes cum hendrerit, pulvinar ut tellus eget velit, arcu nulla aenean. Phasellus augue urna nostra molestie interdum vehicula, posuere fames cum euismod massa curabitur donec, inceptos cubilia tellus facilisis fermentum. Lacus laoreet facilisis ultrices cursus quisque at ad porta vestibulum massa inceptos, curae class aliquet maecenas cum ullamcorper pulvinar erat mus vitae. Cum in aenean convallis dis quam tincidunt justo sed quisque, imperdiet faucibus hendrerit felis commodo scelerisque magnis vehicula etiam leo, eros varius platea lobortis maecenas condimentum nisi phasellus. Turpis vulputate mus himenaeos sociosqu facilisis dignissim leo quam, ultricies habitasse commodo molestie est tortor vitae et, porttitor risus erat cursus phasellus facilisi litora.</p> <p>Nostra habitasse egestas magnis velit pellentesque parturient cum lectus viverra, vestibulum sociosqu nunc vel urna consequat lacinia phasellus at sapien, aenean pretium dictum sed montes interdum imperdiet iaculis. Leo hac eros arcu senectus maecenas, tortor pulvinar venenatis lacinia volutpat, mattis platea ut facilisi. Aenean condimentum at et donec sociosqu fermentum luctus potenti semper vulputate, sapien justo non est auctor gravida ultricies fames per commodo, sed habitasse facilisi nulla quisque hendrerit aliquet viverra bibendum.</p> <p>Interdum nisl quam etiam montes porttitor laoreet nullam senectus velit, mauris proin tellus imperdiet litora venenatis fames massa quis, sollicitudin justo vivamus curae in sociis suscipit facilisi. Platea inceptos lacus elementum pellentesque quam euismod dictumst sociis tincidunt vulputate porttitor eros, turpis netus ut ad tempor sapien aliquet sodales molestie consequat nostra. Cum augue in quisque primis ut nunc sodales, sem orci tempus posuere cubilia suspendisse lacinia ligula, magna sed ridiculus at maecenas habitant.</p> <p>Natoque magna ac feugiat tellus bibendum diam, metus lobortis nisl ornare varius praesent, dictumst gravida lacus parturient semper. Pellentesque faucibus congue fusce posuere placerat dictum vitae, dui vestibulum eu sociis tempus aliquam ultricies malesuada, potenti laoreet lacus sem gravida nisi. Nostra platea sagittis hendrerit congue conubia senectus bibendum quis sapien pharetra, scelerisque nam imperdiet fermentum feugiat suspendisse viverra luctus at, semper ac consequat vitae mi gravida parturient mollis nascetur. Vel taciti justo consequat primis et blandit convallis sed, felis purus fusce a venenatis etiam aenean scelerisque, fringilla volutpat sagittis egestas rutrum id dis.</p> <p>Feugiat fermentum tortor ante ac iaculis sollicitudin ut interdum, cras orci ullamcorper potenti tristique vehicula. Molestie tortor ullamcorper rutrum turpis malesuada phasellus sem ultricies praesent mattis lobortis porta, senectus venenatis diam nostra laoreet volutpat per aptent justo elementum cum. Urna cursus vel felis cras eleifend arcu enim magnis, duis rutrum nibh nascetur cubilia interdum ultrices curae, id lacus aliquam dictumst diam fringilla lacinia.</p> <p>Luctus diam morbi eget tellus libero taciti faucibus inceptos, natoque facilisis lectus maecenas risus dapibus suscipit nibh, vel curae conubia orci imperdiet metus fusce. Condimentum massa donec luctus pharetra cum, in viverra placerat nisl litora facilisis, neque nascetur sociis dictumst. Suscipit accumsan eget rhoncus pharetra justo malesuada aliquet, suspendisse metus eleifend tincidunt varius ridiculus, convallis primis vitae curabitur quis mus.</p> <p>Gravida donec lacus molestie tortor aenean ultricies blandit per tempor, nostra penatibus orci vestibulum semper lectus vel a, montes potenti cum dapibus natoque eu volutpat nulla. Himenaeos purus nam malesuada habitasse nisl pharetra laoreet feugiat mi non, ultrices ultricies a cras ante eu venenatis ligula. Suscipit ut mus habitasse at aliquet sodales commodo justo, feugiat platea sagittis phasellus eleifend pellentesque interdum iaculis, integer cubilia montes metus hendrerit tincidunt purus.</p> <p>Vel posuere tellus dapibus eget duis cubilia, nec class vehicula libero gravida ligula, tempus urna taciti donec congue. Facilisis ridiculus congue cum dui per augue natoque, molestie hac etiam pellentesque dignissim urna class, feugiat aenean massa himenaeos penatibus ut eu, convallis purus et fusce tempus mattis. At mattis suscipit porta nostra nec facilisis sodales turpis, integer et lectus conubia justo nam congue taciti odio, fermentum semper cubilia fusce nunc purus velit."

  # `browser.newContext({ ...device })`
  @device_bug "bug: Playwright.devices: descriptors use JS keys (:userAgent, :deviceScaleFactor, :isMobile, :hasTouch, :defaultBrowserType) that Browser.new_context rejects as unknown options; JS spreads them into newContext"

  describe "device" do
    # it.skip(({ browserName, isBidi }) => browserName === 'firefox' && !isBidi): we run Juggler Firefox.
    @describetag skip: if(System.get_env("BROWSER") == "firefox", do: "firefox")

    @tag skip: @device_bug
    test "should work @smoke", %{playwright: playwright, browser: browser, server: server} do
      iphone = Playwright.devices(playwright)["iPhone 6"]
      context = Browser.new_context!(browser, iphone)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/mobile.html")
      assert Page.evaluate!(page, "() => window.innerWidth") == 375
      assert Page.evaluate!(page, "() => navigator.userAgent") =~ "iPhone"
      BrowserContext.close!(context)
    end

    @tag skip: @device_bug
    test "should support clicking", %{playwright: playwright, browser: browser, server: server} do
      iphone = Playwright.devices(playwright)["iPhone 6"]
      context = Browser.new_context!(browser, iphone)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/input/button.html")
      button = Page.query_selector!(page, "button")
      Page.evaluate!(page, "button => button.style.marginTop = '200px'", button)
      ElementHandle.click!(button)
      assert Page.evaluate!(page, "result") == "Clicked"
      BrowserContext.close!(context)
    end

    test "should scroll to click", %{browser: browser, server: server} do
      context =
        Browser.new_context!(browser,
          viewport: %{width: 400, height: 400},
          device_scale_factor: 1,
          is_mobile: true
        )

      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/input/scrollable.html")
      element = Page.query_selector!(page, "#button-91")
      ElementHandle.click!(element)
      assert ElementHandle.text_content!(element) == "clicked"
      BrowserContext.close!(context)
    end

    @tag skip: @device_bug
    test "should scroll twice when emulated", %{context_factory: context_factory, playwright: playwright} do
      device = Playwright.devices(playwright)["iPhone 6"]
      context = context_factory.(device)
      page = BrowserContext.new_page!(context)

      Page.set_content!(page, """
            <meta name="viewport" content="width=device-width, user-scalable=no" />
            #{@lorem}
            <button>hi</button>
      """)

      Page.evaluate!(page, "() => window.scroll(0, 100)")
      assert Page.evaluate!(page, "() => window.scrollY") == 100

      Page.evaluate!(page, "() => window.scroll(0, 200)")
      assert Page.evaluate!(page, "() => window.scrollY") == 200

      BrowserContext.close!(context)
    end

    @tag skip: @device_bug
    test "should reset scroll top after a navigation", %{
      server: server,
      context_factory: context_factory,
      playwright: playwright,
      browser_name: browser_name
    } do
      # it.skip(browserName === 'webkit')
      if browser_name != "webkit" do
        device = Playwright.devices(playwright)["iPhone 6"]
        context = context_factory.(device)
        page = BrowserContext.new_page!(context)
        Page.goto!(page, server.prefix <> "/input/scrollable.html")
        Page.evaluate!(page, "() => window.scroll(0, 100)")

        Page.goto!(page, server.prefix <> "/input/scrollable2.html")
        assert Page.evaluate!(page, "() => window.scrollY") == 0
        BrowserContext.close!(context)
      end
    end

    @tag skip: @device_bug
    test "should scroll to a precise position with mobile scale", %{
      server: server,
      context_factory: context_factory,
      playwright: playwright,
      browser_name: browser_name
    } do
      # it.skip(browserName === 'webkit')
      if browser_name != "webkit" do
        device = Playwright.devices(playwright)["iPhone 6"]
        context = context_factory.(device)
        page = BrowserContext.new_page!(context)
        Page.goto!(page, server.prefix <> "/input/scrollable.html")
        assert Page.evaluate!(page, "() => document.body.scrollHeight") > 1000
        Page.evaluate!(page, "() => window.scroll(0, 100)")
        assert Page.evaluate!(page, "() => window.scrollY") == 100
        BrowserContext.close!(context)
      end
    end

    @tag skip: @device_bug
    test "should emulate viewport and screen size", %{context_factory: context_factory, playwright: playwright} do
      device = Playwright.devices(playwright)["iPhone 12"]
      context = context_factory.(device)
      page = BrowserContext.new_page!(context)
      Page.set_content!(page, ~s(<meta name="viewport" content="width=device-width, user-scalable=no" />))

      assert Page.evaluate!(page, """
             () => ({
               width: window.screen.width,
               height: window.screen.height
             })
             """) == %{"width" => 390, "height" => 844}

      assert Page.evaluate!(page, """
             () => ({
               width: window.innerWidth,
               height: window.innerHeight
             })
             """) == %{"width" => 390, "height" => 664}

      BrowserContext.close!(context)
    end

    @tag skip: @device_bug
    test "should emulate viewport without screen size", %{context_factory: context_factory, playwright: playwright} do
      device = Playwright.devices(playwright)["iPhone 6"]
      context = context_factory.(device)
      page = BrowserContext.new_page!(context)
      Page.set_content!(page, ~s(<meta name="viewport" content="width=device-width, user-scalable=no" />))

      assert Page.evaluate!(page, """
             () => ({
               width: window.screen.width,
               height: window.screen.height
             })
             """) == %{"width" => 375, "height" => 667}

      assert Page.evaluate!(page, """
             () => ({
               width: window.innerWidth,
               height: window.innerHeight
             })
             """) == %{"width" => 375, "height" => 667}

      BrowserContext.close!(context)
    end
  end
end
