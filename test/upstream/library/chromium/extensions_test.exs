defmodule PlaywrightEx.Library.Chromium.ExtensionsTest do
  @upstream "tests/library/chromium/extensions.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.CDPSession
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils
  alias PlaywrightEx.Worker

  if System.get_env("BROWSER", "chromium") != "chromium", do: @moduletag(skip: "chromium only")

  # it.skip(({ isHeadlessShell }) => isHeadlessShell, 'Headless Shell has no support for extensions'):
  # we run headless Chromium, the headless shell. Deviation: the spec's `launchPersistentContext`
  # fixture launches the `chromium` channel (new headless), which loads extensions, so the
  # tests run.
  defp launch_persistent_context(browser_type, extension_path, options \\ []) do
    extension_options =
      Keyword.merge(options,
        channel: "chromium",
        args: [
          "--disable-extensions-except=#{extension_path}",
          "--load-extension=#{extension_path}"
        ]
      )

    BrowserType.launch_persistent_context!(browser_type, "", extension_options)
  end

  # `serviceWorkers.length ? serviceWorkers[0] : await context.waitForEvent('serviceworker')`: JS
  # reads the list and starts the wait in one tick; holding the baton (an API scope) does the same,
  # so the event can't be dispatched in between.
  defp service_worker(context) do
    Api.call(nil, context, fn ->
      case BrowserContext.service_workers(context) do
        [service_worker | _] -> service_worker
        [] -> context |> BrowserContext.wait_for_event(:service_worker) |> Promise.await!()
      end
    end)
  end

  describe "MV3" do
    # it.skip(({ channel }) => channel?.startsWith('chrome'), '--load-extension is not supported in Chrome anymore. ...')

    # `waitForCdpEvent(event, predicate)`: `cdp.on(event)` forwards the events to the test process
    # (subscribed before `ServiceWorker.enable`); this receives them until `predicate` returns non-nil.
    defp forward_cdp_events(cdp, event) do
      test_pid = self()
      CDPSession.on(cdp, event, fn params -> send(test_pid, {:cdp, event, params}) end)
    end

    defp wait_for_cdp_event(event, predicate) do
      receive do
        {:cdp, ^event, params} ->
          case predicate.(params) do
            nil -> wait_for_cdp_event(event, predicate)
            result -> result
          end
      after
        10_000 -> flunk("timed out waiting for #{event}")
      end
    end

    defp first(list), do: List.first(list) || %{}

    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/39475' }
    test "should support service worker stop and restart lifecycle", %{browser_type: browser_type, asset: asset} do
      extension_path = asset.("extension-mv3-sw-lifecycle")
      context = launch_persistent_context(browser_type, extension_path)

      sw1 = service_worker(context)
      start_time1 = Worker.evaluate!(sw1, "() => globalThis.startTime")

      # stopWorker keeps the same CDP target alive, matching Chrome's natural idle suspension behavior.
      page = BrowserContext.new_page!(context)
      cdp = BrowserContext.new_cdp_session!(context, page)
      forward_cdp_events(cdp, "ServiceWorker.workerVersionUpdated")
      forward_cdp_events(cdp, "ServiceWorker.workerRegistrationUpdated")

      CDPSession.send!(cdp, "ServiceWorker.enable")

      version_id =
        wait_for_cdp_event("ServiceWorker.workerVersionUpdated", &first(&1["versions"])["versionId"])

      scope_url =
        wait_for_cdp_event("ServiceWorker.workerRegistrationUpdated", &first(&1["registrations"])["scopeURL"])

      CDPSession.send!(cdp, "ServiceWorker.stopWorker", %{versionId: version_id})

      wait_for_cdp_event(
        "ServiceWorker.workerVersionUpdated",
        &if(first(&1["versions"])["runningStatus"] == "stopped", do: true)
      )

      CDPSession.send!(cdp, "ServiceWorker.startWorker", %{scopeURL: scope_url})

      wait_for_cdp_event(
        "ServiceWorker.workerVersionUpdated",
        &if(first(&1["versions"])["runningStatus"] == "running", do: true)
      )

      start_time2 = Worker.evaluate!(sw1, "() => globalThis.startTime")
      assert start_time2 > start_time1
      # same object, no new event
      assert BrowserContext.service_workers(context) == [sw1]

      BrowserContext.close!(context)
    end

    test "should give access to the service worker", %{browser_type: browser_type, asset: asset} do
      extension_path = asset.("extension-mv3-simple")
      context = launch_persistent_context(browser_type, extension_path)
      service_worker = service_worker(context)
      assert service_worker
      assert service_worker in BrowserContext.service_workers(context)
      Utils.poll(fn -> Worker.evaluate!(service_worker, "() => globalThis.MAGIC") end, &assert(&1 == 42))
      BrowserContext.close!(context)
      assert BrowserContext.background_pages(context) == []
    end

    @tag :tmp_dir
    test "should give access to the service worker when recording video", %{
      browser_type: browser_type,
      asset: asset,
      tmp_dir: tmp_dir
    } do
      extension_path = asset.("extension-mv3-simple")
      context = launch_persistent_context(browser_type, extension_path, record_video: %{dir: tmp_dir})
      service_worker = service_worker(context)
      assert service_worker
      assert service_worker in BrowserContext.service_workers(context)
      Utils.poll(fn -> Worker.evaluate!(service_worker, "() => globalThis.MAGIC") end, &assert(&1 == 42))
      BrowserContext.close!(context)
    end

    test "should support request/response events in the service worker", %{
      browser_type: browser_type,
      asset: asset,
      server: server
    } do
      # it.skip(browserMajorVersion < 143, 'needs workerScriptLoaded event');
      TestServer.set_route(server, "/empty.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.put_resp_header("x-response-foobar", "BarFoo")
        |> Plug.Conn.send_resp(200, "<span>hello world!</span>")
      end)

      extension_path = asset.("extension-mv3-simple")
      context = launch_persistent_context(browser_type, extension_path)
      service_worker = service_worker(context)
      assert Worker.url(service_worker) =~ ~r/chrome-extension\:\/\/.*/
      request = BrowserContext.wait_for_event(context, :request)
      response = BrowserContext.wait_for_event(context, :response)

      Worker.evaluate!(
        service_worker,
        """
        url => fetch(url, {
          method: 'POST',
          body: 'foobar',
          headers: { 'X-FOOBAR': 'KEKBAR' }
        })
        """,
        server.empty_page
      )

      request = Promise.await!(request)
      response = Promise.await!(response)
      assert Request.url(request) == server.empty_page
      assert Request.method(request) == "POST"
      assert %{"x-foobar" => "KEKBAR"} = Request.all_headers!(request)
      assert Request.post_data(request) == "foobar"

      assert Response.status(response) == 200
      assert Response.url(response) == server.empty_page
      assert Response.request(response) == request
      assert Response.text!(response) == "<span>hello world!</span>"
      assert %{"x-response-foobar" => "BarFoo"} = Response.all_headers!(response)

      BrowserContext.close!(context)
    end

    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/32762' }
    test "should report console messages from content script", %{
      browser_type: browser_type,
      asset: asset,
      server: server
    } do
      extension_path = asset.("extension-mv3-with-logging")
      context = launch_persistent_context(browser_type, extension_path)
      page = BrowserContext.new_page!(context)

      console_promise =
        Page.wait_for_event(page, :console,
          predicate: &(ConsoleMessage.text(&1) =~ "Test console log from a third-party execution context")
        )

      Page.goto!(page, server.empty_page)
      message = Promise.await!(console_promise)
      assert ConsoleMessage.text(message) =~ "Test console log from a third-party execution context"
      BrowserContext.close!(context)
    end

    test "should use custom userAgent in service worker fetch requests", %{
      browser_type: browser_type,
      asset: asset,
      server: server
    } do
      TestServer.set_route(server, "/ua-echo", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(200, conn |> Plug.Conn.get_req_header("user-agent") |> List.first())
      end)

      extension_path = asset.("extension-mv3-simple")
      context = launch_persistent_context(browser_type, extension_path, user_agent: "MyTestAgent/1.0")
      sw = service_worker(context)

      user_agent =
        Worker.evaluate!(
          sw,
          """
          async url => {
            const response = await fetch(url);
            return response.text();
          }
          """,
          server.prefix <> "/ua-echo"
        )

      assert user_agent == "MyTestAgent/1.0"
      BrowserContext.close!(context)
    end
  end
end
