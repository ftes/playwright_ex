defmodule PlaywrightEx.Library.PermissionsTest do
  @upstream "tests/library/permissions.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

  defp get_permission(%PlaywrightEx.Frame{} = frame, name),
    do: Frame.evaluate!(frame, "name => navigator.permissions.query({ name }).then(result => result.state)", name)

  defp get_permission(page, name),
    do: Page.evaluate!(page, "name => navigator.permissions.query({ name }).then(result => result.state)", name)

  describe "permissions" do
    # it.fixme(({ browserName, isWindows }) => browserName === 'webkit' && isWindows, 'Permissions API is disabled on Windows WebKit');

    test "PE-001 should be prompt by default", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      assert get_permission(page, "geolocation") == "prompt"
    end

    test "PE-002 should deny permission when not listed",
         %{page: page, context: context, server: server, browser_name: browser_name} do
      # it.skip(isFrozenWebkit);
      Page.goto!(page, server.empty_page)
      BrowserContext.grant_permissions!(context, [], origin: server.empty_page)

      if browser_name == "webkit" do
        assert get_permission(page, "geolocation") == "prompt"
        # Since https://github.com/WebKit/WebKit/pull/45470 WebKit only returns actual
        # permission value, if the API has been accessed.
        Page.evaluate!(page, "() => navigator.geolocation.getCurrentPosition(() => { })")
        assert get_permission(page, "geolocation") == "denied"
      else
        # isBidi: 'prompt'
        assert get_permission(page, "geolocation") == "denied"
      end
    end

    test "PE-003 should fail when bad permission is given", %{page: page, context: context, server: server} do
      Page.goto!(page, server.empty_page)
      {:error, error} = BrowserContext.grant_permissions(context, ["foo"], origin: server.empty_page)
      # isBidi: 'Protocol error (permissions.setPermission): invalid argument'
      assert Exception.message(error) =~ "Unknown permission: foo"
    end

    test "PE-004 should grant geolocation permission when origin is listed", %{
      page: page,
      context: context,
      server: server
    } do
      Page.goto!(page, server.empty_page)
      BrowserContext.grant_permissions!(context, ["geolocation"], origin: server.empty_page)
      assert get_permission(page, "geolocation") == "granted"
    end

    test "PE-005 should prompt for geolocation permission when origin is not listed",
         %{page: page, context: context, server: server} do
      Page.goto!(page, server.empty_page)
      BrowserContext.grant_permissions!(context, ["geolocation"], origin: server.empty_page)
      Page.goto!(page, server.cross_process_prefix <> "/empty.html")
      assert get_permission(page, "geolocation") == "prompt"
    end

    test "PE-006 should grant notifications permission when listed", %{page: page, context: context, server: server} do
      Page.goto!(page, server.empty_page)
      BrowserContext.grant_permissions!(context, ["notifications"], origin: server.empty_page)
      assert get_permission(page, "notifications") == "granted"
    end

    test "PE-007 should accumulate when adding", %{page: page, context: context, server: server} do
      Page.goto!(page, server.empty_page)
      BrowserContext.grant_permissions!(context, ["geolocation"])
      BrowserContext.grant_permissions!(context, ["notifications"])
      assert get_permission(page, "geolocation") == "granted"
      assert get_permission(page, "notifications") == "granted"
    end

    test "PE-008 should clear permissions", %{page: page, context: context, server: server} do
      Page.goto!(page, server.empty_page)
      BrowserContext.grant_permissions!(context, ["geolocation"])
      BrowserContext.clear_permissions!(context)
      BrowserContext.grant_permissions!(context, ["notifications"])
      assert get_permission(page, "geolocation") != "granted"
      assert get_permission(page, "notifications") == "granted"
    end

    test "PE-009 should grant permission when listed for all domains", %{page: page, context: context, server: server} do
      Page.goto!(page, server.empty_page)
      BrowserContext.grant_permissions!(context, ["geolocation"])
      assert get_permission(page, "geolocation") == "granted"
    end

    test "PE-010 should grant permission when creating context", %{server: server, browser: browser} do
      context = Browser.new_context!(browser, permissions: ["geolocation"])
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      assert get_permission(page, "geolocation") == "granted"
      BrowserContext.close!(context)
    end

    test "PE-011 should reset permissions", %{page: page, context: context, server: server} do
      Page.goto!(page, server.empty_page)
      BrowserContext.grant_permissions!(context, ["geolocation"], origin: server.empty_page)
      assert get_permission(page, "geolocation") == "granted"
      BrowserContext.clear_permissions!(context)
      assert get_permission(page, "geolocation") == "prompt"
    end

    test "PE-012 should trigger permission onchange", %{page: page, context: context, server: server} do
      # it.fail(browserName === 'webkit')
      expected_failure(@browser_name == "webkit", fn ->
        Page.goto!(page, server.empty_page)

        Page.evaluate!(page, """
        () => {
          window['events'] = [];
          return navigator.permissions.query({ name: 'geolocation' }).then(function(result) {
            window['events'].push(result.state);
            result.onchange = function() {
              window['events'].push(result.state);
            };
          });
        }
        """)

        events = fn -> Page.evaluate!(page, "() => window['events']") end
        assert events.() == ["prompt"]
        BrowserContext.grant_permissions!(context, [], origin: server.empty_page)
        # isBidi: no 'denied'
        assert events.() == ["prompt", "denied"]
        BrowserContext.grant_permissions!(context, ["geolocation"], origin: server.empty_page)
        assert events.() == ["prompt", "denied", "granted"]
        BrowserContext.clear_permissions!(context)
        assert events.() == ["prompt", "denied", "granted", "prompt"]
      end)
    end

    test "PE-013 should isolate permissions between browser contexts",
         %{server: server, browser: browser, browser_name: browser_name} do
      # it.skip(isFrozenWebkit);
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      other_context = Browser.new_context!(browser)
      other_page = BrowserContext.new_page!(other_context)
      Page.goto!(other_page, server.empty_page)
      assert get_permission(page, "geolocation") == "prompt"
      assert get_permission(other_page, "geolocation") == "prompt"

      BrowserContext.grant_permissions!(context, [], origin: server.empty_page)
      BrowserContext.grant_permissions!(other_context, ["geolocation"], origin: server.empty_page)

      if browser_name == "webkit" do
        assert get_permission(page, "geolocation") == "prompt"
        # Since https://github.com/WebKit/WebKit/pull/45470 WebKit only returns actual
        # permission value, if the API has been accessed.
        Page.evaluate!(page, "() => navigator.geolocation.getCurrentPosition(() => { })")
        assert get_permission(page, "geolocation") == "denied"
      else
        # isBidi: 'prompt'
        assert get_permission(page, "geolocation") == "denied"
      end

      assert get_permission(other_page, "geolocation") == "granted"

      BrowserContext.clear_permissions!(context)

      if browser_name == "webkit" do
        # Since https://github.com/WebKit/WebKit/pull/45470 WebKit returns the cached
        # permission value, if the geolocation API has been accessed.
        assert get_permission(page, "geolocation") == "denied"

        # Geolocation API in the new page in the same context has not been accessed yet,
        # so the permission status should be prompt.
        page2 = BrowserContext.new_page!(context)
        Page.goto!(page2, server.empty_page)
        assert get_permission(page2, "geolocation") == "prompt"
        Page.close!(page2)
      else
        assert get_permission(page, "geolocation") == "prompt"
      end

      assert get_permission(other_page, "geolocation") == "granted"
      BrowserContext.close!(other_context)
      BrowserContext.close!(context)
    end
  end

  test "PE-014 should support clipboard read", %{
    page: page,
    context: context,
    server: server,
    browser_name: browser_name
  } do
    # it.fail(browserName === 'firefox', 'No such permissions (requires flag) in Firefox')
    expected_failure(@browser_name == "firefox", fn ->
      # https://github.com/microsoft/playwright/issues/27475
      Page.goto!(page, server.empty_page)
      # There is no 'clipboard-read' permission in WebKit Web API.
      if browser_name != "webkit", do: assert(get_permission(page, "clipboard-read") == "prompt")

      # isHeadlessShell: headless chromium (no channel).
      if browser_name == "chromium" and PlaywrightEx.TestBrowser.headless() do
        # Chromium (but not headless-shell) shows a dialog and does not resolve the promise.
        {:error, error} = Page.evaluate(page, "() => navigator.clipboard.readText()")
        assert Exception.message(error) =~ "denied"
      end

      BrowserContext.grant_permissions!(context, ["clipboard-read"])
      if browser_name != "webkit", do: assert(get_permission(page, "clipboard-read") == "granted")
      # There is no 'clipboard-write' permission in WebKit Web API.
      if browser_name == "chromium", do: BrowserContext.grant_permissions!(context, ["clipboard-write"])
      Page.evaluate!(page, "() => navigator.clipboard.writeText('test content')")
      assert Page.evaluate!(page, "() => navigator.clipboard.readText()") == "test content"
    end)
  end

  test "PE-015 should isolate the headless clipboard from the operating system",
       %{browser_type: browser_type, server: server, browser_name: browser_name} do
    # https://github.com/microsoft/playwright/issues/13097
    # it.skip(isFrozenWebkit, 'needs recent webkit');

    # Each headless browser gets its own clipboard, so neither can see the clipboard of the operating system nor of another browser.
    browser1 = BrowserType.launch!(browser_type, headless: true)
    browser2 = BrowserType.launch!(browser_type, headless: true)

    [page1, page2] =
      [browser1, browser2]
      |> Enum.map(fn browser ->
        Task.async(fn ->
          context = Browser.new_context!(browser)
          # There is no 'clipboard-write' permission in WebKit Web API and no clipboard permission at all in Firefox.
          cond do
            browser_name == "chromium" ->
              BrowserContext.grant_permissions!(context, ["clipboard-read", "clipboard-write"])

            browser_name == "webkit" ->
              BrowserContext.grant_permissions!(context, ["clipboard-read"])

            true ->
              nil
          end

          page = BrowserContext.new_page!(context)
          Page.goto!(page, server.empty_page)
          page
        end)
      end)
      |> Task.await_many(:infinity)

    Page.evaluate!(page1, "() => navigator.clipboard.writeText('first')")
    assert Page.evaluate!(page1, "() => navigator.clipboard.readText()") == "first"

    Page.evaluate!(page2, "() => navigator.clipboard.writeText('second')")
    assert Page.evaluate!(page2, "() => navigator.clipboard.readText()") == "second"

    assert Page.evaluate!(page1, "() => navigator.clipboard.readText()") == "first"

    [browser1, browser2] |> Enum.map(&Task.async(fn -> Browser.close!(&1) end)) |> Task.await_many(:infinity)
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: chromium-only api")
  test "PE-016 storage access", %{page: page, context: context, server: server} do
    # https://github.com/microsoft/playwright/issues/31227
    BrowserContext.grant_permissions!(context, ["storage-access"])
    assert get_permission(page, "storage-access") == "granted"

    TestServer.set_route(server, "/set-cookie.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "name=value; Path=/; SameSite=Strict; Secure")
      |> Plug.Conn.send_resp(200, "")
    end)

    TestServer.set_route(server, "/my-frame.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s(<iframe src="#{server.cross_process_prefix <> "/empty.html"}"></iframe>))
    end)

    # Navigate once to the domain as top level.
    Page.goto!(page, server.cross_process_prefix <> "/set-cookie.html")
    Page.goto!(page, server.prefix <> "/my-frame.html")

    frame = Enum.at(Page.frames(page), 1)
    assert get_permission(frame, "storage-access") == "granted"
    access = Frame.evaluate!(frame, "() => document.requestStorageAccess().then(() => true, () => false)")
    assert access == true
    assert Frame.evaluate!(frame, "() => document.hasStorageAccess()") == true
  end

  # it.describe(() => { it.use({ ignoreHTTPSErrors: true }) }): secure context.

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: chromium-only api")
  test "PE-017 should be able to use the local-fonts API", %{
    context_factory: context_factory,
    https_server: https_server
  } do
    # it.skip(!!channel && channel.startsWith('msedge'), 'always times out in edge');
    # it.fixme(!headless, 'times out in headed');
    # https://github.com/microsoft/playwright/issues/36113
    context = context_factory.(ignore_https_errors: true)
    page = BrowserContext.new_page!(context)

    Page.goto!(page, https_server.empty_page)
    assert get_permission(page, "local-fonts") == "prompt"
    BrowserContext.grant_permissions!(context, ["local-fonts"])
    assert get_permission(page, "local-fonts") == "granted"
    assert Page.evaluate!(page, "async () => (await window.queryLocalFonts()).length > 0") == true
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream skip: webkit")
  test "PE-018 local network request is allowed from public origin",
       %{page: page, context: context, server: server, browser_name: browser_name} do
    # https://github.com/microsoft/playwright/issues/37861
    # it.skip(browserName === 'chromium' && browserMajorVersion < 145, ...)  -- the pinned Chromium is newer

    if browser_name in ["chromium", "firefox"], do: BrowserContext.grant_permissions!(context, ["local-network-access"])

    test = self()

    TestServer.set_route(server, "/cors", fn conn ->
      send(test, {:server_request, "#{conn.method} #{conn.request_path}"})

      if conn.method == "OPTIONS" do
        conn
        |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
        |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET, POST, PUT, OPTIONS")
        |> Plug.Conn.put_resp_header("access-control-allow-headers", "*")
        |> Plug.Conn.send_resp(204, "")
      else
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
        |> Plug.Conn.send_resp(200, "Hello there!")
      end
    end)

    # Has to be a public origin.
    Page.goto!(page, "https://demo.playwright.dev/todomvc/")

    Page.on(page, :request, fn request ->
      send(test, {:client_request, "#{Request.method(request)} #{Request.url(request)}"})
    end)

    response =
      case Page.evaluate(
             page,
             """
             async url => {
               const response = await fetch(url, {
                 method: 'POST',
                 body: '',
                 headers: {
                   'Content-Type': 'application/json',
                   'X-Custom-Header': 'test-value'
                 }
               });
               return await response.text();
             }
             """,
             server.cross_process_prefix <> "/cors"
           ) do
        {:ok, value} -> value
        {:error, error} -> Exception.message(error)
      end

    assert response == "Hello there!"
    # serverRequests in order: each is sent before its response, so the preflight comes first.
    server_requests =
      Stream.repeatedly(fn ->
        receive do
          {:server_request, request} -> request
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert server_requests == ["OPTIONS /cors", "POST /cors"]
    expected_client_request = "POST #{server.cross_process_prefix}/cors"
    assert_receive {:client_request, ^expected_client_request}
    refute_received {:client_request, _}
  end

  test "PE-019 can request screen-wake-lock", %{page: page, context: context} do
    # https://github.com/microsoft/playwright/issues/39115
    BrowserContext.grant_permissions!(context, ["screen-wake-lock"])

    Page.route!(page, "**/*", fn route ->
      Route.fulfill!(route, status: 200, body: "<div>Hello there!</div>", content_type: "text/html")
    end)

    Page.goto!(page, "https://example.com")
    Page.evaluate!(page, "() => navigator.wakeLock.request('screen')")
  end

  describe "camera and microphone" do
    # WebKit exposes deterministic mock capture devices; capture is gated on the
    # 'camera'/'microphone' permissions. Chromium needs --use-fake-device-for-media-stream
    # and Firefox has no camera/microphone permission mapping, so scope to WebKit.
    # it.skip(({ isWindows, channel }) => isWindows && channel !== 'webkit-wsl', 'WebKit has no media capture on Windows');
    @describetag skip: if(@browser_name != "webkit", do: "upstream skip: WebKit mock-capture-device based test")

    defp get_user_media(page, constraints) do
      Page.evaluate!(
        page,
        """
        async constraints => {
          try {
            const stream = await navigator.mediaDevices.getUserMedia(constraints);
            const tracks = stream.getTracks().map(track => ({ kind: track.kind, live: track.readyState === 'live' }));
            stream.getTracks().forEach(track => track.stop());
            tracks.sort((a, b) => a.kind.localeCompare(b.kind));
            return { tracks };
          } catch (error) {
            return { error: error.name };
          }
        }
        """,
        constraints
      )
    end

    test "PE-020 should capture when camera and microphone are granted", %{page: page, context: context, server: server} do
      # https://github.com/microsoft/playwright/issues/2973
      # it.skip(isFrozenWebkit, 'Mock capture device support requires a newer WebKit build');
      BrowserContext.grant_permissions!(context, ["camera", "microphone"], origin: server.prefix)
      Page.goto!(page, server.empty_page)

      assert get_user_media(page, %{video: true, audio: true}) == %{
               "tracks" => [
                 %{"kind" => "audio", "live" => true},
                 %{"kind" => "video", "live" => true}
               ]
             }
    end

    test "PE-021 should reject when no permission is granted", %{page: page, server: server} do
      # https://github.com/microsoft/playwright/issues/2973
      # it.skip(isFrozenWebkit, 'Mock capture device support requires a newer WebKit build');
      Page.goto!(page, server.empty_page)
      assert get_user_media(page, %{video: true, audio: true}) == %{"error" => "NotAllowedError"}
    end

    test "PE-022 should gate audio and video independently", %{page: page, context: context, server: server} do
      # https://github.com/microsoft/playwright/issues/2973
      # it.skip(isFrozenWebkit, 'Mock capture device support requires a newer WebKit build');
      BrowserContext.grant_permissions!(context, ["camera"], origin: server.prefix)
      Page.goto!(page, server.empty_page)
      # Camera-only request is allowed.
      assert get_user_media(page, %{video: true}) == %{"tracks" => [%{"kind" => "video", "live" => true}]}
      # Microphone request is rejected because it was not granted.
      assert get_user_media(page, %{audio: true}) == %{"error" => "NotAllowedError"}
    end

    test "PE-023 should stop capturing after permissions are cleared", %{page: page, context: context, server: server} do
      # https://github.com/microsoft/playwright/issues/2973
      # it.skip(isFrozenWebkit, 'Mock capture device support requires a newer WebKit build');
      BrowserContext.grant_permissions!(context, ["camera"], origin: server.prefix)
      Page.goto!(page, server.empty_page)
      assert get_user_media(page, %{video: true}) == %{"tracks" => [%{"kind" => "video", "live" => true}]}
      BrowserContext.clear_permissions!(context)
      assert get_user_media(page, %{video: true}) == %{"error" => "NotAllowedError"}
    end
  end
end
