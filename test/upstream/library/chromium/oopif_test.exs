defmodule PlaywrightEx.Library.Chromium.OopifTest do
  @upstream "tests/library/chromium/oopif.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.UpstreamSnapshot
  import PlaywrightEx.Utils, only: [attach_frame: 3, poll: 2]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.CDPSession
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Worker

  @chromium_only if(System.get_env("BROWSER", "chromium") != "chromium", do: "upstream skip: Chromium only")
  @moduletag skip: @chromium_only

  # it.use({ launchOptions: { ...launchOptions, args: ['--site-per-process'] } }): this module's
  # `browser` is launched with `--site-per-process`; contextTest's `context`/`page` use it.
  setup_all %{browser_type: browser_type} do
    %{browser: BrowserType.launch!(browser_type, args: ["--site-per-process"])}
  end

  @tag :page
  test "should report oopif frames", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)
    assert length(Page.frames(page)) == 2

    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => '' + location.href") ==
             server.cross_process_prefix <> "/grid.html"
  end

  @tag :page
  test "should handle oopif detach", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)
    assert length(Page.frames(page)) == 2
    frame = Enum.at(Page.frames(page), 1)
    assert Frame.evaluate!(frame, "() => '' + location.href") == server.cross_process_prefix <> "/grid.html"
    detached_frame_promise = Page.wait_for_event(page, :frame_detached)
    Page.evaluate!(page, "() => document.querySelector('iframe').remove()")
    detached_frame = Promise.await!(detached_frame_promise)
    assert detached_frame == frame
  end

  @tag :page
  test "should remove workers of a detached oopif", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.empty_page)
    worker_promise = Page.wait_for_event(page, :worker)
    attach_frame(page, "frame1", server.cross_process_prefix <> "/worker/worker.html")
    worker = Promise.await!(worker_promise)
    assert_oopif_count(browser, 1)
    assert length(Page.workers(page)) == 1
    close_promise = Worker.wait_for_event(worker, :close)
    Page.goto!(page, server.prefix <> "/title.html")
    Promise.await!(close_promise)
    assert Page.workers(page) == []
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42278' }
  @tag :page
  test "should not hang in unrouteAll when oopif worker is gone", %{
    page: page,
    context: context,
    browser: browser,
    server: server
  } do
    BrowserContext.route!(context, "**/*", &Route.continue/1)
    Page.goto!(page, server.empty_page)
    worker_promise = Page.wait_for_event(page, :worker)
    attach_frame(page, "frame1", server.cross_process_prefix <> "/worker/worker.html")
    Promise.await!(worker_promise)
    assert_oopif_count(browser, 1)
    Page.goto!(page, server.cross_process_prefix <> "/title.html")
    BrowserContext.unroute_all!(context)
  end

  @tag :page
  test "should handle remote -> local -> remote transitions", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)

    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => '' + location.href") ==
             server.cross_process_prefix <> "/grid.html"

    navigation = Frame.wait_for_navigation(Enum.at(Page.frames(page), 1))
    Page.evaluate!(page, "goLocal()")
    Promise.await!(navigation)
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => '' + location.href") == server.prefix <> "/grid.html"
    assert_oopif_count(browser, 0)
    navigation = Frame.wait_for_navigation(Enum.at(Page.frames(page), 1))
    Page.evaluate!(page, "goRemote()")
    Promise.await!(navigation)

    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => '' + location.href") ==
             server.cross_process_prefix <> "/grid.html"

    assert_oopif_count(browser, 1)
  end

  @tag :page
  @tag skip: "upstream fixme: it.fixme (no reason given)"
  test "should get the proper viewport", %{page: page, browser: browser, server: server} do
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)
    oopif = Enum.at(Page.frames(page), 1)
    assert Frame.evaluate!(oopif, "() => screen.width") == 1280
    assert Frame.evaluate!(oopif, "() => screen.height") == 720
    assert Frame.evaluate!(oopif, "() => matchMedia('(device-width: 1280px)').matches") == true
    assert Frame.evaluate!(oopif, "() => matchMedia('(device-height: 720px)').matches") == true
    assert Frame.evaluate!(oopif, "() => 'ontouchstart' in window") == false
    Page.set_viewport_size!(page, %{width: 123, height: 456})
    assert Frame.evaluate!(oopif, "() => screen.width") == 123
    assert Frame.evaluate!(oopif, "() => screen.height") == 456
    assert Frame.evaluate!(oopif, "() => matchMedia('(device-width: 123px)').matches") == true
    assert Frame.evaluate!(oopif, "() => matchMedia('(device-height: 456px)').matches") == true
    assert Frame.evaluate!(oopif, "() => 'ontouchstart' in window") == false
  end

  @tag :page
  test "should expose function", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)
    oopif = Enum.at(Page.frames(page), 1)
    Page.expose_function!(page, "mul", fn a, b -> a * b end)

    result =
      Frame.evaluate!(oopif, """
      async function() {
        return await window['mul'](9, 4);
      }
      """)

    assert result == 36
  end

  @tag :page
  test "should emulate media", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)
    oopif = Enum.at(Page.frames(page), 1)
    assert Frame.evaluate!(oopif, "() => matchMedia('(prefers-color-scheme: dark)').matches") == false
    Page.emulate_media!(page, color_scheme: :dark)
    assert Frame.evaluate!(oopif, "() => matchMedia('(prefers-color-scheme: dark)').matches") == true
  end

  @tag :page
  test "should emulate offline", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)
    oopif = Enum.at(Page.frames(page), 1)
    assert Frame.evaluate!(oopif, "() => navigator.onLine") == true
    BrowserContext.set_offline!(Page.context(page), true)
    assert Frame.evaluate!(oopif, "() => navigator.onLine") == false
  end

  test "should support context options", %{browser: browser, server: server, playwright: playwright} do
    i_phone = Playwright.devices(playwright)["iPhone 6"]

    context =
      Browser.new_context!(
        browser,
        Map.merge(i_phone, %{timezone_id: "America/Jamaica", locale: "fr-CH", user_agent: "UA"})
      )

    page = BrowserContext.new_page!(context)

    request_task = TestServer.wait_for_request(server, "/grid.html")
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    request = Task.await(request_task, :infinity)
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)
    oopif = Enum.at(Page.frames(page), 1)

    assert Frame.evaluate!(oopif, "() => 'ontouchstart' in window") == true

    assert Frame.evaluate!(oopif, "() => new Date(1479579154987).toString()") ==
             "Sat Nov 19 2016 13:12:34 GMT-0500 (heure normale de l’Est nord-américain)"

    assert Frame.evaluate!(oopif, "() => navigator.language") == "fr-CH"
    assert Frame.evaluate!(oopif, "() => navigator.userAgent") == "UA"
    assert Plug.Conn.get_req_header(request, "user-agent") == ["UA"]

    BrowserContext.close!(context)
  end

  @tag :page
  test "should respect route", %{page: page, browser: browser, server: server} do
    test_pid = self()

    Page.route!(page, "**/digits/0.png", fn route ->
      send(test_pid, :intercepted)
      Route.continue(route)
    end)

    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)
    assert_received :intercepted
  end

  @tag :page
  # A test's `skip: nil` would override the `@moduletag skip:`.
  @tag skip:
         @chromium_only ||
           if(match?({:unix, :darwin}, :os.type()),
             do: "env: golden rendered on Linux; on macOS the OOPIF screenshot is blank (upstream's JS client too)"
           )
  test "should take screenshot", %{page: page, browser: browser, server: server} do
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)
    to_match_snapshot(Page.screenshot!(page), "screenshot-oopif.png")
  end

  @tag :page
  test "should load oopif iframes with subresources and route", %{page: page, browser: browser, server: server} do
    Page.route!(page, "**/*", &Route.continue/1)
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)
  end

  @tag :page
  test "should report main requests", %{page: page, browser: browser, server: server} do
    test_pid = self()
    Page.on(page, :request, fn r -> send(test_pid, {:request_frame, Request.frame(r)}) end)
    Page.on(page, :request_finished, fn r -> send(test_pid, {:finished_frame, Request.frame(r)}) end)

    Page.goto!(page, server.prefix <> "/empty.html")
    main = Page.main_frame(page)

    Frame.evaluate!(
      main,
      """
      url => {
        const iframe = document.createElement('iframe');
        iframe.src = url;
        document.body.appendChild(iframe);
        return new Promise(f => iframe.onload = f);
      }
      """,
      server.cross_process_prefix <> "/empty.html"
    )

    assert length(Page.frames(page)) == 2
    child = hd(Frame.child_frames(main))
    Frame.wait_for_load_state!(child, :domcontentloaded)

    Frame.evaluate!(
      child,
      """
      url => {
        const iframe = document.createElement('iframe');
        iframe.src = url;
        document.body.appendChild(iframe);
        return new Promise(f => iframe.onload = f);
      }
      """,
      server.prefix <> "/empty.html"
    )

    assert length(Page.frames(page)) == 3
    grand_child = hd(Frame.child_frames(child))
    Frame.wait_for_load_state!(grand_child, :domcontentloaded)

    assert_oopif_count(browser, 2)
    request_frames = collect(:request_frame)
    finished_frames = collect(:finished_frame)
    assert Enum.at(request_frames, 0) == main
    assert Enum.at(finished_frames, 0) == main
    assert Enum.at(request_frames, 1) == child
    assert Enum.at(finished_frames, 1) == child
    assert Enum.at(request_frames, 2) == grand_child
    assert Enum.at(finished_frames, 2) == grand_child
  end

  @tag :page
  test "should support exposeFunction", %{page: page, browser: browser, server: server} do
    BrowserContext.expose_function!(Page.context(page), "dec", fn a -> a - 1 end)
    Page.expose_function!(page, "inc", fn a -> a + 1 end)
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)
    assert length(Page.frames(page)) == 2
    assert Frame.evaluate!(Enum.at(Page.frames(page), 0), "() => window['inc'](3)") == 4
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window['inc'](4)") == 5
    assert Frame.evaluate!(Enum.at(Page.frames(page), 0), "() => window['dec'](3)") == 2
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window['dec'](4)") == 3
  end

  @tag :page
  test "should support addInitScript", %{page: page, browser: browser, server: server} do
    BrowserContext.add_init_script!(Page.context(page), "window['bar'] = 17")
    Page.add_init_script!(page, "window['foo'] = 42")
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)
    assert length(Page.frames(page)) == 2
    assert Frame.evaluate!(Enum.at(Page.frames(page), 0), "() => window['foo']") == 42
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window['foo']") == 42
    assert Frame.evaluate!(Enum.at(Page.frames(page), 0), "() => window['bar']") == 17
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window['bar']") == 17
  end

  # @see https://github.com/microsoft/playwright/issues/1240
  @tag :page
  test "should click a button when it overlays oopif", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/button-overlay-oopif.html")
    assert_oopif_count(browser, 1)
    Page.click!(page, "button")
    assert Page.evaluate!(page, "() => window['BUTTON_CLICKED']") == true
  end

  if match?({:unix, :linux}, :os.type()) and !System.get_env("DISPLAY"),
    do: @tag(skip: "headed: no X server (upstream runs headed tests under xvfb)")

  @tag :headed
  test "should report google.com frame with headed", %{browser_type: browser_type, server: server} do
    # it.skip(channel === 'chromium-headless-shell', 'Headless Shell does not support headed mode')  -- we run no channel
    # @see https://github.com/GoogleChrome/puppeteer/issues/2548
    # https://google.com is isolated by default in Chromium embedder.
    browser = BrowserType.launch!(browser_type, headless: false)
    page = Browser.new_page!(browser)
    Page.goto!(page, server.empty_page)
    Page.route!(page, "**/*", fn route -> Route.fulfill(route, body: "YO, GOOGLE.COM") end)

    Page.evaluate!(page, """
    () => {
      const frame = document.createElement('iframe');
      frame.setAttribute('src', 'https://google.com/');
      document.body.appendChild(frame);
      return new Promise(x => frame.onload = x);
    }
    """)

    Page.wait_for_selector!(page, ~s{iframe[src="https://google.com/"]})
    assert_oopif_count(browser, 1)
    urls = Enum.map(Page.frames(page), &Frame.url/1)
    assert urls == [server.empty_page, "https://google.com/"]
    Browser.close!(browser)
  end

  @tag :page
  test "ElementHandle.boundingBox() should work", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")

    Page.eval_on_selector!(page, "iframe", """
    iframe => {
      iframe.style.width = '520px';
      iframe.style.height = '520px';
      iframe.style.marginLeft = '42px';
      iframe.style.marginTop = '17px';
    }
    """)

    Frame.goto!(Enum.at(Page.frames(page), 1), Frame.url(Enum.at(Page.frames(page), 1)))

    assert_oopif_count(browser, 1)
    handle1 = Frame.query_selector!(Enum.at(Page.frames(page), 1), ".box:nth-of-type(13)")

    poll(fn -> ElementHandle.bounding_box!(handle1) end, fn box ->
      assert box == %{x: 100 + 42, y: 50 + 17, width: 50, height: 50}
    end)

    navigation = Frame.wait_for_navigation(Enum.at(Page.frames(page), 1))
    Page.evaluate!(page, "goLocal()")
    Promise.await!(navigation)
    assert_oopif_count(browser, 0)
    handle2 = Frame.query_selector!(Enum.at(Page.frames(page), 1), ".box:nth-of-type(13)")

    poll(fn -> ElementHandle.bounding_box!(handle2) end, fn box ->
      assert box == %{x: 100 + 42, y: 50 + 17, width: 50, height: 50}
    end)
  end

  @tag :page
  test "should click", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")

    Page.eval_on_selector!(page, "iframe", """
    iframe => {
      iframe.style.width = '500px';
      iframe.style.height = '500px';
      iframe.style.marginLeft = '102px';
      iframe.style.marginTop = '117px';
    }
    """)

    Frame.goto!(Enum.at(Page.frames(page), 1), Frame.url(Enum.at(Page.frames(page), 1)))

    assert_oopif_count(browser, 1)
    handle1 = Frame.query_selector!(Enum.at(Page.frames(page), 1), ".box:nth-of-type(13)")

    JSHandle.evaluate!(
      handle1,
      "div => div.addEventListener('click', () => window['_clicked'] = true, false)"
    )

    ElementHandle.click!(handle1)
    assert JSHandle.evaluate!(handle1, "() => window['_clicked']") == true
  end

  @tag :page
  test "contentFrame should work", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)

    assert page |> Page.locator("iframe") |> Locator.content_frame() |> FrameLocator.locator("div") |> Locator.count!() ==
             200

    oopif = Page.query_selector!(page, "iframe")
    content = ElementHandle.content_frame!(oopif)
    assert content |> Frame.locator("div") |> Locator.count!() == 200
  end

  @tag :page
  test "should allow cdp sessions on oopifs", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)
    assert length(Page.frames(page)) == 2

    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => '' + location.href") ==
             server.cross_process_prefix <> "/grid.html"

    parent_cdp = BrowserContext.new_cdp_session!(Page.context(page), Enum.at(Page.frames(page), 0))
    parent = CDPSession.send!(parent_cdp, "DOM.getDocument", %{pierce: true, depth: -1})
    refute JSON.encode!(parent) =~ "./digits/1.png"

    oopif_cdp = BrowserContext.new_cdp_session!(Page.context(page), Enum.at(Page.frames(page), 1))
    oopif = CDPSession.send!(oopif_cdp, "DOM.getDocument", %{pierce: true, depth: -1})
    assert JSON.encode!(oopif) =~ "./digits/1.png"
  end

  @tag :page
  test "should emit filechooser event for iframe", %{page: page, server: server, browser: browser} do
    # Add listener before OOPIF is created.
    chooser_promise = Page.wait_for_event(page, :file_chooser)
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)
    assert length(Page.frames(page)) == 2
    frame = Enum.at(Page.frames(page), 1)
    Frame.set_content!(frame, "<input type=file>")
    Frame.click!(frame, "input")
    chooser = Promise.await!(chooser_promise)
    assert chooser
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/28023' }
  @tag :page
  test "should be able to click in iframe", %{page: page, server: server, browser: browser} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)
    assert length(Page.frames(page)) == 2
    frame = Enum.at(Page.frames(page), 1)
    Frame.set_content!(frame, ~s[<button onclick="console.log('clicked')">OK</button>])
    message_promise = Page.wait_for_event(page, :console)
    Frame.click!(frame, "button")
    message = Promise.await!(message_promise)
    assert ConsoleMessage.text(message) == "clicked"
  end

  @tag :page
  test "should not throw on exposeFunction when oopif detaches", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    assert_oopif_count(browser, 1)

    Task.await_many(
      [
        Task.async(fn -> Page.expose_function!(page, "myFunc", fn -> 2022 end) end),
        Task.async(fn -> Page.evaluate!(page, "() => document.querySelector('iframe').remove()") end)
      ],
      :infinity
    )

    assert Page.evaluate!(page, "() => window.myFunc()") == 2022
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/20809' }
  @tag :page
  test "should intercept response body from oopif", %{page: page, server: server} do
    response_promise = Page.wait_for_response(page, "**/grid.html")
    Page.goto!(page, server.prefix <> "/dynamic-oopif.html")
    response = Promise.await!(response_promise)
    assert Response.text!(response) not in [nil, ""]
  end

  @tag :page
  test "should navigate a local frame to oopif with frame.goto", %{page: page, browser: browser, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    assert_oopif_count(browser, 0)
    frame = Enum.at(Page.frames(page), 1)
    assert Frame.url(frame) == server.prefix <> "/frames/frame.html"

    test_pid = self()
    Page.on(page, :frame_navigated, fn f -> send(test_pid, {:navigation, Frame.url(f)}) end)

    response = Frame.goto!(frame, server.cross_process_prefix <> "/grid.html")
    assert_oopif_count(browser, 1)
    assert Response.url(response) == server.cross_process_prefix <> "/grid.html"
    assert Response.frame(response) == frame
    assert Frame.url(frame) == server.cross_process_prefix <> "/grid.html"
    assert Frame.evaluate!(frame, "() => '' + location.href") == server.cross_process_prefix <> "/grid.html"
    assert collect(:navigation) == [server.cross_process_prefix <> "/grid.html"]
    assert length(Page.frames(page)) == 2
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/36095' }
  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/17656' }
  test "should allow to re-connect to OOPIFs with CDP when iframes were there already", %{
    browser_type: browser_type,
    server: server
  } do
    # it.skip(!!process.env.PWTEST_CHANNEL, 'Test default channel only')  -- we run no channel
    # `10123 + parallelIndex * 4` is a free port (modules run in parallel).
    cdp_port = free_port()
    host_browser = BrowserType.launch!(browser_type, channel: "chromium", args: ["--remote-debugging-port=#{cdp_port}"])
    host_page = Browser.new_page!(host_browser)
    Page.goto!(host_page, server.prefix <> "/dynamic-oopif.html")

    browser = BrowserType.connect_over_cdp!(browser_type, "http://localhost:#{cdp_port}")
    page = browser |> Browser.contexts() |> hd() |> BrowserContext.pages() |> hd()
    assert length(Page.frames(page)) == 2
    assert_oopif_count(browser, 1)

    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => '' + location.href") ==
             server.cross_process_prefix <> "/grid.html"

    Browser.close!(browser)
    Browser.close!(host_browser)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42955' }
  test "should report the whole frame tree when connecting over CDP to nested OOPIFs", %{
    browser_type: browser_type,
    server: server
  } do
    # it.skip(!!process.env.PWTEST_CHANNEL, 'Test default channel only')  -- we run no channel

    # top > cross-site iframe (oopif) > same-process child iframe > sandboxed srcdoc iframe (oopif).
    TestServer.set_route(server, "/nested-top.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(
        200,
        ~s[<h1 id=top>TOP</h1><iframe src="#{server.cross_process_prefix}/nested-b.html"></iframe>]
      )
    end)

    TestServer.set_route(server, "/nested-b.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s[<iframe src="/nested-c.html"></iframe>])
    end)

    TestServer.set_route(server, "/nested-c.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s[<iframe sandbox="allow-scripts" srcdoc="<p>D</p>"></iframe>])
    end)

    # `10123 + parallelIndex * 4` is a free port (modules run in parallel).
    cdp_port = free_port()

    host_browser =
      BrowserType.launch!(browser_type,
        channel: "chromium",
        args: ["--remote-debugging-port=#{cdp_port}", "--site-per-process", "--enable-features=IsolateSandboxedIframes"]
      )

    host_page = Browser.new_page!(host_browser)
    Page.goto!(host_page, server.prefix <> "/nested-top.html")

    browser = BrowserType.connect_over_cdp!(browser_type, "http://localhost:#{cdp_port}")
    assert_oopif_count(browser, 2)
    page = browser |> Browser.contexts() |> hd() |> BrowserContext.pages() |> hd()

    expected_tree = [
      server.prefix <> "/nested-top.html",
      "    " <> server.cross_process_prefix <> "/nested-b.html",
      "        " <> server.cross_process_prefix <> "/nested-c.html",
      "            about:srcdoc"
    ]

    assert dump_frames(Page.main_frame(page)) == expected_tree
    assert length(Page.frames(page)) == 4

    assert Page.url(page) == server.prefix <> "/nested-top.html"
    assert Page.evaluate!(page, "() => window.top === window") == true
    Expect.to_have_text!(Page.locator(page, "#top"), "TOP")

    page
    |> Page.frame_locator("iframe")
    |> FrameLocator.frame_locator("iframe")
    |> FrameLocator.frame_locator("iframe")
    |> FrameLocator.locator("p")
    |> Expect.to_have_text!("D")

    Browser.close!(browser)
    Browser.close!(host_browser)
  end

  defp dump_frames(frame, indent \\ "") do
    assert Frame.evaluate!(frame, "() => '' + location.href") == Frame.url(frame)
    [indent <> Frame.url(frame) | Enum.flat_map(Frame.child_frames(frame), &dump_frames(&1, indent <> "    "))]
  end

  defp assert_oopif_count(browser, count) do
    if BrowserType.name(Browser.browser_type(browser)) == "chromium" do
      assert count_oopifs(browser) == count
    end
  end

  defp count_oopifs(browser) do
    browser_session = Browser.new_browser_cdp_session!(browser)
    test_pid = self()

    CDPSession.on(browser_session, "Target.targetCreated", fn %{"targetInfo" => target_info} ->
      if target_info["type"] == "iframe", do: send(test_pid, {:oopif, target_info})
    end)

    CDPSession.send!(browser_session, "Target.setDiscoverTargets", %{discover: true})
    CDPSession.detach!(browser_session)
    length(collect(:oopif))
  end

  defp collect(tag) do
    receive do
      {^tag, value} -> [value | collect(tag)]
    after
      0 -> []
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
