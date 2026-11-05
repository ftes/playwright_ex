defmodule PlaywrightEx.Library.BrowsercontextReuseTest do
  @upstream "tests/library/browsercontext-reuse.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [verify_viewport: 3]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client
  alias PlaywrightEx.Clock
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.RemoteServer.LaunchServer
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Utils
  alias PlaywrightEx.WebSocketRoute

  # class LaunchScenario: `browser._disconnectFromReusedContext` / `_newContextForReuse` are
  # internal client methods (not in the facade), called inside an API scope as the facade does.
  # `this._browserType._instrumentation.runBeforeCreateBrowserContext(defaultContextOptions)` is
  # the test runner's hook (it adds the configured context options; there are none here).
  defp launch_scenario(browser_type) do
    {:ok, state} = Agent.start(fn -> %{browser_type: browser_type, browser: nil, context: nil} end)

    close = fn ->
      if browser = Agent.get(state, & &1.browser), do: Browser.close(browser)
      Agent.stop(state)
    end

    {&reused_context(state, &1), close}
  end

  defp browser(state) do
    if browser = Agent.get(state, & &1.browser) do
      browser
    else
      browser = BrowserType.launch!(Agent.get(state, & &1.browser_type))
      Agent.update(state, &%{&1 | browser: browser})
      browser
    end
  end

  defp reused_context(state, options) do
    browser = browser(state)

    if Agent.get(state, & &1.context),
      do: Api.call(nil, browser, fn -> Client.Browser._disconnect_from_reused_context(browser, "reusedContext") end)

    context = Api.call(nil, browser, fn -> Client.Browser._new_context_for_reuse(browser, options || %{}) end)
    Agent.update(state, &%{&1 | context: context})
    context
  end

  # class ConnectScenario: `browserType.launchServer()` is the `launch_server` fixture (the
  # driver's `launch-server` command).
  defp connect_scenario(browser_type, launch_server) do
    {:ok, state} = Agent.start(fn -> %{browser_type: browser_type, server: nil, browser: nil} end)

    close = fn ->
      if browser = Agent.get(state, & &1.browser), do: Browser.close(browser)
      if server = Agent.get(state, & &1.server), do: LaunchServer.close(server)
      Agent.stop(state)
    end

    {&connect_reused_context(state, launch_server, &1), close}
  end

  defp server(state, launch_server) do
    if server = Agent.get(state, & &1.server) do
      server
    else
      {:ok, server} = launch_server.(%{})
      Agent.update(state, &%{&1 | server: server})
      server
    end
  end

  defp connect_reused_context(state, launch_server, options) do
    server = server(state, launch_server)
    if browser = Agent.get(state, & &1.browser), do: Browser.close!(browser)
    browser = BrowserType.connect!(Agent.get(state, & &1.browser_type), LaunchServer.ws_endpoint(server))
    Agent.update(state, &%{&1 | browser: browser})
    Api.call(nil, browser, fn -> Client.Browser._new_context_for_reuse(browser, options || %{}) end)
  end

  # `window.log`
  defp log(page), do: Page.evaluate!(page, "() => window.log")

  for scenario <- ["launch", "connect"] do
    describe "reuse " <> scenario do
      # test.skip(({ mode }) => mode !== 'default' && scenario === 'connect');  -- always default mode
      # test.fixme(({ channel }) => channel?.startsWith('msedge'), ...)  -- we run no channel
      @describetag scenario: scenario

      setup %{browser_type: browser_type, launch_server: launch_server, scenario: scenario} do
        {reused_context, close} =
          if scenario == "launch",
            do: launch_scenario(browser_type),
            else: connect_scenario(browser_type, launch_server)

        on_exit(close)
        %{reused_context: reused_context}
      end

      test "should re-add binding after reset", %{reused_context: reused_context} do
        context = reused_context.(nil)

        BrowserContext.expose_function!(context, "add", fn a, b -> a - b end)

        page = BrowserContext.new_page!(context)
        assert Page.evaluate!(page, "add(7, 6)") == 1

        context = reused_context.(nil)

        BrowserContext.expose_function!(context, "add", fn a, b -> a + b end)

        page = hd(BrowserContext.pages(context))
        assert Page.evaluate!(page, "add(5, 6)") == 11
        Page.reload!(page)
        assert Page.evaluate!(page, "add(5, 6)") == 11
      end

      test "should reset serviceworker", %{reused_context: reused_context, server: server} do
        TestServer.set_route(server, "/page.html", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.send_resp(200, """
            <title>Page Title</title>
            <script>
              navigator.serviceWorker.register('sw.js');
              window.activationPromise = new Promise(resolve => navigator.serviceWorker.oncontrollerchange = resolve);
            </script>
          """)
        end)

        TestServer.set_route(server, "/sw.js", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/javascript")
          |> Plug.Conn.send_resp(200, """
            self.addEventListener('fetch', event => {
              const blob = new Blob(['<title>Wrong Title</title>'], { type : 'text/html' });
              const response = new Response(blob, { status: 200 , statusText: 'OK' });
              event.respondWith(response);
            });

            self.addEventListener('activate', event => {
              event.waitUntil(clients.claim());
            });
          """)
        end)

        context = reused_context.(nil)
        page = BrowserContext.new_page!(context)
        Page.goto!(page, server.prefix <> "/page.html")
        Expect.to_have_title!(page, "Page Title")
        Page.evaluate!(page, "() => window['activationPromise']")

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        Page.goto!(page, server.prefix <> "/page.html")
        Expect.to_have_title!(page, "Page Title")
      end

      test "should reset serviceworker that hangs in importScripts", %{reused_context: reused_context, server: server} do
        TestServer.set_route(server, "/page.html", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.send_resp(200, """
            <title>Page Title</title>
            <script>
              navigator.serviceWorker.register('sw.js');
            </script>
          """)
        end)

        TestServer.set_route(server, "/sw.js", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/javascript")
          |> Plug.Conn.send_resp(200, """
            importScripts('helper.js');

            self.addEventListener('fetch', event => {
              const blob = new Blob(['<title>Wrong Title</title>'], { type : 'text/html' });
              const response = new Response(blob, { status: 200 , statusText: 'OK' });
              event.respondWith(response);
            });

            self.addEventListener('activate', event => {
              event.waitUntil(clients.claim());
            });
          """)
        end)

        TestServer.set_route(server, "/helper.js", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/javascript")
          # Sending excessive content length makes importScripts hang for
          # 5 seconds in Chromium, 6 seconds in Firefox and long time in WebKit.
          |> Plug.Conn.put_resp_header("content-length", "1000")
          |> Plug.Conn.send_resp(200, "1")
        end)

        context = reused_context.(nil)
        page = BrowserContext.new_page!(context)
        Page.goto!(page, server.prefix <> "/page.html")
        Expect.to_have_title!(page, "Page Title")

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        Page.goto!(page, server.prefix <> "/page.html")
        Expect.to_have_title!(page, "Page Title")
      end

      test "should not cache resources", %{reused_context: reused_context, server: server} do
        # test.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/19926' });
        {:ok, request_count_map} = Agent.start_link(fn -> %{} end)
        increment = fn url -> Agent.update(request_count_map, &Map.update(&1, url, 1, fn c -> c + 1 end)) end
        get = fn url -> Agent.get(request_count_map, & &1[url]) end

        TestServer.set_route(server, "/page.html", fn conn ->
          request_count = get.(conn.request_path) || 0
          # Counted before the response is sent: node's `res.end` flushes after the handler returns.
          increment.(conn.request_path)

          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.put_resp_header("cache-control", "max-age=3600")
          |> Plug.Conn.send_resp(200, """
          <!DOCTYPE html>
          <html>
            <head>
              <meta charset="UTF-8">
              <title>Count: #{request_count}</title>
              <link rel="stylesheet" href="style.css">
              <script>
                fetch('simple.json').then(() => {});
              </script>
            </head>
          </html>
          """)
        end)

        TestServer.set_route(server, "/style.css", fn conn ->
          increment.(conn.request_path)

          conn
          |> Plug.Conn.put_resp_header("content-type", "text/css")
          |> Plug.Conn.put_resp_header("cache-control", "max-age=3600")
          |> Plug.Conn.send_resp(200, "body { background-color: red; }")
        end)

        TestServer.set_route(server, "/simple.json", fn conn ->
          increment.(conn.request_path)

          conn
          |> Plug.Conn.put_resp_header("cache-control", "max-age=3600")
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(200, ~s({ "foo": "bar" }))
        end)

        context = reused_context.(nil)
        page = BrowserContext.new_page!(context)
        Page.goto!(page, server.prefix <> "/page.html")
        Expect.to_have_title!(page, "Count: 0")
        assert get.("/page.html") == 1
        assert get.("/style.css") == 1
        assert get.("/simple.json") == 1

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        Page.goto!(page, server.prefix <> "/page.html")
        Expect.to_have_title!(page, "Count: 1")
        assert get.("/page.html") == 2
        assert get.("/style.css") == 2
        assert get.("/simple.json") == 2
      end

      test "should ignore binding from beforeunload", %{reused_context: reused_context} do
        # test.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/22803' });

        context = reused_context.(nil)

        me = self()
        BrowserContext.expose_function!(context, "binding", fn -> send(me, :called) end)

        page = BrowserContext.new_page!(context)

        Page.evaluate!(page, """
        () => {
          window.addEventListener('beforeunload', () => window['binding']());
        }
        """)

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        Page.set_content!(page, "hello")

        refute_received :called
      end

      # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/22432' }
      test "should reset mouse position", %{reused_context: reused_context} do
        # Note: this test only reproduces the issue locally when run with --repeat-each=20.
        # test.skip(!headless, 'headed browser has mouse jiggles');  -- we run headless

        page_content = """
          <style>
            div { height: 30px; background: blue; }
            div:hover { background: red; }
            html, body { margin: 0; padding: 0; }
          </style>
          <div id=filler>one</div>
          <div id=one>one</div>
          <div id=two>two</div>
        """

        context = reused_context.(nil)
        page = BrowserContext.new_page!(context)
        Page.set_content!(page, page_content)
        Expect.to_have_css!(Page.locator(page, "#one"), "background-color", "rgb(0, 0, 255)")
        Expect.to_have_css!(Page.locator(page, "#two"), "background-color", "rgb(0, 0, 255)")

        Mouse.move!(Page.mouse(page), 10, 75)
        Expect.to_have_css!(Page.locator(page, "#one"), "background-color", "rgb(0, 0, 255)")
        Expect.to_have_css!(Page.locator(page, "#two"), "background-color", "rgb(255, 0, 0)")

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        Page.set_content!(page, page_content)
        Expect.to_have_css!(Page.locator(page, "#one"), "background-color", "rgb(0, 0, 255)")
        Expect.to_have_css!(Page.locator(page, "#two"), "background-color", "rgb(0, 0, 255)")
      end

      @tag :tmp_dir
      test "should reset tracing", %{reused_context: reused_context, tmp_dir: tmp_dir} do
        # test.skip(trace === 'on');  -- no runner tracing

        context = reused_context.(nil)
        Tracing.start!(BrowserContext.tracing(context))

        page = BrowserContext.new_page!(context)
        Page.evaluate!(page, "1 + 1")

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        Page.evaluate!(page, "2 + 2")

        {:error, error} = Tracing.stop_chunk(BrowserContext.tracing(context), path: Path.join(tmp_dir, "trace.zip"))
        assert Exception.message(error) =~ "Must start tracing before stopping"
      end

      test "should work with clock emulation", %{reused_context: reused_context} do
        context = reused_context.(nil)

        page = BrowserContext.new_page!(context)
        Clock.set_fixed_time!(Page.clock(page), ~U[2020-01-01 00:00:00.000Z])
        assert Page.evaluate!(page, "new Date().toISOString()") == "2020-01-01T00:00:00.000Z"

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        Clock.set_fixed_time!(Page.clock(page), ~U[2020-01-01 00:00:00Z])
        assert Page.evaluate!(page, "new Date().toISOString()") == "2020-01-01T00:00:00.000Z"
      end

      test "should continue issuing events after closing the reused page", %{
        reused_context: reused_context,
        server: server
      } do
        # test.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/24574' });

        context = reused_context.(nil)
        page = BrowserContext.new_page!(context)
        request = Page.wait_for_request(page, server.prefix <> "/one-style.css")
        Page.goto!(page, server.prefix <> "/one-style.html")
        Promise.await!(request)
        Page.close!(page)

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        request = Page.wait_for_request(page, server.prefix <> "/one-style.css", timeout: 10_000)
        Page.goto!(page, server.prefix <> "/one-style.html")
        Promise.await!(request)
      end

      # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/36480' }
      test "should work with routeWebSocket", %{reused_context: reused_context, server: server} do
        setup = fn page, suffix ->
          Page.route_web_socket!(page, ~r/ws1/, fn ws ->
            WebSocketRoute.on_message(ws, fn _message ->
              WebSocketRoute.send(ws, "page-mock-" <> suffix)
            end)
          end)

          page
          |> Page.context()
          |> BrowserContext.route_web_socket!(~r/.*/, fn ws ->
            server = WebSocketRoute.connect_to_server(ws)

            WebSocketRoute.on_message(ws, fn _message ->
              WebSocketRoute.send(ws, "context-mock-" <> suffix)
            end)

            WebSocketRoute.on_message(server, fn message -> WebSocketRoute.send(ws, message) end)
          end)

          Page.goto!(page, server.empty_page)

          Page.evaluate!(
            page,
            """
            host => {
              window.log = [];
              window.ws1 = new WebSocket('ws://' + host + '/ws1');
              window.ws1.addEventListener('message', event => window.log.push(`ws1:${event.data}`));
              window.ws = new WebSocket('ws://' + host + '/ws');
              window.ws.addEventListener('message', event => window.log.push(`ws:${event.data}`));
            }
            """,
            server.host
          )
        end

        context = reused_context.(nil)
        page = BrowserContext.new_page!(context)
        ws_promise = TestServer.wait_for_web_socket(server)
        setup.(page, "before")
        ws = Task.await(ws_promise, :infinity)
        Page.evaluate!(page, "() => window.ws1.send('request')")
        Utils.poll(fn -> log(page) end, &assert(&1 == ["ws1:page-mock-before"]))
        Page.evaluate!(page, "() => window.ws.send('request')")
        Utils.poll(fn -> log(page) end, &assert(&1 == ["ws1:page-mock-before", "ws:context-mock-before"]))
        TestServer.WebSocket.send(ws, "hi")

        Utils.poll(
          fn -> log(page) end,
          &assert(&1 == ["ws1:page-mock-before", "ws:context-mock-before", "ws:hi"])
        )

        context = reused_context.(nil)
        page = hd(BrowserContext.pages(context))
        new_ws_promise = TestServer.wait_for_web_socket(server)
        setup.(page, "after")
        new_ws = Task.await(new_ws_promise, :infinity)
        Page.evaluate!(page, "() => window.ws1.send('request')")
        Utils.poll(fn -> log(page) end, &assert(&1 == ["ws1:page-mock-after"]))
        Page.evaluate!(page, "() => window.ws.send('request')")
        Utils.poll(fn -> log(page) end, &assert(&1 == ["ws1:page-mock-after", "ws:context-mock-after"]))
        TestServer.WebSocket.send(new_ws, "hello")

        Utils.poll(
          fn -> log(page) end,
          &assert(&1 == ["ws1:page-mock-after", "ws:context-mock-after", "ws:hello"])
        )
      end

      test "should update viewport and media", %{reused_context: reused_context} do
        # Internal client call: options with JS keys.
        context = reused_context.(%{viewport: %{width: 800, height: 600}, colorScheme: "dark"})
        page = BrowserContext.new_page!(context)
        assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches") == true
        verify_viewport(page, 800, 600)
        Page.close!(page)

        context = reused_context.(%{viewport: %{width: 600, height: 800}, colorScheme: "light"})
        page = BrowserContext.new_page!(context)
        assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: light)').matches") == true
        verify_viewport(page, 600, 800)
      end
    end
  end
end
