defmodule PlaywrightEx.Library.Defaultbrowsercontext2Test do
  @upstream "tests/library/defaultbrowsercontext-2.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  test "should support hasTouch option", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(has_touch: true)
    Page.goto!(page, server.prefix <> "/mobile.html")
    assert Page.evaluate!(page, "() => 'ontouchstart' in window") == true
  end

  test "should work in persistent context", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(viewport: %{width: 320, height: 480}, is_mobile: true)
    Page.goto!(page, server.prefix <> "/empty.html")
    assert Page.evaluate!(page, "() => window.innerWidth") == 980
  end

  test "should support colorScheme option", %{launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(color_scheme: :dark)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: light)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches") == true
  end

  test "should support reducedMotion option", %{launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(reduced_motion: :reduce)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: reduce)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: no-preference)').matches") == false
  end

  test "should support forcedColors option", %{launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(forced_colors: :active)
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: active)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: none)').matches") == false
  end

  test "should support contrast option", %{launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(contrast: :more)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-contrast: more)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(prefers-contrast: no-preference)').matches") == false
  end

  test "should support timezoneId option", %{launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(locale: "en-US", timezone_id: "America/Jamaica")

    assert Page.evaluate!(page, "() => new Date(1479579154987).toString()") ==
             "Sat Nov 19 2016 13:12:34 GMT-0500 (Eastern Standard Time)"
  end

  test "should support locale option", %{launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(locale: "fr-FR")
    assert Page.evaluate!(page, "() => navigator.language") == "fr-FR"
  end

  test "should support geolocation and permissions options", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} =
      launch_persistent.(geolocation: %{longitude: 10, latitude: 10}, permissions: ["geolocation"])

    Page.goto!(page, server.empty_page)

    geolocation =
      Page.evaluate!(page, """
      () => new Promise(resolve => navigator.geolocation.getCurrentPosition(position => {
        resolve({ latitude: position.coords.latitude, longitude: position.coords.longitude });
      }))
      """)

    assert geolocation == %{"latitude" => 10, "longitude" => 10}
  end

  test "should support ignoreHTTPSErrors option", %{https_server: https_server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(ignore_https_errors: true)
    {:ok, response} = Page.goto(page, https_server.empty_page)
    assert Response.ok(response) == true
  end

  test "should support extraHTTPHeaders option", %{server: server, launch_persistent: launch_persistent} do
    %{page: page} = launch_persistent.(extra_http_headers: %{"foo" => "bar"})
    request = TestServer.wait_for_request(server, "/empty.html")
    Page.goto!(page, server.empty_page)
    assert header(Task.await(request), "foo") == "bar"
  end

  test "should accept userDataDir", %{create_user_data_dir: create_user_data_dir, browser_type: browser_type} do
    user_data_dir = create_user_data_dir.()
    context = BrowserType.launch_persistent_context!(browser_type, user_data_dir)
    assert length(File.ls!(user_data_dir)) > 0
    BrowserContext.close!(context)
    assert length(File.ls!(user_data_dir)) > 0
  end

  test "should accept relative userDataDir", %{create_user_data_dir: create_user_data_dir, browser_type: browser_type} do
    user_data_dir = create_user_data_dir.()

    context =
      BrowserType.launch_persistent_context!(
        browser_type,
        Path.relative_to(Path.join(user_data_dir, "foobar"), File.cwd!(), force: true)
      )

    assert length(File.ls!(Path.join(user_data_dir, "foobar"))) > 0
    BrowserContext.close!(context)
  end

  @tag timeout: 180_000
  test "should restore state from userDataDir", %{
    browser_type: browser_type,
    server: server,
    create_user_data_dir: create_user_data_dir
  } do
    user_data_dir = create_user_data_dir.()
    browser_context = BrowserType.launch_persistent_context!(browser_type, user_data_dir)
    page = BrowserContext.new_page!(browser_context)
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => localStorage.hey = 'hello'")
    # Browsers do not persist local storage immediately, they do it asynchronously in another process.
    # Navigate away to give it a chance to save (best-effort).
    Page.goto!(page, server.empty_page)
    BrowserContext.close!(browser_context)

    browser_context2 = BrowserType.launch_persistent_context!(browser_type, user_data_dir)
    page2 = BrowserContext.new_page!(browser_context2)
    Page.goto!(page2, server.empty_page)
    assert Page.evaluate!(page2, "() => localStorage.hey") == "hello"
    BrowserContext.close!(browser_context2)

    user_data_dir2 = create_user_data_dir.()
    browser_context3 = BrowserType.launch_persistent_context!(browser_type, user_data_dir2)
    page3 = BrowserContext.new_page!(browser_context3)
    Page.goto!(page3, server.empty_page)
    assert Page.evaluate!(page3, "() => localStorage.hey") != "hello"
    BrowserContext.close!(browser_context3)
  end

  test "should create userDataDir if it does not exist", %{
    create_user_data_dir: create_user_data_dir,
    browser_type: browser_type
  } do
    user_data_dir = Path.join(create_user_data_dir.(), "nonexisting")
    context = BrowserType.launch_persistent_context!(browser_type, user_data_dir)
    BrowserContext.close!(context)
    assert length(File.ls!(user_data_dir)) > 0
  end

  test "should goto about:blank on relaunched persistent context", %{
    browser_type: browser_type,
    create_user_data_dir: create_user_data_dir,
    browser_name: browser_name
  } do
    # it.fixme(browserName === 'firefox' && !isBidi);
    if browser_name != "firefox" do
      user_data_dir = create_user_data_dir.()

      context1 = BrowserType.launch_persistent_context!(browser_type, user_data_dir)
      Page.goto!(hd(BrowserContext.pages(context1)), "about:blank")
      BrowserContext.close!(context1)

      # When relaunching with an existing profile, Firefox session restore can race with the user's goto and cause "interrupted by another navigation".
      # This issue is timing-sensitive and might not fire on every run, so rely on CI's --repeat-each matrix for coverage.
      context2 = BrowserType.launch_persistent_context!(browser_type, user_data_dir)
      Page.goto!(hd(BrowserContext.pages(context2)), "about:blank")
      assert Page.url(hd(BrowserContext.pages(context2))) == "about:blank"
      BrowserContext.close!(context2)
    end
  end

  test "should have default URL when launching browser", %{launch_persistent: launch_persistent} do
    %{context: context} = launch_persistent.([])
    urls = Enum.map(BrowserContext.pages(context), &Page.url/1)
    assert urls == ["about:blank"]
  end

  test "should throw if page argument is passed", %{
    browser_type: browser_type,
    server: server,
    create_user_data_dir: create_user_data_dir,
    browser_name: browser_name
  } do
    if browser_name != "firefox" do
      options = [args: [server.empty_page]]
      {:error, error} = BrowserType.launch_persistent_context(browser_type, create_user_data_dir.(), options)
      assert Exception.message(error) =~ "can not specify page"
    end
  end

  @tag skip: "not ported: toImpl (server-side defaultArgs)"
  test "should have passed URL when launching with ignoreDefaultArgs: true"

  @tag skip: "not ported: __testHookBeforeCreateBrowser is a JS function"
  test "should handle timeout"

  @tag skip: "not ported: __testHookBeforeCreateBrowser is a JS function"
  test "should handle exception"

  test "should fire close event for a persistent context", %{launch_persistent: launch_persistent} do
    %{context: context} = launch_persistent.([])
    test = self()
    BrowserContext.on(context, :close, fn _ -> send(test, :closed) end)
    BrowserContext.close!(context)
    assert_received :closed
  end

  @tag skip: "not ported: Coverage"
  test "coverage should work"

  @tag skip: "not ported: Selectors"
  test "should respect selectors"

  @tag skip: "not ported: __testHookOnConnectToBrowser is a JS function"
  test "should connect to a browser with the default page"

  @tag skip: "not ported: routeFromHAR"
  test "should support har option"

  # `(browser as any)._channel.defaultUserAgentForTest()`: the client's channel call.
  test "user agent is up to date", %{launch_persistent: launch_persistent, browser: browser} do
    %{userAgent: user_agent} =
      PlaywrightEx.Runtime.Api.call(nil, browser, fn ->
        ChannelOwner.channel_call(browser, :defaultUserAgentForTest, %{})
      end)

    %{context: context, page: page} = launch_persistent.([])
    assert Page.evaluate!(page, "() => navigator.userAgent") == user_agent
    BrowserContext.close!(context)
  end

  test "dialog.accept should work", %{launch_persistent: launch_persistent} do
    %{context: context, page: page} = launch_persistent.([])

    Page.goto!(
      page,
      ~s|data:text/html,<html><title>Title</title><button onclick="alert('Alert')">Button</button></html>|
    )

    test = self()

    Page.on(page, :dialog, fn dialog ->
      send(test, :shown)
      Dialog.accept(dialog)
    end)

    page |> Page.get_by_role(:button, name: "Button") |> Locator.click!()
    assert_received :shown
    BrowserContext.close!(context)
  end

  test "CacheStorage entry should survive page.reload()", %{launch_persistent: launch_persistent, server: server} do
    %{context: context, page: page} = launch_persistent.([])
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    async () => {
      const cache = await caches.open('repro-cache');
      await cache.put('/meta', new Response('payload'));
    }
    """)

    Page.reload!(page)

    after_reload =
      Page.evaluate!(page, """
      async () => {
        const cache = await caches.open('repro-cache');
        const resp = await cache.match('/meta');
        return resp ? await resp.text() : null;
      }
      """)

    assert after_reload == "payload"
    BrowserContext.close!(context)
  end

  test "exposes browser", %{launch_persistent: launch_persistent} do
    %{context: context} = launch_persistent.([])
    browser = BrowserContext.browser(context)
    assert Browser.version(browser)
    page = Browser.new_page!(browser)
    Page.goto!(page, "data:text/html,<html><title>Title</title></html>")
    assert Page.title!(page) == "Title"
    Browser.close!(browser)
    assert BrowserContext.pages(context) == []
    # Next line should not throw.
    BrowserContext.close!(context)
  end

  test "should support storage.getDirectory()", %{launch_persistent: launch_persistent, server: server} do
    %{context: context} = launch_persistent.([])
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    name =
      Page.evaluate!(page, """
      async () => {
        const dir = await navigator.storage.getDirectory();
        return dir.name;
      }
      """)

    assert name == ""
    BrowserContext.close!(context)
  end
end
