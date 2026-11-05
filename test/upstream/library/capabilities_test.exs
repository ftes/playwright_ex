defmodule PlaywrightEx.Library.CapabilitiesTest do
  @upstream "tests/library/capabilities.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.FileChooser
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")
  @is_windows match?({:win32, _}, :os.type())
  # Upstream's CI runs Linux under xvfb-run: headless Firefox without a display finds no GL driver.
  @no_display match?({:unix, :linux}, :os.type()) and System.get_env("DISPLAY") in [nil, ""]
  @no_firefox_webgl if(@no_display and @browser_name == "firefox",
                      do:
                        "env: Linux Firefox without an X display has no WebGL (Exhausted GL driver options; upstream client too)"
                    )

  # platformFixtures `macVersion` (major; 0 if not mac): Darwin 25 = macOS 26, Darwin 24 = macOS 15.
  @mac_version (case :os.type() do
                  {:unix, :darwin} ->
                    {darwin_major, _, _} = :os.version()
                    if darwin_major >= 25, do: darwin_major + 1, else: darwin_major - 9

                  _ ->
                    0
                end)

  # url.pathToFileURL(path).href
  defp file_url(path), do: "file://" <> URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))

  defp html(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/html")
    |> Plug.Conn.send_resp(200, body)
  end

  test "SharedArrayBuffer should work @smoke", %{context_factory: context_factory, https_server: https_server} do
    context = context_factory.(ignore_https_errors: true)
    page = BrowserContext.new_page!(context)

    TestServer.set_route(https_server, "/sharedarraybuffer", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
      |> Plug.Conn.put_resp_header("cross-origin-embedder-policy", "require-corp")
      # Note: without 'onload', Firefox sometimes does not fire the load event
      # over the protocol. The reason is unclear.
      |> Plug.Conn.send_resp(200, """
        <div>Hello there!</div>
        <script>window.onload = () => console.log('onload')</script>
      """)
    end)

    Page.goto!(page, https_server.prefix <> "/sharedarraybuffer")
    assert Page.evaluate!(page, "() => typeof SharedArrayBuffer") == "function"
  end

  test "Web Assembly should work @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/wasm/table2.html")
    assert Page.evaluate!(page, "loadTable()") == "42, 83"
  end

  test "WebSocket should work @smoke", %{page: page, server: server} do
    TestServer.send_on_web_socket_connection(server, "incoming")

    value =
      Page.evaluate!(
        page,
        """
        host => {
          let cb;
          const result = new Promise(f => cb = f);
          const ws = new WebSocket('ws://' + host + '/ws');
          ws.addEventListener('message', data => { ws.close(); cb(data.data); });
          ws.addEventListener('error', error => cb('Error'));
          return result;
        }
        """,
        server.host
      )

    assert value == "incoming"
  end

  test "should respect CSP @smoke", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-security-policy", "script-src 'unsafe-inline';")
      |> Plug.Conn.send_resp(200, """
        <script>
          window.testStatus = 'SUCCESS';
          window.testStatus = eval("'FAILED'");
        </script>
      """)
    end)

    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => window['testStatus']") == "SUCCESS"
  end

  @tag skip:
         if(@is_windows and @browser_name == "webkit",
           do:
             "upstream skip: passes locally but fails on GitHub Action bot, apparently due to a Media Pack issue in the Windows Server"
         )
  test "should play video @smoke", %{page: page, asset: asset, browser_name: browser_name} do
    # Safari only plays mp4 so we test WebKit with an .mp4 clip.
    file_name = if browser_name == "webkit", do: "video_mp4.html", else: "video.html"
    absolute_path = asset.(file_name)
    # Our test server doesn't support range requests required to play on Mac,
    # so we load the page using a file url.
    Page.goto!(page, file_url(absolute_path))
    Page.eval_on_selector!(page, "video", "v => v.play()")
    Page.eval_on_selector!(page, "video", "v => v.pause()")
  end

  @tag skip: if(@is_windows and @browser_name == "webkit", do: "upstream skip: not supported")
  test "should play webm video @smoke", %{page: page, asset: asset} do
    absolute_path = asset.("video_webm.html")
    # Our test server doesn't support range requests required to play on Mac,
    # so we load the page using a file url.
    Page.goto!(page, file_url(absolute_path))
    Page.eval_on_selector!(page, "video", "v => v.play()")
    Page.eval_on_selector!(page, "video", "v => v.pause()")
  end

  @tag skip:
         (cond do
            @is_windows and @browser_name == "webkit" ->
              "upstream fixme: https://github.com/microsoft/playwright/issues/10892"

            @browser_name == "webkit" and @mac_version == 15 ->
              "upstream skip: audio output is unreliable on hosted macOS 15 runners"

            true ->
              nil
          end)
  test "should play audio @smoke", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<audio src="#{server.prefix}/example.mp3"></audio>))
    Page.eval_on_selector!(page, "audio", "e => e.play()")
    Page.wait_for_timeout!(page, 3000)
    Page.eval_on_selector!(page, "audio", "e => e.pause()")
    assert Page.eval_on_selector!(page, "audio", "e => e.currentTime") > 0.1
  end

  @tag skip: @no_firefox_webgl
  test "should support webgl @smoke", %{page: page} do
    has_web_gl =
      Page.evaluate!(page, """
      () => {
        const canvas = document.createElement('canvas');
        return !!canvas.getContext('webgl');
      }
      """)

    assert has_web_gl == true
  end

  @tag skip:
         if(@is_windows and @browser_name == "firefox", do: "upstream fixme: firefox on Windows") || @no_firefox_webgl
  test "should support webgl 2 @smoke", %{page: page} do
    has_web_gl2 =
      Page.evaluate!(page, """
      () => {
        const canvas = document.createElement('canvas');
        return !!canvas.getContext('webgl2');
      }
      """)

    assert has_web_gl2 == true
  end

  @tag skip:
         if(@is_windows and @browser_name == "webkit",
           do: "upstream fixme: https://github.com/microsoft/playwright/issues/11009, times out in setContent"
         )
  test "should not crash on page with mp4 @smoke", %{page: page, server: server} do
    Page.set_content!(page, ~s(<video><source src="#{server.prefix}/movie.mp4"/></video>))
    Page.wait_for_timeout!(page, 1000)
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: showDirectoryPicker is only available in Chromium")
  test "should not crash on showDirectoryPicker", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/7339
    Page.goto!(page, server.empty_page)
    # "User activation is required to show a file picker." - so we click first.
    Locator.click!(Page.locator(page, "body"))

    picker =
      Task.async(fn ->
        Page.evaluate(page, """
        async () => {
          const dir = await window.showDirectoryPicker();
          return dir.name;
          // In headless it throws (aborted), in headed it stalls (Test ended) and waits for the picker to be accepted.
        }
        """)
      end)

    # The dialog will not be accepted, so we just wait for some time to
    # to give the browser a chance to crash.
    Page.wait_for_timeout!(page, 3_000)

    # `.catch(e => expect(e.message).toMatch(...))`: checked if it settled (headed: it stalls until the test ends).
    case Task.yield(picker, 0) || Task.shutdown(picker) do
      {:ok, {:error, e}} ->
        assert Exception.message(e) =~ ~r/((DOMException|AbortError): .*The user aborted a request|Test ended)/

      _ ->
        :ok
    end
  end

  test "should not crash on storage.getDirectory()", %{page: page, server: server, browser_name: browser_name} do
    # annotation: issue https://github.com/microsoft/playwright/issues/18235
    Page.goto!(page, server.empty_page)

    error =
      case Page.evaluate(page, """
           async () => {
             const dir = await navigator.storage.getDirectory();
             return dir.name;
           }
           """) do
        {:ok, _} -> nil
        {:error, e} -> e
      end

    if browser_name == "webkit",
      do: assert(Exception.message(error) =~ "UnknownError: The operation failed for an unknown transient reason"),
      else: refute(error)
  end

  test "navigator.clipboard should be present", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/18901
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => navigator.clipboard")
  end

  test "should set CloseEvent.wasClean to false when the server terminates a WebSocket connection",
       %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/12353
    TestServer.once_web_socket_connection(server, fn socket ->
      TestServer.WebSocket.destroy(socket)
    end)

    was_clean =
      Page.evaluate!(
        page,
        """
        port => new Promise(resolve => {
          const ws = new WebSocket('ws://localhost:' + port + '/ws');
          ws.addEventListener('close', error => resolve(error.wasClean));
        })
        """,
        server.port
      )

    assert was_clean == false
  end

  test "serviceWorker should intercept document request", %{page: page, server: server} do
    TestServer.set_route(server, "/sw.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.send_resp(200, """
        self.addEventListener('fetch', event => {
          event.respondWith(new Response('intercepted'));
        });
        self.addEventListener('activate', event => {
          event.waitUntil(clients.claim());
        });
      """)
    end)

    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    async () => {
      await navigator.serviceWorker.register('/sw.js');
      await new Promise(resolve => navigator.serviceWorker.oncontrollerchange = resolve);
    }
    """)

    Page.reload!(page)
    assert Page.text_content!(page, "body") == "intercepted"
  end

  @tag skip: if(@browser_name != "webkit", do: "upstream skip: not webkit")
  test "webkit should define window.safari", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/21037
    # issue: https://github.com/microsoft/playwright/issues/29032
    Page.goto!(page, server.empty_page)
    defined = Page.evaluate!(page, "() => !!window.safari")
    assert defined
    assert Page.evaluate!(page, "() => typeof window.safari.pushNotification") == "object"

    assert Page.evaluate!(page, "() => window.safari.pushNotification.toString()") ==
             "[object SafariRemoteNotification]"
  end

  test "make sure that XMLHttpRequest upload events are emitted correctly", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/21489
    Page.goto!(page, server.empty_page)

    events =
      Page.evaluate!(page, """
      async () => {
        const events = [];
        const xhr = new XMLHttpRequest();
        xhr.upload.addEventListener('loadstart', () => events.push('loadstart'));
        xhr.upload.addEventListener('progress', () => events.push('progress'));
        xhr.upload.addEventListener('load', () => events.push('load'));
        xhr.upload.addEventListener('loadend', () => events.push('loadend'));
        xhr.open('POST', '/simple.json');
        xhr.send('hello');
        await new Promise(f => xhr.onload = f);
        return events;
      }
      """)

    assert events == ["loadstart", "progress", "load", "loadend"]
  end

  test "loading in HTMLImageElement.prototype", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/22738
    Page.goto!(page, server.empty_page)
    defined = Page.evaluate!(page, "() => 'loading' in HTMLImageElement.prototype")
    assert defined
  end

  test "window.GestureEvent in WebKit", %{page: page, server: server, browser_name: browser_name} do
    # issue: https://github.com/microsoft/playwright/issues/22735
    Page.goto!(page, server.empty_page)
    defined = Page.evaluate!(page, "() => 'GestureEvent' in window")
    assert defined == (browser_name == "webkit")
    type = Page.evaluate!(page, "() => typeof window.GestureEvent")
    assert type == if(browser_name == "webkit", do: "function", else: "undefined")
  end

  # it.fixme(firefox && !headless)  -- not honored: we run headless
  test "requestFullscreen", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/22832
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      const result = new Promise(resolve => document.addEventListener('fullscreenchange', resolve));
      void document.documentElement.requestFullscreen().then(() => console.log('success')).catch(e => console.log(e));
      return result;
    }
    """)

    assert Page.evaluate!(page, "() => document.fullscreenElement === document.documentElement")

    Page.evaluate!(page, """
    () => {
      const result = new Promise(resolve => document.addEventListener('fullscreenchange', resolve));
      void document.exitFullscreen().then(() => console.log('success')).catch(e => console.log(e));
      return result;
    }
    """)

    refute Page.evaluate!(page, "() => !!document.fullscreenElement")
  end

  test "should send no Content-Length header for GET requests with a Content-Type", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/22569
    Page.goto!(page, server.empty_page)
    request_task = TestServer.wait_for_request(server, "/empty.html")

    Page.evaluate!(page, """
    () => fetch('/empty.html', {
      'headers': { 'Content-Type': 'application/json' },
      'method': 'GET'
    })
    """)

    request = Task.await(request_task, :infinity)
    assert Plug.Conn.get_req_header(request, "content-length") == []
  end

  test "Intl.ListFormat should work", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23978
    Page.goto!(page, server.empty_page)

    formatted =
      Page.evaluate!(page, """
      () => {
        const data = ['first', 'second', 'third'];
        const listFormat = new Intl.ListFormat('en', {
          type: 'disjunction',
          style: 'short',
        });
        return listFormat.format(data);
      }
      """)

    assert formatted == "first, second, or third"
  end

  test "service worker should cover the iframe", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/29267
    TestServer.set_route(server, "/sw.html", fn conn ->
      html(conn, """
        <script>
          window.registrationPromise = navigator.serviceWorker.register('sw.js');
          window.activationPromise = new Promise(resolve => navigator.serviceWorker.oncontrollerchange = resolve);
        </script>
      """)
    end)

    TestServer.set_route(server, "/iframe.html", &html(&1, "<div>from the server</div>"))

    TestServer.set_route(server, "/sw.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.send_resp(200, """
        const kIframeHtml = "<div>from the service worker</div>";

        self.addEventListener('fetch', event => {
          if (event.request.url.endsWith('iframe.html')) {
            const blob = new Blob([kIframeHtml], { type: 'text/html' });
            const response = new Response(blob, { status: 200 , statusText: 'OK' });
            event.respondWith(response);
            return;
          }
          event.respondWith(fetch(event.request));
        });

        self.addEventListener('activate', event => {
          event.waitUntil(clients.claim());
        });
      """)
    end)

    Page.goto!(page, server.prefix <> "/sw.html")
    Page.evaluate!(page, "() => window['activationPromise']")

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.src = '/iframe.html';
      document.body.appendChild(iframe);
    }
    """)

    Expect.to_have_text!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("div"), "from the service worker")
  end

  test "service worker should register in an iframe", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/29267
    TestServer.set_route(server, "/main.html", &html(&1, "<iframe src='/dir/iframe.html'></iframe>"))

    TestServer.set_route(server, "/dir/iframe.html", fn conn ->
      html(conn, """
        <script>
          window.registrationPromise = navigator.serviceWorker.register('sw.js');
          window.activationPromise = new Promise(resolve => navigator.serviceWorker.oncontrollerchange = resolve);
        </script>
      """)
    end)

    TestServer.set_route(server, "/dir/sw.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.send_resp(200, """
        const kIframeHtml = "<div>from the service worker</div>";

        self.addEventListener('fetch', event => {
          if (event.request.url.endsWith('html')) {
            event.respondWith(fetch(event.request));
            return;
          }
          const blob = new Blob(['responseFromServiceWorker'], { type: 'text/plain' });
          const response = new Response(blob, { status: 200 , statusText: 'OK' });
          event.respondWith(response);
        });

        self.addEventListener('activate', event => {
          event.waitUntil(clients.claim());
        });
      """)
    end)

    Page.goto!(page, server.prefix <> "/main.html")
    iframe = Enum.at(Page.frames(page), 1)
    Frame.evaluate!(iframe, "() => window['activationPromise']")

    response =
      Frame.evaluate!(iframe, """
      async () => {
        const response = await fetch('foo.txt');
        return response.text();
      }
      """)

    assert response == "responseFromServiceWorker"
  end

  # it.skip(isFrozenWebkit)  -- not honored: frozen WebKit builds
  @tag skip: if(@is_windows and @browser_name == "webkit", do: "upstream skip: webkit on Windows")
  test "should be able to render avif images", %{page: page, server: server} do
    # annotation: issue https://github.com/microsoft/playwright/issues/32673
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<img src="#{server.prefix}/rgb.avif" onerror="window.error = true">))

    Utils.poll(
      fn -> Locator.bounding_box!(Page.locator(page, "img")) end,
      &assert(match?(%{width: 128, height: 128}, &1))
    )

    assert Page.evaluate!(page, "() => window.error") == nil
  end

  test "should not crash when clicking a label with a <input type=\"file\"/>", %{page: page} do
    # annotation: issue https://github.com/microsoft/playwright/issues/33257
    Page.set_content!(page, """
      <form>
        <label>
          A second file
          <input type="file" />
        </label>
      </form>
    """)

    file_chooser_promise = Page.wait_for_event(page, :file_chooser)
    Locator.click!(Page.get_by_text(page, "A second file"))
    file_chooser = Promise.await!(file_chooser_promise)
    assert FileChooser.page(file_chooser) == page
  end

  test "should not crash when clicking a color input", %{page: page} do
    # annotation: issue https://github.com/microsoft/playwright/issues/33864
    Page.set_content!(page, ~s(<input type="color">))
    input = Page.locator(page, "input")

    Expect.to_be_visible!(input)
    Locator.click!(input)
    Expect.to_be_visible!(input)
  end

  @tag skip:
         (cond do
            @is_windows and @browser_name == "webkit" -> "upstream skip: audio does not play at all"
            System.get_env("PW_CLOCK") == "frozen" -> "upstream skip: no way to inject real setTimeout"
            true -> nil
          end)
  test "should not auto play audio", %{page: page, browser_name: browser_name} do
    # annotation: issue https://github.com/microsoft/playwright/issues/33590
    Page.route!(page, "**/*", fn route ->
      Route.fulfill!(route,
        status: 200,
        content_type: "text/html",
        body: """
        <script>
          async function onLoad() {
            const log = document.getElementById('log');
            const audioContext = new AudioContext();
            const gainNode = new GainNode(audioContext);
            gainNode.connect(audioContext.destination);
            gainNode.gain.value = 0.025;
            const sineNode = new OscillatorNode(audioContext);
            sineNode.connect(gainNode);
            sineNode.start();
            await new Promise((resolve) => setTimeout(resolve, 1000));
            log.innerHTML = 'State: ' + audioContext.state;
          }
        </script>
        <body onload="onLoad()">
        <div id="log"></div>
        </body>
        """
      )
    end)

    Page.goto!(page, "http://127.0.0.1/audio.html")

    if browser_name == "webkit",
      do: Expect.to_have_text!(Page.locator(page, "#log"), ~r/State: (interrupted|suspended)/),
      else: Expect.to_have_text!(Page.locator(page, "#log"), "State: suspended")
  end

  test "should not crash on feature detection for PublicKeyCredential", %{page: page, server: server} do
    # annotation: issue https://github.com/microsoft/playwright/issues/35433
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    async () => {
      await PublicKeyCredential.getClientCapabilities();
      await PublicKeyCredential.isConditionalMediationAvailable();
      await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
    }
    """)
  end
end
