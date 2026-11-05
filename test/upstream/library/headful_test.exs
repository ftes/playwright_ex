defmodule PlaywrightEx.Library.HeadfulTest do
  @upstream "tests/library/headful.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.UpstreamSnapshot

  @browser_name System.get_env("BROWSER", "chromium")

  # it.skip(({ headless }) => headless, 'avoid popping windows in headless mode');
  # it.skip(({ channel }) => channel === 'chromium-headless-shell', 'shell is never headed');  -- we run no channel
  @headless_skip if(PlaywrightEx.TestBrowser.headless(),
                   do: "upstream skip: avoid popping windows in headless mode (HEADED=1 runs it)"
                 )
  # Upstream's client too (tmp script on the driver's playwright-core, macOS 26): headed Chromium
  # lays text out taller than the headless shell (normal line height), e.g. 57.5 vs 56 px.
  @macos_chromium_skip if(@browser_name == "chromium" and match?({:unix, :darwin}, :os.type()),
                         do:
                           "env: macOS headed Chromium has taller line boxes than the headless shell (upstream client too)"
                       )
  # A test's own skip tag replaces the module's: tests with one add `@headless_skip ||`.
  @moduletag skip: @headless_skip
  # The tests that only run headed: CI's headed step runs `HEADED=1 mix test --only headful`.
  @moduletag :headful

  test "should have default url when launching browser @smoke", %{launch_persistent: launch_persistent} do
    %{context: context} = launch_persistent.([])
    urls = Enum.map(BrowserContext.pages(context), &Page.url/1)
    assert urls == ["about:blank"]
  end

  @tag timeout: @slow_timeout
  test "should close browser with beforeunload page", %{launch_persistent: launch_persistent, server: server} do
    %{context: context} = launch_persistent.([])
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(page, "body")
    BrowserContext.close!(context)
  end

  @tag :page
  test "should close browsercontext with pending beforeunload dialog", %{server: server, context: context} do
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/beforeunload.html")
    # We have to interact with a page so that 'beforeunload' handlers
    # fire.
    Page.click!(page, "body")
    dialog_promise = Page.wait_for_event(page, :dialog)
    Page.close!(page, run_before_unload: true)
    Promise.await!(dialog_promise)
    BrowserContext.close!(context)
  end

  test "should not crash when creating second context", %{browser: browser} do
    browser_context = Browser.new_context!(browser)
    BrowserContext.new_page!(browser_context)
    BrowserContext.close!(browser_context)

    browser_context = Browser.new_context!(browser)
    BrowserContext.new_page!(browser_context)
    BrowserContext.close!(browser_context)
  end

  @tag :page
  test "should click when viewport size is larger than screen", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/22082' });
    Page.set_viewport_size!(page, %{
      width: 3000,
      height: 3000
    })

    Page.set_content!(page, """
      <style>
        html, body { position: absolute; left: 0; top: 0; right: 0; bottom: 0; }
      </style>
      <button style="position: absolute; right: 0; bottom: 0;">Button in the bottom-right corner</button>
    """)

    Locator.click!(Page.locator(page, "button"))
  end

  @tag :page
  test "should dispatch click events to oversized viewports", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/22082' });
    # Some prime numbers for width/height.
    width = 2971
    height = 3067
    Page.set_viewport_size!(page, %{width: width, height: height})

    Page.evaluate!(page, """
    () => {
      window['events'] = [];
      window.addEventListener('click', event => window['events'].push({ x: event.clientX, y: event.clientY }), false);
    }
    """)

    mouse = Page.mouse(page)

    # Allow a little padding from the edges of viewport.
    expected_events =
      for i <- 3..22 do
        x = width - i
        y = height - i
        Mouse.move!(mouse, x, y)
        Mouse.down!(mouse)
        Mouse.up!(mouse)
        %{"x" => x, "y" => y}
      end

    actual_events = Page.evaluate!(page, "() => window['events']")
    assert expected_events == actual_events
  end

  @tag :page
  test "should click background tab", %{page: page, server: server} do
    Page.set_content!(page, ~s(<button>Hello</button><a target=_blank href="#{server.empty_page}">empty.html</a>))
    Page.click!(page, "a")
    Page.click!(page, "button")
  end

  test "should close browser after context menu was triggered", %{browser_type: browser_type, server: server} do
    browser = BrowserType.launch!(browser_type)
    page = Browser.new_page!(browser)
    Page.goto!(page, server.prefix <> "/grid.html")
    Page.click!(page, "body", button: "right")
    Browser.close!(browser)
  end

  @tag :page
  test "should(not) block third party cookies", %{page: page, server: server, browser_name: browser_name} do
    allows_third_party = allows_third_party(browser_name)
    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      """
      src => {
        let fulfill;
        const promise = new Promise(x => fulfill = x);
        const iframe = document.createElement('iframe');
        document.body.appendChild(iframe);
        iframe.onload = fulfill;
        iframe.src = src;
        return promise;
      }
      """,
      server.cross_process_prefix <> "/grid.html"
    )

    document_cookie =
      Frame.evaluate!(Enum.at(Page.frames(page), 1), """
      () => {
        document.cookie = 'username=John Doe';
        return document.cookie;
      }
      """)

    Page.wait_for_timeout!(page, 2000)
    assert document_cookie == if(allows_third_party, do: "username=John Doe", else: "")
    cookies = BrowserContext.cookies!(Page.context(page), server.cross_process_prefix <> "/grid.html")

    if allows_third_party do
      assert cookies == [
               %{
                 domain: "127.0.0.1",
                 expires: -1,
                 httpOnly: false,
                 name: "username",
                 path: "/",
                 sameSite: default_same_site_cookie_value(browser_name),
                 secure: false,
                 value: "John Doe"
               }
             ]
    else
      assert cookies == []
    end
  end

  @tag skip: @headless_skip || if(@browser_name == "webkit", do: "upstream skip: No third party cookies in WebKit")
  test "should not block third party SameSite=None cookies", %{https_server: https_server, browser: browser} do
    # it.skip(process.env.PW_CLOCK === 'frozen');  -- no PW_CLOCK here
    page = Browser.new_page!(browser, ignore_https_errors: true)

    TestServer.set_route(https_server, "/empty.html", fn conn ->
      html(conn, ~s(<iframe src="#{https_server.cross_process_prefix}/grid.html"></iframe>))
    end)

    TestServer.set_route(https_server, "/grid.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "a=b; Path=/; Max-Age=3600; SameSite=None; Secure")
      |> html("""
      Hello world
          <script>
          setTimeout(() => fetch('/json'), 1000);
          </script>
      """)
    end)

    test = self()

    TestServer.set_route(https_server, "/json", fn conn ->
      send(test, {:cookie, header(conn, "cookie")})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.goto!(page, https_server.empty_page)
    assert_receive {:cookie, cookie}
    assert cookie == "a=b"
    Page.close!(page)
  end

  @tag skip:
         @headless_skip ||
           if(@browser_name == "webkit", do: "upstream skip: Our WebKit embedder does not respect window features")
  test "should not override viewport size when passed null", %{server: server, browser: browser} do
    context = Browser.new_context!(browser, viewport: :null)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    popup_promise = Page.wait_for_event(page, :popup)

    Page.evaluate!(page, """
    () => {
      const win = window.open(window.location.href, 'Title', 'toolbar=no,location=no,directories=no,status=no,menubar=no,scrollbars=yes,resizable=yes,width=600,height=300,top=0,left=0');
      win.resizeTo(500, 450);
    }
    """)

    popup = Promise.await!(popup_promise)
    Page.wait_for_load_state!(popup)
    Page.wait_for_function!(popup, "() => window.outerWidth === 500 && window.outerHeight === 450")
    BrowserContext.close!(context)
  end

  test "Page.bringToFront should work", %{browser: browser} do
    page1 = Browser.new_page!(browser)
    Page.set_content!(page1, "Page1")
    page2 = Browser.new_page!(browser)
    Page.set_content!(page2, "Page2")

    Page.bring_to_front!(page1)
    assert Page.evaluate!(page1, "document.visibilityState") == "visible"
    assert Page.evaluate!(page2, "document.visibilityState") == "visible"

    Page.bring_to_front!(page2)
    assert Page.evaluate!(page1, "document.visibilityState") == "visible"

    assert Page.evaluate!(page2, "document.visibilityState") ==
             "visible"

    Page.close!(page1)
    Page.close!(page2)
  end

  test "should click in OOPIF", %{launch_persistent: launch_persistent, server: server} do
    TestServer.set_route(server, "/empty.html", fn conn ->
      html(conn, ~s(<iframe src="#{server.cross_process_prefix}/iframe.html"></iframe>))
    end)

    TestServer.set_route(server, "/iframe.html", fn conn ->
      html(conn, """
      <button id="button" onclick="console.log('ok')">Submit</button>
          <script>console.log('frame loaded')</script>
      """)
    end)

    %{page: page} = launch_persistent.([])
    {:ok, console_log} = Agent.start_link(fn -> [] end)
    Page.on(page, :console, fn m -> Agent.update(console_log, &(&1 ++ [ConsoleMessage.text(m)])) end)
    Page.goto!(page, server.empty_page)
    Frame.click!(Enum.at(Page.frames(page), 1), "text=Submit")
    assert "ok" in Agent.get(console_log, & &1)
  end

  test "should click bottom row w/ infobar in OOPIF", %{
    browser_name: browser_name,
    launch_persistent: launch_persistent,
    server: server
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      html(conn, """
        <style>
          html, body { margin: 0; padding: 0; width: 100%; height: 100%; }
          iframe { position: absolute; bottom: 0; }
        </style>
        <iframe src="#{server.cross_process_prefix}/iframe.html"></iframe>
      """)
    end)

    TestServer.set_route(server, "/iframe.html", fn conn ->
      html(conn, """
        <style>
          html, body { margin: 0; padding: 0; width: 100%; height: 100%; }
          button { position: absolute; bottom: 0; }
        </style>
        <button id="button" onclick="window._clicked=true">Submit</button>
      """)
    end)

    %{page: page} = launch_persistent.([])
    Page.goto!(page, server.empty_page)

    if browser_name == "chromium" do
      # CHROME BUG:
      #   Unfortunately, on some platforms the automation infobar is shown up late or animates in.
      #   Upon showing, it triggers a resize of WebContentsView and RenderWidgetHostView
      #   through the native view hierarchy. This in turn resizes the compositor to the visible view size
      #   instead of the emulated size specified in Emulation.setDeviceMetricsOverride.
      #   Hit testing for OOPIFs is affected by the new size, and clicks do not reach the iframe.
      #
      #   The workaround is to re-apply the viewport after a delay, in this case after the navigation.
      Page.set_viewport_size!(page, %{width: 800, height: 600})
    end

    Frame.click!(Enum.at(Page.frames(page), 1), "text=Submit")
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "window._clicked") == true
  end

  # it.skip(browserName === 'firefox' && !isBidi, 'Text is misaligned in headed vs headless');  -- firefox is never BiDi here
  @tag :page
  @tag skip:
         @macos_chromium_skip || @headless_skip ||
           if(@browser_name == "firefox", do: "upstream skip: Text is misaligned in headed vs headless")
  test "headless and headful should use same default fonts", %{page: page, browser_type: browser_type} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/11177' });
    generic_font_families = [
      "standard",
      "serif",
      "sans-serif",
      "monospace",
      "cursive",
      "fantasy",
      "emoji"
    ]

    headless_browser = BrowserType.launch!(browser_type, headless: true)
    headless_page = Browser.new_page!(headless_browser)

    for family <- generic_font_families do
      content = """
      <div style="font: 15px bold #{if family == "standard", do: "", else: family}; max-width: 300px; max-height: 300px; overflow: hidden">
            Lorem ipsum dolor sit amet consectetur adipiscing elit proin, integer curabitur imperdiet rhoncus cursus tincidunt bibendum, consequat sed magnis laoreet luctus mollis tellus. Nisl parturient mus accumsan feugiat sem laoreet magnis nisi, aptent per sollicitudin gravida orci ac blandit, viverra eros praesent auctor vivamus semper bibendum. Consequat sed habitasse luctus dictumst gravida platea semper phasellus, nascetur ridiculus purus est varius quisque et scelerisque, id vehicula eleifend montes sollicitudin dis velit. Pellentesque ridiculus per natoque et eleifend taciti nunc, laoreet auctor at condimentum imperdiet ante, conubia mi cubilia scelerisque sociosqu sem.</p> <p>Curabitur magna per felis primis mauris non dapibus luctus ultricies eros, quis et egestas condimentum lobortis eget semper montes litora purus, ridiculus elementum sollicitudin imperdiet dictum lacinia parturient cras eu. Risus cum varius rhoncus eros torquent pretium taciti id erat dis egestas, nibh tristique montes convallis metus lacus phasellus blandit ut auctor bibendum semper, facilisis mi integer eget ultrices lobortis odio viverra duis dui. Risus ullamcorper lacinia in venenatis sodales fusce tortor potenti volutpat quis, dictum vulputate suspendisse velit mollis torquent sociis aptent morbi, senectus nascetur justo maecenas conubia magnis viverra gravida fames. Phasellus sed nec gravida nibh class augue lectus, blandit quis turpis orci diam nam pellentesque, ultricies metus imperdiet hendrerit lacinia lacus.</p> <p>Inceptos facilisi montes cum hendrerit, pulvinar ut tellus eget velit, arcu nulla aenean. Phasellus augue urna nostra molestie interdum vehicula, posuere fames cum euismod massa curabitur donec, inceptos cubilia tellus facilisis fermentum. Lacus laoreet facilisis ultrices cursus quisque at ad porta vestibulum massa inceptos, curae class aliquet maecenas cum ullamcorper pulvinar erat mus vitae. Cum in aenean convallis dis quam tincidunt justo sed quisque, imperdiet faucibus hendrerit felis commodo scelerisque magnis vehicula etiam leo, eros varius platea lobortis maecenas condimentum nisi phasellus. Turpis vulputate mus himenaeos sociosqu facilisis dignissim leo quam, ultricies habitasse commodo molestie est tortor vitae et, porttitor risus erat cursus phasellus facilisi litora.</p> <p>Nostra habitasse egestas magnis velit pellentesque parturient cum lectus viverra, vestibulum sociosqu nunc vel urna consequat lacinia phasellus at sapien, aenean pretium dictum sed montes interdum imperdiet iaculis. Leo hac eros arcu senectus maecenas, tortor pulvinar venenatis lacinia volutpat, mattis platea ut facilisi. Aenean condimentum at et donec sociosqu fermentum luctus potenti semper vulputate, sapien justo non est auctor gravida ultricies fames per commodo, sed habitasse facilisi nulla quisque hendrerit aliquet viverra bibendum.</p> <p>Interdum nisl quam etiam montes porttitor laoreet nullam senectus velit, mauris proin tellus imperdiet litora venenatis fames massa quis, sollicitudin justo vivamus curae in sociis suscipit facilisi. Platea inceptos lacus elementum pellentesque quam euismod dictumst sociis tincidunt vulputate porttitor eros, turpis netus ut ad tempor sapien aliquet sodales molestie consequat nostra. Cum augue in quisque primis ut nunc sodales, sem orci tempus posuere cubilia suspendisse lacinia ligula, magna sed ridiculus at maecenas habitant.</p> <p>Natoque magna ac feugiat tellus bibendum diam, metus lobortis nisl ornare varius praesent, dictumst gravida lacus parturient semper. Pellentesque faucibus congue fusce posuere placerat dictum vitae, dui vestibulum eu sociis tempus aliquam ultricies malesuada, potenti laoreet lacus sem gravida nisi. Nostra platea sagittis hendrerit congue conubia senectus bibendum quis sapien pharetra, scelerisque nam imperdiet fermentum feugiat suspendisse viverra luctus at, semper ac consequat vitae mi gravida parturient mollis nascetur. Vel taciti justo consequat primis et blandit convallis sed, felis purus fusce a venenatis etiam aenean scelerisque, fringilla volutpat sagittis egestas rutrum id dis.</p> <p>Feugiat fermentum tortor ante ac iaculis sollicitudin ut interdum, cras orci ullamcorper potenti tristique vehicula. Molestie tortor ullamcorper rutrum turpis malesuada phasellus sem ultricies praesent mattis lobortis porta, senectus venenatis diam nostra laoreet volutpat per aptent justo elementum cum. Urna cursus vel felis cras eleifend arcu enim magnis, duis rutrum nibh nascetur cubilia interdum ultrices curae, id lacus aliquam dictumst diam fringilla lacinia.</p> <p>Luctus diam morbi eget tellus libero taciti faucibus inceptos, natoque facilisis lectus maecenas risus dapibus suscipit nibh, vel curae conubia orci imperdiet metus fusce. Condimentum massa donec luctus pharetra cum, in viverra placerat nisl litora facilisis, neque nascetur sociis dictumst. Suscipit accumsan eget rhoncus pharetra justo malesuada aliquet, suspendisse metus eleifend tincidunt varius ridiculus, convallis primis vitae curabitur quis mus.</p> <p>Gravida donec lacus molestie tortor aenean ultricies blandit per tempor, nostra penatibus orci vestibulum semper lectus vel a, montes potenti cum dapibus natoque eu volutpat nulla. Himenaeos purus nam malesuada habitasse nisl pharetra laoreet feugiat mi non, ultrices ultricies a cras ante eu venenatis ligula. Suscipit ut mus habitasse at aliquet sodales commodo justo, feugiat platea sagittis phasellus eleifend pellentesque interdum iaculis, integer cubilia montes metus hendrerit tincidunt purus.</p> <p>Vel posuere tellus dapibus eget duis cubilia, nec class vehicula libero gravida ligula, tempus urna taciti donec congue. Facilisis ridiculus congue cum dui per augue natoque, molestie hac etiam pellentesque dignissim urna class, feugiat aenean massa himenaeos penatibus ut eu, convallis purus et fusce tempus mattis. At mattis suscipit porta nostra nec facilisis sodales turpis, integer et lectus conubia justo nam congue taciti odio, fermentum semper cubilia fusce nunc purus velit.
            <div/>
      """

      [
        Task.async(fn -> Page.set_content!(page, content) end),
        Task.async(fn -> Page.set_content!(headless_page, content) end)
      ]
      |> Task.await_many(:infinity)

      [image1, image2] =
        Task.await_many(
          [Task.async(fn -> Page.screenshot!(page) end), Task.async(fn -> Page.screenshot!(headless_page) end)],
          :infinity
        )

      count = UpstreamSnapshot.compare(image1, image2)
      assert count == 0
    end

    Browser.close!(headless_browser)
  end

  @tag :page
  @tag skip: @macos_chromium_skip || @headless_skip
  test "should have the same hyphen rendering on headless and headed", %{
    browser_type: browser_type,
    page: page,
    headless: headless,
    server: server
  } do
    # { annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/33590' } }
    content = """
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <style>
          .hyphenated {
            width: 100px;
            hyphens: auto;
            text-align: justify;
            border: 1px solid black;
          }
        </style>
      </head>
      <body>
        <div class="hyphenated">
          supercalifragilisticexpialidocious
        </div>
      </body>
      </html>
    """

    TestServer.set_route(server, "/hyphenated.html", fn conn -> html(conn, content) end)

    opposite_browser = BrowserType.launch!(browser_type, headless: !headless)
    opposite_page = Browser.new_page!(opposite_browser)
    Page.goto!(opposite_page, server.prefix <> "/hyphenated.html")
    Page.goto!(page, server.prefix <> "/hyphenated.html")

    height = "() => document.querySelector('.hyphenated').getBoundingClientRect().height"

    [div_height1, div_height2] =
      Task.await_many(
        [
          Task.async(fn -> Page.evaluate!(page, height) end),
          Task.async(fn -> Page.evaluate!(opposite_page, height) end)
        ],
        :infinity
      )

    assert div_height1 == div_height2
    Browser.close!(opposite_browser)
  end

  # browserTest `allowsThirdParty`.
  defp allows_third_party(browser_name), do: browser_name == "firefox"

  # browserTest `defaultSameSiteCookieValue` (no BiDi here).
  defp default_same_site_cookie_value("chromium"), do: "Lax"
  defp default_same_site_cookie_value("firefox"), do: "None"
  defp default_same_site_cookie_value("webkit"), do: if(match?({:unix, :linux}, :os.type()), do: "Lax", else: "None")

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  defp html(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, body)
end
