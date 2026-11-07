defmodule PlaywrightEx.Library.BrowsercontextServiceWorkerPolicyTest do
  @upstream "tests/library/browsercontext-service-worker-policy.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Response
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  @moduletag :page

  test "WO-027 should allow service workers by default", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    Utils.assert_truthy(Page.evaluate!(page, "() => window['registrationPromise']"))
  end

  for {mode, worker_response} <- [
        {"literal", "new Response('<h1>offline</h1>', { headers: { 'Content-Type': 'text/html' } })"},
        {"cache-only", "caches.match('/offline.html')"},
        {"network-fallback", "fetch(event.request).catch(() => caches.match('/offline.html'))"},
        {"preload-fallback",
         """
         (async () => {
             try {
               return await event.preloadResponse || await fetch(event.request);
             } catch {
               return caches.match('/offline.html');
             }
           })()\
         """}
      ] do
    @mode mode
    @worker_response worker_response
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42775' }
    @tag skip:
           if(@browser_name == "firefox" and @mode in ["network-fallback", "preload-fallback"],
             do: "upstream fixme: Firefox does not apply offline emulation to service worker requests."
           )
    test "WO-028 should allow #{mode} service worker navigation while offline", %{
      context: context,
      page: page,
      server: server
    } do
      # it.skip(isElectron); it.skip(isFrozenWebkit, ...): neither applies here.
      # it.fixme(browserName === 'firefox' && (mode === 'network-fallback' || mode === 'preload-fallback'),
      #   'Firefox does not apply offline emulation to service worker requests.')
      network_requests = :counters.new(1, [])

      TestServer.set_route(server, "/target.html", fn conn ->
        :counters.add(network_requests, 1, 1)

        conn
        |> Plug.Conn.put_resp_header("cache-control", "no-store")
        |> Plug.Conn.send_resp(200, "online")
      end)

      TestServer.set_route(server, "/offline.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.send_resp(200, "<h1>offline</h1>")
      end)

      TestServer.set_route(server, "/sw.js", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/javascript")
        |> Plug.Conn.send_resp(200, """
          self.addEventListener('install', event => event.waitUntil((async () => {
            const cache = await caches.open('offline');
            await cache.add('/offline.html');
            await self.skipWaiting();
          })()));
          self.addEventListener('activate', event => event.waitUntil((async () => {
            #{if @mode == "preload-fallback", do: "await self.registration.navigationPreload.enable();", else: ""}
            await self.clients.claim();
          })()));
          self.addEventListener('fetch', event => {
            if (event.request.mode === 'navigate')
              event.respondWith(#{@worker_response});
          });
        """)
      end)

      Page.goto!(page, server.empty_page)

      Page.evaluate!(page, """
      async () => {
        await navigator.serviceWorker.register('/sw.js');
        await navigator.serviceWorker.ready;
      }
      """)

      Page.wait_for_function!(page, "() => !!navigator.serviceWorker.controller")
      BrowserContext.set_offline!(context, true)

      response = Page.goto!(page, server.prefix <> "/target.html")
      assert Response.status(response) == 200
      assert Response.from_service_worker(response) == true
      Expect.to_have_text!(Page.locator(page, "h1"), "offline")
      assert Page.evaluate!(page, "() => navigator.onLine") == false
      assert :counters.get(network_requests, 1) == 0

      new_page = BrowserContext.new_page!(context)
      new_response = Page.goto!(new_page, server.prefix <> "/target.html")
      assert Response.status(new_response) == 200
      assert Response.from_service_worker(new_response) == true
      Expect.to_have_text!(Page.locator(new_page, "h1"), "offline")
      assert Page.evaluate!(new_page, "() => navigator.onLine") == false
      assert :counters.get(network_requests, 1) == 0

      BrowserContext.set_offline!(context, false)

      assert Page.evaluate!(page, "() => fetch('/target.html').then(response => response.text())") ==
               "online"

      assert :counters.get(network_requests, 1) == 1
    end
  end

  describe "block" do
    # it.use({ serviceWorkers: 'block' })
    setup %{context_factory: context_factory} do
      context = context_factory.(service_workers: :block)
      %{context: context, page: BrowserContext.new_page!(context)}
    end

    test "WO-029 blocks service worker registration", %{page: page, server: server} do
      console_promise =
        Page.wait_for_event(page, :console,
          predicate: fn evt -> ConsoleMessage.text(evt) == "Service Worker registration blocked by Playwright" end
        )

      Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
      Promise.await!(console_promise)
    end

    test "WO-030 should not throw error on about:blank", %{page: page} do
      # issue: https://github.com/microsoft/playwright/issues/32292
      test_pid = self()
      Page.on(page, :page_error, fn error -> send(test_pid, {:page_error, error}) end)
      Page.goto!(page, "about:blank")
      refute_received {:page_error, _}
    end

    test "WO-031 should not throw error in opaque sandboxed iframe", %{page: page, server: server} do
      # issue: https://github.com/microsoft/playwright/issues/43113
      test_pid = self()
      Page.on(page, :page_error, fn error -> send(test_pid, {:page_error, error}) end)
      Page.goto!(page, server.empty_page)
      Page.set_content!(page, ~s(<iframe sandbox="allow-scripts" srcdoc="<p>Preview</p>"></iframe>))
      Expect.to_have_text!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("p"), "Preview")
      refute_received {:page_error, _}
    end
  end
end
