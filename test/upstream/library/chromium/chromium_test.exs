defmodule PlaywrightEx.Library.Chromium.ChromiumTest do
  @upstream "tests/library/chromium/chromium.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.CDPSession
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils
  alias PlaywrightEx.Worker

  @chromium_only if(System.get_env("BROWSER", "chromium") != "chromium", do: "upstream skip: chromium only")
  @moduletag skip: @chromium_only

  # Deviations:
  #   * `Promise.all([context.waitForEvent(...), page.goto(...)])` starts the waits (promise
  #     handles), then runs the action, then awaits them.

  # Chromium on Linux intermittently never sends the service worker main script's
  # Network.responseReceived (its request and loadingFinished arrive), so that response never
  # resolves. Upstream's own client hits it too (~3% of runs in a loop); upstream CI retries.
  # A test's `skip: nil` would override the `@moduletag skip:`.
  @sw_script_response_skip @chromium_only ||
                             if(match?({:unix, :linux}, :os.type()),
                               do: "ci: Linux chromium intermittently drops the service worker script response"
                             )

  defp req_header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defp wait_for_service_worker(context), do: BrowserContext.wait_for_event(context, :service_worker)

  defp wait_for_request(context, predicate), do: BrowserContext.wait_for_event(context, :request, predicate)

  defp wait_for_response(context, predicate),
    do: BrowserContext.wait_for_event(context, :response, predicate)

  # `r.url().endsWith(suffix)` of a request or response.
  defp url_ends_with?(%PlaywrightEx.Request{} = r, suffix), do: String.ends_with?(Request.url(r), suffix)
  defp url_ends_with?(%PlaywrightEx.Response{} = r, suffix), do: String.ends_with?(Response.url(r), suffix)

  defp js_response(conn, body) do
    conn |> Plug.Conn.put_resp_header("content-type", "text/javascript") |> Plug.Conn.send_resp(200, body)
  end

  @update_demo_html """

        <!DOCTYPE html>
        <html>
          <head>
            <title>Service Worker Update Demo</title>
          </head>
          <body>
            <button id="update" disabled>update service worker</button>
            <script>
              const updateBtn = document.getElementById('update');
              updateBtn.addEventListener('click', evt => {
                evt.preventDefault();
                registration.then(r => r.update());
              });

              const registration = new Promise(r => navigator.serviceWorker.register('/worker.js').then(r));
              registration.then(() => updateBtn.disabled = false);
            </script>
          </body>
        </html>
  """

  @tag :page
  test "should create a worker from a service worker", %{page: page, server: server} do
    worker = wait_for_service_worker(Page.context(page))
    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    worker = Promise.await!(worker)
    assert Worker.evaluate!(worker, "() => self.toString()") == "[object ServiceWorkerGlobalScope]"
  end

  @tag :page
  test "should create a worker from service worker with noop routing", %{context: context, page: page, server: server} do
    BrowserContext.route!(context, "**", fn route -> Route.continue(route) end)
    worker = wait_for_service_worker(Page.context(page))
    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    worker = Promise.await!(worker)
    assert Worker.evaluate!(worker, "() => self.toString()") == "[object ServiceWorkerGlobalScope]"
  end

  @tag :page
  test "should emit new service worker on update", %{context: context, page: page, server: server} do
    version = :counters.new(1, [])

    TestServer.set_route(server, "/worker.js", fn conn ->
      v = :counters.get(version, 1)
      :counters.add(version, 1, 1)
      js_response(conn, "self.PW_VERSION = #{v};")
    end)

    TestServer.set_route(server, "/home", fn conn -> Plug.Conn.send_resp(conn, 200, @update_demo_html) end)

    sw = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/home")
    sw = Promise.await!(sw)

    Utils.poll(fn -> Worker.evaluate!(sw, "() => self['PW_VERSION']") end, &assert(&1 == 0))

    updated_sw = wait_for_service_worker(context)
    Page.click!(page, "#update")
    updated_sw = Promise.await!(updated_sw)

    Utils.poll(fn -> Worker.evaluate!(updated_sw, "() => self['PW_VERSION']") end, &assert(&1 == 1))
  end

  describe "http credentials" do
    # test.use({ httpCredentials: { username: 'user',  password: 'pass' } })
    test "httpCredentials", %{context_factory: context_factory, server: server} do
      context = context_factory.(http_credentials: %{username: "user", password: "pass"})
      page = BrowserContext.new_page!(context)
      TestServer.set_auth(server, "/serviceworkers/fetch/sw.html", "user", "pass")
      TestServer.set_auth(server, "/empty.html", "user", "pass")
      worker = wait_for_service_worker(context)
      Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
      worker = Promise.await!(worker)

      Page.evaluate!(page, "() => window['activationPromise']")
      assert Worker.evaluate!(worker, "() => fetch('/empty.html').then(r => r.status)") == 200
    end
  end

  @tag :page
  test "serviceWorkers() should return current workers", %{page: page, server: server} do
    context = Page.context(page)
    worker1 = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    worker1 = Promise.await!(worker1)
    workers = BrowserContext.service_workers(context)
    assert length(workers) == 1

    worker2 = wait_for_service_worker(context)
    Page.goto!(page, server.cross_process_prefix <> "/serviceworkers/empty/sw.html")
    worker2 = Promise.await!(worker2)
    workers = BrowserContext.service_workers(context)
    assert length(workers) == 2
    assert worker1 in workers
    assert worker2 in workers
  end

  @tag :page
  test "should not create a worker from a shared worker", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    test_pid = self()
    BrowserContext.once(Page.context(page), :service_worker, fn _ -> send(test_pid, :service_worker_created) end)

    Page.evaluate!(page, """
    () => {
      new SharedWorker('data:text/javascript,console.log("hi")');
    }
    """)

    refute_received :service_worker_created
  end

  @tag :page
  test "Page.route should work with intervention headers", %{server: server, page: page} do
    TestServer.set_route(server, "/intervention", fn conn ->
      Plug.Conn.send_resp(conn, 200, """

          <script>
            document.write('<script src="#{server.cross_process_prefix}/intervention.js">' + '</scr' + 'ipt>');
          </script>
      """)
    end)

    TestServer.set_redirect(server, "/intervention.js", "/redirect.js")
    test_pid = self()

    TestServer.set_route(server, "/redirect.js", fn conn ->
      send(test_pid, {:server_request, conn})
      Plug.Conn.send_resp(conn, 200, "console.log(1);")
    end)

    Page.route!(page, "*", fn route -> Route.continue(route) end)
    Page.goto!(page, server.prefix <> "/intervention")
    # Check for feature URL substring rather than https://www.chromestatus.com to
    # make it work with Edgium.
    assert_received {:server_request, server_request}
    assert req_header(server_request, "intervention") =~ "feature/5718547946799104"
  end

  test "should close service worker together with the context", %{browser_type: browser_type, server: server} do
    browser = BrowserType.launch!(browser_type)
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    worker = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    worker = Promise.await!(worker)
    test_pid = self()
    BrowserContext.on(context, :close, fn _ -> send(test_pid, {:message, "context"}) end)
    Worker.on(worker, :close, fn _ -> send(test_pid, {:message, "worker"}) end)
    BrowserContext.close!(context)
    assert Enum.join(received_messages(), "|") == "worker|context"
    Browser.close!(browser)
  end

  defp received_messages do
    receive do
      {:message, message} -> [message | received_messages()]
    after
      0 -> []
    end
  end

  test "should pass args with spaces", %{browser_type: browser_type, create_user_data_dir: create_user_data_dir} do
    browser =
      BrowserType.launch_persistent_context!(browser_type, create_user_data_dir.(), args: ["--user-agent=I am Foo"])

    page = BrowserContext.new_page!(browser)
    user_agent = Page.evaluate!(page, "() => navigator.userAgent")
    BrowserContext.close!(browser)
    assert user_agent == "I am Foo"
  end

  @tag :page
  @tag skip: @sw_script_response_skip
  test "serviceWorker(), and fromServiceWorker() work", %{context: context, page: page, server: server} do
    worker = wait_for_service_worker(context)
    html = wait_for_request(context, &url_ends_with?(&1, "/sw.html"))
    main = wait_for_request(context, &url_ends_with?(&1, "/sw.js"))
    in_worker = wait_for_request(context, &url_ends_with?(&1, "/request-from-within-worker.txt"))
    Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
    [worker, html, main, in_worker] = Enum.map([worker, html, main, in_worker], &Promise.await!/1)

    assert Request.frame(html)
    assert Request.service_worker(html) == nil
    assert Response.from_service_worker(Request.response!(html)) == false

    assert_raise RuntimeError, fn -> Request.frame(main) end
    assert Request.service_worker(main) == worker
    assert Response.from_service_worker(Request.response!(main)) == false

    assert_raise RuntimeError, fn -> Request.frame(in_worker) end
    assert Request.service_worker(in_worker) == worker
    assert Response.from_service_worker(Request.response!(in_worker)) == false

    Page.evaluate!(page, "() => window['activationPromise']")
    inner_sw = wait_for_request(context, &(url_ends_with?(&1, "/inner.txt") and Request.service_worker(&1) != nil))
    inner_page = wait_for_request(context, &(url_ends_with?(&1, "/inner.txt") and Request.service_worker(&1) == nil))
    Page.evaluate!(page, "() => fetch('/inner.txt')")
    [inner_sw, inner_page] = Enum.map([inner_sw, inner_page], &Promise.await!/1)
    assert Request.service_worker(inner_page) == nil
    assert Response.from_service_worker(Request.response!(inner_page)) == true

    assert Request.service_worker(inner_sw) == worker
    assert Response.from_service_worker(Request.response!(inner_sw)) == false
  end

  @tag skip: @sw_script_response_skip
  @tag :page
  test "should intercept service worker requests (main and within)", %{context: context, page: page, server: server} do
    BrowserContext.route!(context, "**/request-from-within-worker", fn route ->
      Route.fulfill(route, content_type: "application/json", status: 200, body: ~s("intercepted!"))
    end)

    BrowserContext.route!(context, "**/sw.js", fn route ->
      Route.fulfill(route,
        content_type: "text/javascript",
        status: 200,
        body: """

                  self.contentPromise = new Promise(res => fetch('/request-from-within-worker').then(r => r.json()).then(res));
        """
      )
    end)

    promises = [
      wait_for_service_worker(context),
      wait_for_response(context, &url_ends_with?(&1, "/request-from-within-worker")),
      wait_for_request(context, &(url_ends_with?(&1, "sw.js") and Request.service_worker(&1) != nil)),
      wait_for_response(context, &(url_ends_with?(&1, "sw.js") and !Response.from_service_worker(&1)))
    ]

    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    [sw | _] = Enum.map(promises, &Promise.await!/1)

    assert Worker.evaluate!(sw, "() => self['contentPromise']") == "intercepted!"
  end

  @tag :page
  test "should report failure (due to content-type) of main service worker request", %{
    server: server,
    page: page,
    context: context
  } do
    # test.skip(browserMajorVersion < 104, 'Requires http://crrev.com/1012503 or later.');
    TestServer.set_route(server, "/serviceworkers/fetch/sw.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "console.log('hi from sw');")
    end)

    server_request = TestServer.wait_for_request(server, "/serviceworkers/fetch/sw.js")
    main = wait_for_request(context, &url_ends_with?(&1, "sw.js"))
    Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
    Task.await(server_request, :infinity)
    main = Promise.await!(main)
    # This will timeout today
    Request.response!(main)
  end

  @tag :page
  test "should report failure (due to redirect) of main service worker request", %{
    server: server,
    page: page,
    context: context
  } do
    # test.skip(browserMajorVersion < 104, 'Requires http://crrev.com/1012503 or later.');
    TestServer.set_redirect(server, "/serviceworkers/empty/sw.js", "/dev/null")
    server_request = TestServer.wait_for_request(server, "/serviceworkers/empty/sw.js")
    main = wait_for_request(context, &url_ends_with?(&1, "sw.js"))
    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    Task.await(server_request, :infinity)
    main = Promise.await!(main)
    # This will timeout today
    resp = Request.response!(main)
    assert Response.status(resp) == 302
  end

  @tag :page
  test "should intercept service worker importScripts", %{context: context, page: page, server: server} do
    BrowserContext.route!(context, "**/import.js", fn route ->
      Route.fulfill(route, content_type: "text/javascript", status: 200, body: "self.exportedValue = 47;")
    end)

    BrowserContext.route!(context, "**/sw.js", fn route ->
      Route.fulfill(route,
        content_type: "text/javascript",
        status: 200,
        body: """

                  importScripts('/import.js');
                  self.importedValue = self.exportedValue;
        """
      )
    end)

    promises = [
      wait_for_service_worker(context),
      wait_for_response(context, &url_ends_with?(&1, "/import.js"))
    ]

    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    [sw | _] = Enum.map(promises, &Promise.await!/1)

    assert Worker.evaluate!(sw, "() => self['importedValue']") == 47
  end

  # pageWithHar (tests/config/browserTest.ts): a context recording a HAR into the output dir.
  defp page_with_har(context_factory, tmp_dir) do
    har_path = Path.join(tmp_dir, "test.har")
    context = context_factory.(record_har: %{path: har_path}, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)

    get_log = fn ->
      BrowserContext.close!(context)
      har_path |> File.read!() |> JSON.decode!() |> Map.fetch!("log")
    end

    %{context: context, page: page, get_log: get_log}
  end

  @tag skip: @sw_script_response_skip
  @tag :tmp_dir
  test "should report intercepted service worker requests in HAR", %{
    context_factory: context_factory,
    tmp_dir: tmp_dir,
    server: server
  } do
    %{context: context, page: page, get_log: get_log} = page_with_har(context_factory, tmp_dir)

    BrowserContext.route!(context, "**/request-from-within-worker", fn route ->
      Route.fulfill(route,
        content_type: "application/json",
        headers: %{"x-pw-test" => "request-within-worker"},
        status: 200,
        body: ~s("intercepted!")
      )
    end)

    BrowserContext.route!(context, "**/sw.js", fn route ->
      Route.fulfill(route,
        content_type: "text/javascript",
        headers: %{"x-pw-test" => "intercepted-main"},
        status: 200,
        body: """

                  self.contentPromise = new Promise(res => fetch('/request-from-within-worker').then(r => r.json()).then(res));
        """
      )
    end)

    promises = [
      wait_for_service_worker(context),
      wait_for_response(context, &url_ends_with?(&1, "/request-from-within-worker"))
    ]

    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    [sw | _] = Enum.map(promises, &Promise.await!/1)

    assert Worker.evaluate!(sw, "() => self['contentPromise']") == "intercepted!"

    log = get_log.()
    pw_test_headers = fn entry -> Enum.filter(entry["response"]["headers"], &(&1["name"] == "x-pw-test")) end

    sw = Enum.filter(log["entries"], &String.ends_with?(&1["request"]["url"], "sw.js"))
    assert length(sw) == 1
    assert pw_test_headers.(hd(sw)) == [%{"name" => "x-pw-test", "value" => "intercepted-main"}]

    req = Enum.filter(log["entries"], &String.ends_with?(&1["request"]["url"], "request-from-within-worker"))
    assert length(req) == 1
    assert pw_test_headers.(hd(req)) == [%{"name" => "x-pw-test", "value" => "request-within-worker"}]
    assert hd(req)["response"]["content"]["text"] == ~s("intercepted!")
  end

  @tag :page
  test "should intercept only serviceworker request, not page", %{context: context, page: page, server: server} do
    BrowserContext.route!(context, "**/data.json", fn route ->
      if Request.service_worker(Route.request(route)) do
        Route.fulfill(route, content_type: "text/plain", status: 200, body: "from sw")
      else
        Route.continue(route)
      end
    end)

    sw = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
    sw = Promise.await!(sw)
    Page.evaluate!(page, "() => window['activationPromise']")
    response = Page.evaluate!(page, "() => fetch('/data.json').then(r => r.text())")
    [url] = Worker.evaluate!(sw, "() => self['intercepted']")
    assert url =~ ~r/\/data\.json$/
    assert response == "from sw"
  end

  @table_header "| Event                             | Owner            | URL                            | Routed | [`method: Response.fromServiceWorker`] |"

  defp format_request({scope, r}, routed) do
    event = if scope == :page, do: "[`event: Page.request`]", else: "[`event: BrowserContext.request`]"
    owner = if Request.service_worker(r), do: "Service [Worker]", else: String.pad_trailing("[Frame]", 16)
    url = r |> Request.url() |> String.split("/") |> List.last()
    is_routed = if r in routed, do: "Yes", else: ""
    from_sw = if Response.from_service_worker(Request.response!(r)), do: "Yes", else: ""

    "| #{String.pad_trailing(event, String.length("[`event: BrowserContext.request`]"))} | #{owner} | #{String.pad_trailing(url, 30)} | #{String.pad_trailing(is_routed, String.length("Routed"))} | #{String.pad_trailing(from_sw, String.length("[`method: Response.fromServiceWorker`]"))} |"
  end

  # `routed` and `requests`, appended to by the route handlers and request listeners.
  defp record_requests(context, page) do
    {:ok, routed} = Agent.start_link(fn -> [] end)
    {:ok, requests} = Agent.start_link(fn -> [] end)

    route_handler = fn route ->
      Agent.update(routed, &(&1 ++ [Route.request(route)]))
      Route.continue(route)
    end

    BrowserContext.route!(context, "**", route_handler)
    Page.route!(page, "**", route_handler)
    Page.on(page, :request, fn r -> Agent.update(requests, &(&1 ++ [{:page, r}])) end)
    BrowserContext.on(context, :request, fn r -> Agent.update(requests, &(&1 ++ [{:context, r}])) end)

    fn ->
      routed = Agent.get(routed, & &1)
      [@table_header | Enum.map(Agent.get(requests, & &1), &format_request(&1, routed))]
    end
  end

  @tag skip: @sw_script_response_skip
  @tag :page
  test "should produce network events, routing, and annotations for Service Worker", %{
    page: page,
    context: context,
    server: server
  } do
    TestServer.set_route(server, "/index.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, """

            <script>
              window.registrationPromise = navigator.serviceWorker.register('/transparent-service-worker.js');
            </script>
      """)
    end)

    TestServer.set_route(server, "/transparent-service-worker.js", fn conn ->
      js_response(conn, """

            self.addEventListener("fetch", (event) => {
              // actually make the request
              const responsePromise = fetch(event.request);
              // send it back to the page
              event.respondWith(responsePromise);
            });

            self.addEventListener("activate", (event) => {
              event.waitUntil(clients.claim());
            });
      """)
    end)

    table = record_requests(context, page)

    sw = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/index.html")
    sw = Promise.await!(sw)

    Utils.poll(fn -> Worker.evaluate!(sw, "() => self.registration.active?.state") end, &assert(&1 == "activated"))

    Page.evaluate!(page, "() => fetch('/data.json')")

    assert table.() == [
             "| Event                             | Owner            | URL                            | Routed | [`method: Response.fromServiceWorker`] |",
             "| [`event: BrowserContext.request`] | [Frame]          | index.html                     | Yes    |                                        |",
             "| [`event: Page.request`]           | [Frame]          | index.html                     | Yes    |                                        |",
             "| [`event: BrowserContext.request`] | Service [Worker] | transparent-service-worker.js  | Yes    |                                        |",
             "| [`event: BrowserContext.request`] | Service [Worker] | data.json                      | Yes    |                                        |",
             "| [`event: BrowserContext.request`] | [Frame]          | data.json                      |        | Yes                                    |",
             "| [`event: Page.request`]           | [Frame]          | data.json                      |        | Yes                                    |"
           ]
  end

  @tag skip: @sw_script_response_skip
  @tag :page
  test "should produce network events, routing, and annotations for Service Worker (advanced)", %{
    page: page,
    context: context,
    server: server
  } do
    TestServer.set_route(server, "/index.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, """

            <script>
              window.registrationPromise = navigator.serviceWorker.register('/complex-service-worker.js');
            </script>
      """)
    end)

    TestServer.set_route(server, "/complex-service-worker.js", fn conn ->
      js_response(conn, """

            self.addEventListener("install", function (event) {
              event.waitUntil(
                caches.open("v1").then(function (cache) {
                  // 1. Pre-fetches and caches /addressbook.json
                  return cache.add("/addressbook.json");
                })
              );
            });

            // Opt to handle FetchEvent's from the page
            self.addEventListener("fetch", (event) => {
              event.respondWith(
                (async () => {
                  // 1. Try to first serve directly from caches
                  let response = await caches.match(event.request);
                  if (response) return response;

                  // 2. Re-write request for /foo to /bar
                  if (event.request.url.endsWith("foo")) return fetch("./bar");

                  // 3. Prevent tracker.js from being retrieved, and returns a placeholder response
                  if (event.request.url.endsWith("tracker.js"))
                    return new Response('console.log("no trackers!")', {
                      status: 200,
                      headers: { "Content-Type": "text/javascript" },
                    });

                  // 4. Otherwise, fallthrough, perform the fetch and respond
                  return fetch(event.request);
                })()
              );
            });

            self.addEventListener("activate", (event) => {
              event.waitUntil(clients.claim());
            });
      """)
    end)

    TestServer.set_route(server, "/addressbook.json", fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end)

    table = record_requests(context, page)

    sw = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/index.html")
    sw = Promise.await!(sw)

    Utils.poll(fn -> Worker.evaluate!(sw, "() => self.registration.active?.state") end, &assert(&1 == "activated"))

    Page.evaluate!(page, "() => fetch('/addressbook.json')")
    Page.evaluate!(page, "() => fetch('/foo')")
    Page.evaluate!(page, "() => fetch('/tracker.js')")
    Page.evaluate!(page, "() => fetch('/fallthrough.txt')")

    assert table.() == [
             "| Event                             | Owner            | URL                            | Routed | [`method: Response.fromServiceWorker`] |",
             "| [`event: BrowserContext.request`] | [Frame]          | index.html                     | Yes    |                                        |",
             "| [`event: Page.request`]           | [Frame]          | index.html                     | Yes    |                                        |",
             "| [`event: BrowserContext.request`] | Service [Worker] | complex-service-worker.js      | Yes    |                                        |",
             "| [`event: BrowserContext.request`] | Service [Worker] | addressbook.json               | Yes    |                                        |",
             "| [`event: BrowserContext.request`] | [Frame]          | addressbook.json               |        | Yes                                    |",
             "| [`event: Page.request`]           | [Frame]          | addressbook.json               |        | Yes                                    |",
             "| [`event: BrowserContext.request`] | Service [Worker] | bar                            | Yes    |                                        |",
             "| [`event: BrowserContext.request`] | [Frame]          | foo                            |        | Yes                                    |",
             "| [`event: Page.request`]           | [Frame]          | foo                            |        | Yes                                    |",
             "| [`event: BrowserContext.request`] | [Frame]          | tracker.js                     |        | Yes                                    |",
             "| [`event: Page.request`]           | [Frame]          | tracker.js                     |        | Yes                                    |",
             "| [`event: BrowserContext.request`] | Service [Worker] | fallthrough.txt                | Yes    |                                        |",
             "| [`event: BrowserContext.request`] | [Frame]          | fallthrough.txt                |        | Yes                                    |",
             "| [`event: Page.request`]           | [Frame]          | fallthrough.txt                |        | Yes                                    |"
           ]
  end

  @tag skip: "upstream fixme: https://github.com/microsoft/playwright/issues/14711"
  test "should intercept service worker update requests"

  @tag :page
  test "setOffline", %{context: context, page: page, server: server} do
    worker = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
    worker = Promise.await!(worker)

    Page.evaluate!(page, "() => window['activationPromise']")
    BrowserContext.set_offline!(context, true)
    request = wait_for_request(context, &(url_ends_with?(&1, "/inner.txt") and Request.service_worker(&1) != nil))
    error = Worker.evaluate!(worker, "() => fetch('/inner.txt').catch(e => `REJECTED: ${e}`)")
    Promise.await!(request)
    assert error =~ ~r/REJECTED.*Failed to fetch/
  end

  @tag :page
  test "setExtraHTTPHeaders", %{context: context, page: page, server: server} do
    worker = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
    worker = Promise.await!(worker)

    Page.evaluate!(page, "() => window['activationPromise']")
    BrowserContext.set_extra_http_headers!(context, %{"x-custom-header" => "custom!"})
    request_promise = TestServer.wait_for_request(server, "/inner.txt")
    Worker.evaluate!(worker, "() => fetch('/inner.txt')")
    req = Task.await(request_promise, :infinity)
    assert req_header(req, "x-custom-header") == "custom!"
  end

  # test.skip(isHeadlessShell): we always run headless Chromium without a channel, which is the
  # headless shell (playwright-python runs these in its `chrome`/`msedge` channel jobs only).
  @tag skip: "upstream skip: Headless shell does not create a ProcessSingleton"
  test "should throw when connecting twice to an already running persistent context (--remote-debugging-port)"

  @tag skip: "upstream skip: Headless shell does not create a ProcessSingleton"
  test "should throw when connecting twice to an already running persistent context (--remote-debugging-pipe)"

  # test.skip(mode !== 'default', 'no env in non-default mode'): the driver is another process, so a
  # driver of its own started with PLAYWRIGHT_DISABLE_SERVICE_WORKER_NETWORK=1.
  test "PLAYWRIGHT_DISABLE_SERVICE_WORKER_NETWORK", %{server: server} do
    name = :disable_service_worker_network

    start_supervised!(
      {PlaywrightEx.Supervisor,
       name: name, env: [{"PWTEST_UNDER_TEST", "1"}, {"PLAYWRIGHT_DISABLE_SERVICE_WORKER_NETWORK", "1"}]},
      id: name
    )

    browser = BrowserType.launch!(Playwright.chromium(PlaywrightEx.playwright(name)))
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    test_pid = self()

    BrowserContext.on(context, :request, fn r ->
      send(test_pid, {:request, Request.service_worker(r), Request.url(r)})
    end)

    sw = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
    Promise.await!(sw)

    assert received_urls() == [
             server.prefix <> "/serviceworkers/fetch/sw.html",
             server.prefix <> "/serviceworkers/fetch/style.css"
           ]

    Page.evaluate!(page, "() => window['activationPromise']")
    Page.evaluate!(page, "() => fetch('./inner.txt')")

    assert received_urls() == [server.prefix <> "/serviceworkers/fetch/inner.txt"]

    Browser.close!(browser)
  end

  defp received_urls do
    receive do
      {:request, service_worker, url} ->
        assert service_worker == nil
        [url | received_urls()]
    after
      0 -> []
    end
  end

  @tag :page
  test "should emit console messages from service worker", %{page: page, context: context, server: server} do
    empty_page = BrowserContext.new_page!(context)
    Page.goto!(empty_page, server.empty_page)
    test_pid = self()
    Page.on(empty_page, :console, fn message -> send(test_pid, {:empty_page_message, message}) end)

    worker = wait_for_service_worker(context)
    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    worker = Promise.await!(worker)

    message = Worker.wait_for_event(worker, :console)
    page_message = Page.wait_for_event(page, :console)

    Worker.evaluate!(worker, """
    () => console.log('hello from service worker', {
      i: 'am',
      am: 1,
      complex: {
        yup: true,
      },
    })
    """)

    message = Promise.await!(message)
    page_message = Promise.await!(page_message)

    assert message == page_message
    refute_received {:empty_page_message, _}

    # Should be able to access the message after closing the page.
    Page.close!(page)

    assert ConsoleMessage.text(message) =~ "hello from service worker"
    assert ConsoleMessage.type(message) == "log"
    args = ConsoleMessage.args(message)
    assert length(args) == 2
    assert JSHandle.json_value!(Enum.at(args, 0)) == "hello from service worker"

    assert JSHandle.json_value!(Enum.at(args, 1)) == %{
             "i" => "am",
             "am" => 1,
             "complex" => %{
               "yup" => true
             }
           }
  end

  @tag :page
  @tag skip: @chromium_only
  test "should capture console.log from ServiceWorker start", %{context: context, page: page, server: server} do
    TestServer.set_route(server, "/serviceworkers/empty/sw.js", fn conn ->
      js_response(conn, "console.log('Hello from the first line of sw.js');")
    end)

    me = self()
    # The driver sends a worker's console only while someone subscribes to it: the context's
    # subscription covers the window before the worker's (JS sends that within the dispatching
    # tick; here it takes a few steps, and the first line of sw.js runs in between under load).
    # deviation: subscribe-first (OTP runtime)
    BrowserContext.on(context, :console, fn _ -> nil end)
    # deviation: subscribe-first (OTP runtime)
    BrowserContext.once(context, :service_worker, fn worker ->
      send(me, {:console, Worker.wait_for_event(worker, :console)})
    end)

    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    assert_receive {:console, console_message}, 10_000
    console_message = Promise.await!(console_message)
    assert ConsoleMessage.text(console_message) == "Hello from the first line of sw.js"
    assert ConsoleMessage.type(console_message) == "log"
  end

  describe "WebUI navigation" do
    # isEdge(channel): we run Chromium without a channel.
    defp goto_error(page, url) do
      case Page.goto(page, url) do
        {:ok, _} -> ""
        {:error, e} -> Exception.message(e)
      end
    end

    @tag :page
    test "should refuse WebUI pages that crash the browser in an isolated context", %{browser: browser, page: page} do
      hosts = ["apps", "extensions", "help", "history", "password-manager", "settings"]

      for url <-
            Enum.map(hosts, &"chrome://#{&1}") ++
              [
                "chrome://extensions/",
                "chrome://settings/help",
                "chrome://SETTINGS",
                "chrome:settings",
                "chrome:///settings",
                "view-source:chrome://settings"
              ] do
        assert goto_error(page, url) =~ ~s(Cannot navigate to "#{url}")
      end

      # The refusal only matters because it keeps the browser process alive.
      assert Browser.is_connected(browser) == true
      assert Page.evaluate!(page, "() => 1 + 1") == 2
    end

    @tag skip: "upstream skip: Edge has its own list of pages disallowed in InPrivate"
    test "should refuse WebUI pages that crash Edge in an isolated context"

    # test.skip(headless): we always run headless (so does playwright-python's CI).
    @tag skip: "upstream skip: WebUI pages are not available in headless"
    test "should navigate to WebUI pages that work in an isolated context"

    @tag skip: "upstream skip: WebUI pages are not available in headless"
    test "should navigate to any WebUI page in a persistent context"
  end

  @tag :page
  test "should fire dialogclosed event when dialog is closed out of band", %{page: page} do
    # Establish the CDP session up front: creating one while a dialog is blocking the page hangs.
    client = BrowserContext.new_cdp_session!(Page.context(page), page)
    CDPSession.send!(client, "Page.enable")
    dialog_promise = Page.wait_for_event(page, :dialog)
    closed_promise = Page.wait_for_event(page, :dialog_closed)
    evaluate_promise = Task.async(fn -> Page.evaluate(page, "() => alert('yo')") end)
    dialog = Promise.await!(dialog_promise)
    # Handle the dialog out of band, similar to the user closing it in the headed browser.
    CDPSession.send!(client, "Page.handleJavaScriptDialog", %{accept: true})
    assert Promise.await!(closed_promise) == dialog
    {:ok, _} = Task.await(evaluate_promise, :infinity)
  end

  test "should not leak service worker session after context close"
end
