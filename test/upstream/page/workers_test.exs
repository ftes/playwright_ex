defmodule PlaywrightEx.Page.WorkersTest do
  @upstream "tests/page/workers.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils
  alias PlaywrightEx.Worker

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")
  @k_target_closed_error_message "Target page, context or browser has been closed"

  @blob_worker """
  () => {
    window.worker = new Worker(URL.createObjectURL(new Blob(['42'], { type: 'application/javascript' })));
  }
  """

  test "WO-001 Page.workers @smoke", %{page: page, server: server} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    Page.expect_event!(page, :worker, fn -> Page.goto!(page, server.prefix <> "/worker/worker.html") end)
    [worker] = Page.workers(page)
    assert Worker.url(worker) =~ "worker.js"

    assert Worker.evaluate!(worker, "() => self['workerFunction']()") == "worker function result"

    Page.goto!(page, server.empty_page)
    assert Page.workers(page) == []
  end

  test "WO-002 should emit created and destroyed events", %{page: page} do
    worker_created_promise = Page.wait_for_event(page, :worker)

    worker_obj =
      Page.evaluate_handle!(
        page,
        "() => new Worker(URL.createObjectURL(new Blob(['1'], { type: 'application/javascript' })))"
      )

    worker = Promise.await!(worker_created_promise)
    worker_this_obj = Worker.evaluate_handle!(worker, "this")
    test = self()
    Worker.once(worker, :close, fn closed -> send(test, {:destroyed, closed}) end)
    Page.evaluate!(page, "workerObj => workerObj.terminate()", worker_obj)
    assert_receive {:destroyed, ^worker}, 5000
    {:error, error} = JSHandle.get_property(worker_this_obj, "self")
    assert Exception.message(error) =~ "jsHandle.getProperty"
    assert Exception.message(error) =~ @k_target_closed_error_message
  end

  test "WO-003 should reject in-flight evaluate and emit close when page closes", %{page: page, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43204' }
    Page.goto!(page, server.empty_page)

    worker =
      Page.expect_event!(page, :worker, fn ->
        Page.evaluate!(
          page,
          "() => new Worker(URL.createObjectURL(new Blob(['1'], { type: 'application/javascript' })))"
        )
      end)

    test = self()
    Worker.once(worker, :close, fn closed -> send(test, {:close, closed}) end)
    eval_promise = Runtime.Promise.async(fn -> Worker.evaluate(worker, "() => new Promise(() => {})") end)
    Page.close!(page)
    {:error, error} = Runtime.Promise.await(eval_promise)
    assert Exception.message(error) =~ "worker.evaluate"
    assert_receive {:close, ^worker}
  end

  test "WO-004 should report console logs", %{page: page} do
    message =
      Page.expect_event!(page, :console, fn ->
        Page.evaluate!(
          page,
          "() => new Worker(URL.createObjectURL(new Blob(['console.log(1)'], { type: 'application/javascript' })))"
        )
      end)

    assert ConsoleMessage.text(message) == "1"
    # Firefox's juggler had an issue that reported worker blob urls as frame urls.
    refute Page.url(page) =~ "blob"
  end

  test "WO-005 should have timestamp on worker console messages", %{page: page} do
    # it.skip(isAndroid, ...), it.skip(channel === 'webkit-wsl', ...)
    # Account for the rounding of fractional timestamps.
    before = System.system_time(:millisecond) - 1

    message =
      Page.expect_event!(page, :console, fn ->
        Page.evaluate!(
          page,
          ~s|() => new Worker(URL.createObjectURL(new Blob(['console.log("ts")'], { type: 'application/javascript' })))|
        )
      end)

    # Account for the rounding of fractional timestamps.
    after_ = System.system_time(:millisecond) + 1
    assert ConsoleMessage.text(message) == "ts"
    assert ConsoleMessage.timestamp(message) >= before
    assert ConsoleMessage.timestamp(message) <= after_
  end

  test "WO-006 should not report console logs from workers twice", %{page: page} do
    test = self()
    Page.on(page, :console, fn msg -> send(test, {:message, ConsoleMessage.text(msg)}) end)
    one = Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == "1"))
    two = Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == "2"))

    Page.evaluate!(
      page,
      "() => new Worker(URL.createObjectURL(new Blob(['console.log(1); console.log(2);'], { type: 'application/javascript' })))"
    )

    Promise.await!(one)
    Promise.await!(two)
    assert_received {:message, message1}
    assert_received {:message, message2}
    refute_received {:message, _}
    assert [message1, message2] == ["1", "2"]
    # Firefox's juggler had an issue that reported worker blob urls as frame urls.
    refute Page.url(page) =~ "blob"
  end

  test "WO-007 should have JSHandles for console logs", %{page: page, browser_name: browser_name} do
    test = self()
    Page.on(page, :console, fn msg -> send(test, {:log, msg}) end)

    Page.evaluate!(
      page,
      "() => new Worker(URL.createObjectURL(new Blob(['console.log(1,2,3,this)'], { type: 'application/javascript' })))"
    )

    assert_receive {:log, log}, 5000

    if browser_name != "firefox",
      do: assert(ConsoleMessage.text(log) == "1 2 3 DedicatedWorkerGlobalScope"),
      else: assert(ConsoleMessage.text(log) == "1 2 3 JSHandle@object")

    assert length(ConsoleMessage.args(log)) == 4

    assert log |> ConsoleMessage.args() |> Enum.at(3) |> JSHandle.get_property!("origin") |> JSHandle.json_value!() ==
             "null"
  end

  test "WO-008 should evaluate", %{page: page} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    worker_created_promise = Page.wait_for_event(page, :worker)

    Page.evaluate!(
      page,
      "() => new Worker(URL.createObjectURL(new Blob(['console.log(1)'], { type: 'application/javascript' })))"
    )

    worker = Promise.await!(worker_created_promise)
    assert Worker.evaluate!(worker, "1+1") == 2
  end

  test "WO-009 should report console event on the worker", %{page: page} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    worker =
      Page.expect_event!(page, :worker, fn ->
        Page.evaluate!(page, @blob_worker)
      end)

    promises = [
      Worker.wait_for_event(worker, :console),
      Page.wait_for_event(page, :console),
      BrowserContext.wait_for_event(Page.context(page), :console)
    ]

    Worker.evaluate!(worker, "() => { console.log('hello from worker'); }")
    [message1, message2, message3] = Enum.map(promises, &Promise.await!/1)
    assert ConsoleMessage.text(message1) == "hello from worker"
    assert message1 == message2
    assert message1 == message3
  end

  test "WO-010 should report console event on the worker when not listening on page or context", %{page: page} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    worker =
      Page.expect_event!(page, :worker, fn ->
        Page.evaluate!(page, @blob_worker)
      end)

    message =
      Worker.expect_event!(worker, :console, fn ->
        Worker.evaluate!(worker, "() => { console.log('hello from worker'); }")
      end)

    assert ConsoleMessage.text(message) == "hello from worker"
  end

  test "WO-011 should report errors", %{page: page} do
    test = self()
    Page.on(page, :page_error, fn error -> send(test, {:pageerror, error}) end)

    Page.evaluate!(page, """
    () => new Worker(URL.createObjectURL(new Blob([`
      setTimeout(() => {
        // Do a console.log just to check that we do not confuse it with an error.
        console.log('hey');
        throw new Error('this is my error');
      })
    `], { type: 'application/javascript' })))
    """)

    assert_receive {:pageerror, error_log}, 5000
    assert error_log.message =~ "this is my error"
  end

  test "WO-012 should clear upon navigation", %{server: server, page: page} do
    Page.goto!(page, server.empty_page)
    worker_created_promise = Page.wait_for_event(page, :worker)

    Page.evaluate!(
      page,
      "() => new Worker(URL.createObjectURL(new Blob(['console.log(1)'], { type: 'application/javascript' })))"
    )

    worker = Promise.await!(worker_created_promise)
    assert length(Page.workers(page)) == 1
    test = self()
    Worker.once(worker, :close, fn _ -> send(test, :destroyed) end)
    Page.goto!(page, server.prefix <> "/one-style.html")
    assert_received :destroyed
    assert Page.workers(page) == []
  end

  test "WO-013 should clear upon cross-process navigation", %{server: server, page: page} do
    Page.goto!(page, server.empty_page)
    worker_created_promise = Page.wait_for_event(page, :worker)

    Page.evaluate!(
      page,
      "() => new Worker(URL.createObjectURL(new Blob(['console.log(1)'], { type: 'application/javascript' })))"
    )

    worker = Promise.await!(worker_created_promise)
    assert length(Page.workers(page)) == 1
    test = self()
    Worker.once(worker, :close, fn _ -> send(test, :destroyed) end)
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert_received :destroyed
    assert Page.workers(page) == []
  end

  @tag skip:
         if(@browser_name == "chromium",
           do:
             "flaky: Chromium sometimes fetches the iframe's worker.js but never auto-attaches the worker " <>
               "(no Target.attachedToTarget, so no page worker event). The JS client hangs too: 6/510 " <>
               "in a 2-CPU Linux container, this client ~3% (before and after the OTP Phase 1 changes). " <>
               "A Chromium bug: https://issues.chromium.org/issues/582409894 " <>
               "(upstream: https://github.com/microsoft/playwright/issues/43922)"
         )
  test "WO-014 should attribute network activity for worker inside iframe to the iframe", %{page: page, server: server} do
    # it.skip(browserName === 'firefox' && browserMajorVersion < 114, ...)  -- the pinned browsers are newer
    # it.skip(browserName === 'chromium' && browserMajorVersion < 149, ...)  -- the pinned browsers are newer
    Page.goto!(page, server.prefix <> "/empty.html")
    worker_promise = Page.wait_for_event(page, :worker)
    frame = Utils.attach_frame(page, "frame1", server.prefix <> "/worker/worker.html")
    worker = Promise.await!(worker_promise)
    url = server.prefix <> "/one-style.css"

    request =
      Page.expect_request!(page, url, fn ->
        Worker.evaluate!(worker, "url => fetch(url).then(response => response.text()).then(console.log)", url)
      end)

    assert Request.url(request) == url
    assert Request.frame(request) == frame
  end

  test "WO-015 should report network activity", %{page: page, server: server, asset: asset} do
    # it.skip(browserName === 'firefox' && browserMajorVersion < 114, ...)  -- the pinned browsers are newer
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    worker = Page.expect_event!(page, :worker, fn -> Page.goto!(page, server.prefix <> "/worker/worker.html") end)
    url = server.prefix <> "/one-style.css"
    request_promise = Page.wait_for_request(page, url)
    response_promise = Page.wait_for_response(page, url)
    Worker.evaluate!(worker, "url => fetch(url).then(response => response.text()).then(console.log)", url)
    request = Promise.await!(request_promise)
    response = Promise.await!(response_promise)
    assert Request.url(request) == url
    assert Response.request(response) == request
    assert Response.ok(response) == true
    assert Response.text!(response) == File.read!(asset.("one-style.css"))
  end

  test "WO-016 should report network activity on worker creation", %{page: page, server: server} do
    # it.skip(browserName === 'firefox' && browserMajorVersion < 114, ...)  -- the pinned browsers are newer
    Page.goto!(page, server.empty_page)
    url = server.prefix <> "/one-style.css"
    request_promise = Page.wait_for_request(page, url)
    response_promise = Page.wait_for_response(page, url)

    Page.evaluate!(
      page,
      """
      url => new Worker(URL.createObjectURL(new Blob([`
        fetch("${url}").then(response => response.text()).then(console.log);
      `], { type: 'application/javascript' })))
      """,
      url
    )

    request = Promise.await!(request_promise)
    response = Promise.await!(response_promise)
    assert Request.url(request) == url
    assert Response.request(response) == request
    assert Response.ok(response) == true
  end

  # annotation: issues 33107, 35678
  test "WO-017 should report worker script as network request", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    request1_promise = Page.wait_for_event(page, :request, &(Request.url(&1) =~ "worker.js"))
    request2_promise = Page.wait_for_event(page, :request_finished, &(Request.url(&1) =~ "worker.js"))
    Page.evaluate!(page, "() => window.w = new Worker('/worker/worker.js')")
    request1 = Promise.await!(request1_promise)
    request2 = Promise.await!(request2_promise)
    assert Request.url(request1) == server.prefix <> "/worker/worker.js"
    assert request1 == request2
    response = Request.response!(request1)
    text = Response.text!(response)
    assert text =~ "console.log('hello from the worker');"
  end

  # annotation: issue 35678
  @tag skip:
         if(@browser_name == "chromium",
           do: "upstream fixme: Chromium does not report the redirect because it is not plumbed to the worker target"
         )
  test "WO-018 should report worker script as network request after redirect", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_redirect(server, "/worker.js", "/worker2.js")

    TestServer.set_route(server, "/worker2.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/javascript")
      |> Plug.Conn.send_resp(200, "console.log('hello from the worker');")
    end)

    request_promise = Page.wait_for_event(page, :request, &(Request.url(&1) =~ "worker.js"))

    console_promise =
      Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) =~ "hello from the worker"))

    Page.evaluate!(page, "() => window.w = new Worker('/worker.js')")
    request = Promise.await!(request_promise)
    Promise.await!(console_promise)
    assert Request.url(request) == server.prefix <> "/worker.js"
    redirect = Request.redirected_to(request)
    assert redirect
    assert Request.url(redirect) == server.prefix <> "/worker2.js"
    response = Request.response!(redirect)
    text = Response.text!(response)
    assert text =~ "console.log('hello from the worker');"
  end

  test "WO-019 should dispatch console messages when page has workers", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/15550' })
    Page.goto!(page, server.empty_page)

    Page.expect_event!(page, :worker, fn ->
      Page.evaluate!(
        page,
        "() => new Worker(URL.createObjectURL(new Blob(['const x = 1;'], { type: 'application/javascript' })))"
      )
    end)

    message = Page.expect_event!(page, :console, fn -> Page.evaluate!(page, "() => console.log('foo')") end)
    assert ConsoleMessage.text(message) == "foo"
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream fixme: webkit (#27376)")
  test "WO-020 should report and intercept network from nested worker", %{page: page, server: server} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    Page.route!(page, "**/simple.json", fn route ->
      json = %{foo: "not bar"}
      Route.fulfill!(route, json: json)
    end)

    Page.goto!(page, server.empty_page)
    url = server.prefix <> "/simple.json"
    {:ok, workers} = Agent.start_link(fn -> [] end)
    {:ok, messages} = Agent.start_link(fn -> [] end)

    Page.on(page, :worker, fn worker -> Agent.update(workers, &(&1 ++ [worker])) end)
    Page.on(page, :console, fn msg -> Agent.update(messages, &(&1 ++ [ConsoleMessage.text(msg)])) end)

    nested_worker = """
    url => new Worker(URL.createObjectURL(new Blob([`
      fetch("${url}").then(response => response.text()).then(t => console.log(t.trim()));
    `], { type: 'application/javascript' })))
    """

    Page.evaluate!(page, nested_worker, url)
    Expect.poll!(fn -> length(Agent.get(workers, & &1)) end, &assert(&1 == 1))

    workers |> Agent.get(&hd/1) |> Worker.evaluate!(nested_worker, url)

    Expect.poll!(fn -> length(Agent.get(workers, & &1)) end, &assert(&1 == 2))

    Expect.poll!(fn -> Agent.get(messages, & &1) end, &assert(&1 == [~s|{"foo":"not bar"}|, ~s|{"foo":"not bar"}|]))
  end

  # annotation: issue 31747
  test "WO-021 should support extra http headers", %{page: page, server: server} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    Page.set_extra_http_headers!(page, %{"foo" => "bar"})
    worker_promise = Page.wait_for_event(page, :worker)
    request1_task = TestServer.wait_for_request(server, "/worker/worker.js")
    Page.goto!(page, server.prefix <> "/worker/worker.html")
    worker = Promise.await!(worker_promise)
    request1 = Task.await(request1_task, :infinity)
    request2_task = TestServer.wait_for_request(server, "/one-style.css")
    Worker.evaluate!(worker, "url => fetch(url)", server.prefix <> "/one-style.css")
    request2 = Task.await(request2_task, :infinity)
    assert Plug.Conn.get_req_header(request1, "foo") == ["bar"]
    assert Plug.Conn.get_req_header(request2, "foo") == ["bar"]
  end

  @tag skip:
         (case @browser_name do
            "webkit" -> "upstream fixme: flaky on all platforms"
            "firefox" -> "upstream fixme: does not plumb setOffline into WorkerNavigator::OnLine"
            _ -> false
          end)
  test "WO-022 should support offline", %{page: page, server: server} do
    worker_promise = Page.wait_for_event(page, :worker)

    console_promise =
      Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) =~ "hello from the worker"))

    Page.goto!(page, server.prefix <> "/worker/worker.html")
    worker = Promise.await!(worker_promise)
    Promise.await!(console_promise)
    BrowserContext.set_offline!(Page.context(page), true)
    Expect.poll!(fn -> Worker.evaluate!(worker, "() => navigator.onLine") end, &assert(&1 == false))
    assert Worker.evaluate!(worker, "() => fetch('/one-style.css').catch(e => 'error')") == "error"
    BrowserContext.set_offline!(Page.context(page), false)
    Expect.poll!(fn -> Worker.evaluate!(worker, "() => navigator.onLine") end, &assert(&1 == true))
  end

  # annotation: issue 39948
  test "WO-023 should resolve worker script allHeaders in main frame", %{page: page, server: server} do
    request_promise =
      Page.wait_for_event(page, :request_finished,
        predicate: &(Request.url(&1) == server.prefix <> "/worker/worker.js")
      )

    Page.goto!(page, server.prefix <> "/worker/worker.html")
    request = Promise.await!(request_promise)
    response = Request.response!(request)
    request_headers = Request.all_headers!(request)
    Utils.assert_truthy(request_headers["host"])
    response_headers = Response.all_headers!(response)
    Utils.assert_truthy(response_headers["content-type"])
  end

  # annotation: issue 39948
  test "WO-024 should resolve worker script allHeaders in iframe", %{page: page, server: server} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 151, ...)  -- the pinned browsers are newer
    request_promise =
      Page.wait_for_event(page, :request_finished,
        predicate: &(Request.url(&1) == server.prefix <> "/worker/worker.js")
      )

    Utils.attach_frame(page, "frame1", server.prefix <> "/worker/worker.html")
    request = Promise.await!(request_promise)
    response = Request.response!(request)
    request_headers = Request.all_headers!(request)
    Utils.assert_truthy(request_headers["host"])
    response_headers = Response.all_headers!(response)
    Utils.assert_truthy(response_headers["content-type"])
  end

  # annotation: issue 39948
  @tag skip:
         (case @browser_name do
            "webkit" -> "upstream fixme: cannot evaluate in nested worker"
            "firefox" -> "upstream fixme: nested worker script request is not reported at all"
            _ -> false
          end)
  test "WO-025 should resolve worker script allHeaders in nested worker inside iframe", %{page: page, server: server} do
    url = server.prefix <> "/worker/worker.js"
    worker_promise = Page.wait_for_event(page, :worker)
    finished_promise = Page.wait_for_event(page, :request_finished, &(Request.url(&1) == url))
    Utils.attach_frame(page, "frame1", server.prefix <> "/worker/worker.html")
    worker = Promise.await!(worker_promise)
    Promise.await!(finished_promise)

    request =
      Page.expect_event!(
        page,
        :request_finished,
        fn -> Worker.evaluate!(worker, "url => { self.w = new Worker(url); }", url) end,
        predicate: &(Request.url(&1) == url)
      )

    response = Request.response!(request)
    headers = Response.all_headers!(response)
    Utils.assert_truthy(headers["content-type"])
  end
end
