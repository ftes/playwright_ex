defmodule PlaywrightEx.Page.PageEventRequestTest do
  @upstream "tests/page/page-event-request.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [attach_frame: 3]

  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  # Collects events sent by listeners: `const requests = []; page.on('request', r => requests.push(r))`.
  defp received(acc \\ []) do
    receive do
      {:event, event} -> received([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp on_request(page) do
    me = self()
    Page.on(page, :request, &send(me, {:event, &1}))
  end

  # Node's `${req.method} ${req.url}`.
  defp server_request(conn) do
    "#{conn.method} #{conn.request_path}#{if conn.query_string != "", do: "?" <> conn.query_string}"
  end

  test "should fire for navigation requests", %{page: page, server: server} do
    on_request(page)
    Page.goto!(page, server.empty_page)
    assert length(received()) == 1
  end

  test "should fire for iframes", %{page: page, server: server} do
    on_request(page)
    Page.goto!(page, server.empty_page)
    attach_frame(page, "frame1", server.empty_page)
    assert length(received()) == 2
  end

  test "should fire for fetches", %{page: page, server: server} do
    on_request(page)
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => fetch('/empty.html')")
    assert length(received()) == 2
  end

  # https://github.com/microsoft/playwright/issues/34497
  test "should fire for fetches with keepalive: true", %{page: page, server: server} do
    on_request(page)
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => fetch('/empty.html', { keepalive: true })")
    assert length(received()) == 2
  end

  test "should report requests and responses handled by service worker", %{
    page: page,
    server: server
  } do
    # it.fixme(isAndroid); it.fixme(isElectron);  -- neither
    Page.goto!(page, server.prefix <> "/serviceworkers/fetchdummy/sw.html")
    Page.evaluate!(page, "() => window['activationPromise']")
    request_promise = Page.wait_for_event(page, :request)
    sw_response = Page.evaluate!(page, "() => window['fetchDummy']('foo')")
    request = Promise.await!(request_promise)
    assert sw_response == "responseFromServiceWorker:foo"
    assert Request.url(request) == server.prefix <> "/serviceworkers/fetchdummy/foo"
    assert Request.service_worker(request) == nil
    response = Request.response!(request)
    assert Response.url(response) == server.prefix <> "/serviceworkers/fetchdummy/foo"
    assert Response.text!(response) == "responseFromServiceWorker:foo"
    assert Response.from_service_worker(response) == true

    failed_promise = Page.wait_for_event(page, :request_failed)
    Page.evaluate(page, "() => window['fetchDummy']('error')")
    failed_request = Promise.await!(failed_promise)
    assert Request.url(failed_request) == server.prefix <> "/serviceworkers/fetchdummy/error"
    assert Request.failure(failed_request) != nil
    assert Request.service_worker(failed_request) == nil
    assert Request.response!(failed_request) == nil
  end

  test "should report requests and responses handled by service worker with routing",
       %{page: page, server: server, browser_name: browser_name} do
    # it.fixme(isAndroid); it.fixme(isElectron);  -- neither
    me = self()

    Page.route!(page, "**/*", fn route ->
      send(me, {:event, Request.url(Route.request(route))})
      Route.continue(route)
    end)

    Page.goto!(page, server.prefix <> "/serviceworkers/fetchdummy/sw.html")
    Page.evaluate!(page, "() => window['activationPromise']")
    request_promise = Page.wait_for_event(page, :request)
    sw_response = Page.evaluate!(page, "() => window['fetchDummy']('foo')")
    request = Promise.await!(request_promise)
    assert sw_response == "responseFromServiceWorker:foo"
    assert Request.url(request) == server.prefix <> "/serviceworkers/fetchdummy/foo"
    assert Request.service_worker(request) == nil
    response = Request.response!(request)
    assert Response.url(response) == server.prefix <> "/serviceworkers/fetchdummy/foo"
    assert Response.text!(response) == "responseFromServiceWorker:foo"

    failed_promise = Page.wait_for_event(page, :request_failed)
    Page.evaluate(page, "() => window['fetchDummy']('error')")
    failed_request = Promise.await!(failed_promise)
    assert Request.url(failed_request) == server.prefix <> "/serviceworkers/fetchdummy/error"
    assert Request.failure(failed_request) != nil
    assert Request.service_worker(failed_request) == nil
    assert Request.response!(failed_request) == nil

    expected_urls =
      [server.prefix <> "/serviceworkers/fetchdummy/sw.html"] ++
        if browser_name == "webkit",
          do: [server.prefix <> "/serviceworkers/fetchdummy/sw.js"],
          else: []

    assert received() == expected_urls
  end

  test "should report navigation requests and responses handled by service worker",
       %{page: page, server: server, browser_name: browser_name} do
    # it.fixme(isAndroid);  -- not Android
    Page.goto!(page, server.prefix <> "/serviceworkers/stub/sw.html")
    Page.evaluate!(page, "() => window['activationPromise']")

    reload_response = Page.reload!(page)
    assert Page.evaluate!(page, "window.fromSW") == true
    assert Response.url(reload_response) == server.prefix <> "/serviceworkers/stub/sw.html"
    Page.evaluate!(page, "() => window['activationPromise']")

    if browser_name != "firefox" do
      # When SW fetch throws, Firefox does not fail the navigation,
      # but rather falls back to the real network.

      failed_promise = Page.wait_for_event(page, :request_failed)
      Page.evaluate!(page, "() => { window.location.href = '/serviceworkers/stub/error.html'; }")
      failed_request = Promise.await!(failed_promise)
      assert Request.url(failed_request) == server.prefix <> "/serviceworkers/stub/error.html"

      assert Request.failure(failed_request).errorText =~
               if(browser_name == "chromium", do: "net::ERR_FAILED", else: "uh oh")

      assert Request.service_worker(failed_request) == nil
      assert Request.response!(failed_request) == nil
    end
  end

  test "should report navigation requests and responses handled by service worker with routing",
       %{page: page, server: server, browser_name: browser_name} do
    # it.fixme(isAndroid);  -- not Android
    Page.route!(page, "**/*", &Route.continue/1)
    Page.goto!(page, server.prefix <> "/serviceworkers/stub/sw.html")
    Page.evaluate!(page, "() => window['activationPromise']")

    reload_response = Page.reload!(page)
    assert Page.evaluate!(page, "window.fromSW") == true
    assert Response.url(reload_response) == server.prefix <> "/serviceworkers/stub/sw.html"
    Page.evaluate!(page, "() => window['activationPromise']")

    if browser_name != "firefox" do
      # When SW fetch throws, Firefox does not fail the navigation,
      # but rather falls back to the real network.

      failed_promise = Page.wait_for_event(page, :request_failed)

      Page.evaluate!(page, """
      () => {
        window.location.href = '/serviceworkers/stub/error.html';
        // eslint-disable-next-line
        undefined
      }
      """)

      failed_request = Promise.await!(failed_promise)
      assert Request.url(failed_request) == server.prefix <> "/serviceworkers/stub/error.html"

      assert Request.failure(failed_request).errorText =~
               if(browser_name == "chromium", do: "net::ERR_FAILED", else: "uh oh")

      assert Request.service_worker(failed_request) == nil
      assert Request.response!(failed_request) == nil
    end
  end

  test "should return response body when Cross-Origin-Opener-Policy is set", %{
    page: page,
    server: server
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      # Note: without 'onload', Firefox sometimes does not fire the load event
      # over the protocol. The reason is unclear.
      conn
      |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
      |> Plug.Conn.send_resp(200, """
        <div>Hello there!</div>
        <script>window.onload = () => console.log('onload')</script>
      """)
    end)

    response = Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page
    Response.finished!(response)
    assert Request.failure(Response.request(response)) == nil
    assert Response.text!(response) =~ "Hello there!"
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: This test is specifically testing Chromium race")
  test "should fire requestfailed when intercepting race", %{
    page: page,
    server: server
  } do
    me = self()
    Page.on(page, :request, &send(me, {:request, &1}))
    Page.on(page, :request_failed, &send(me, {:request_failed, &1}))

    # Stall requests to make sure we don't get requestfinished.
    Page.route!(page, "**", fn _route -> nil end)

    iframes = String.duplicate(~s|<iframe src="#{server.empty_page}"></iframe>\n|, 10)

    Page.set_content!(page, """
    #{iframes}
    <script>
      function abortAll() {
        const frames = document.querySelectorAll("iframe");
        for (const frame of frames)
          frame.src = "about:blank";
      }
      abortAll();
    </script>
    """)

    # The listeners' `expect`s, checked here in event order, until `++counter === 10`.
    check_events = fn check_events, counter, alive, failures ->
      if counter < 10 do
        receive do
          {:request, request} ->
            refute request in alive
            refute request in failures
            check_events.(check_events, counter, [request | alive], failures)

          {:request_failed, request} ->
            refute request in failures
            assert request in alive

            check_events.(check_events, counter + 1, List.delete(alive, request), [
              request | failures
            ])
        after
          30_000 -> flunk("timed out waiting for requestfailed")
        end
      end
    end

    check_events.(check_events, 0, [], [])
  end

  # https://github.com/microsoft/playwright/issues/22812
  test "main resource xhr should have type xhr", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    request_promise = Page.wait_for_event(page, :request)

    Page.evaluate!(page, """
    () => {
      const x = new XMLHttpRequest();
      x.open('GET', location.href, false);
      x.send();
    }
    """)

    request = Promise.await!(request_promise)
    assert Request.is_navigation_request(request) == false
    assert Request.resource_type(request) == "xhr"
  end

  # https://github.com/microsoft/playwright/issues/32752
  # https://github.com/microsoft/playwright/issues/42786
  test "should finish 204 request", %{page: page, server: server} do
    TestServer.set_route(server, "/204", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(204, "")
    end)

    Page.goto!(page, server.empty_page)
    me = self()
    ends_with_204 = &String.ends_with?(Request.url(&1), "/204")

    # Promise.race([...requestfailed..., ...requestfinished...])
    for {event, label} <- [request_failed: "requestfailed", request_finished: "requestfinished"] do
      promise = Page.wait_for_event(page, event, ends_with_204)
      spawn(fn -> with {:ok, _} <- Promise.await(promise), do: send(me, {:race, label}) end)
    end

    spawn(fn ->
      Page.evaluate(page, "async url => { await fetch(url); }", server.prefix <> "/204")
    end)

    assert_receive {:race, winner}, 30_000
    assert winner == "requestfinished"
  end

  # https://github.com/microsoft/playwright/issues/33148
  test "<picture> resource should have type image", %{page: page} do
    request_promise = Page.wait_for_event(page, :request)

    Page.set_content!(page, """
    <picture>
      <source>
        <img src="https://www.wikipedia.org/portal/wikipedia.org/assets/img/Wikipedia-logo-v2@2x.png">
      </source>
    </picture>
    """)

    request = Promise.await!(request_promise)
    assert Request.resource_type(request) == "image"
  end

  # Chromium: requestWillBeSentEvent.frameId is undefined for OPTIONS.
  # WebKit: no requestWillBeSent event in the protocol for OPTIONS (at least on Mac).
  # Firefox: OPTIONS request can be dispatched.
  # https://github.com/microsoft/playwright/issues/36311
  test "should not expose preflight OPTIONS request", %{page: page, server: server} do
    me = self()

    TestServer.set_route(server, "/cors", fn conn ->
      send(me, {:server_request, server_request(conn)})

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

    Page.on(page, :request, fn request ->
      send(me, {:event, "#{Request.method(request)} #{Request.url(request)}"})
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
        {:ok, text} -> text
        {:error, _} -> nil
      end

    assert response == "Hello there!"
    assert server_requests() == ["OPTIONS /cors", "POST /cors"]
    assert received() == ["POST #{server.cross_process_prefix}/cors"]
  end

  # https://github.com/microsoft/playwright/issues/36311
  test "should not expose preflight OPTIONS request with network interception",
       %{page: page, server: server, browser_name: browser_name} do
    me = self()

    TestServer.set_route(server, "/cors", fn conn ->
      send(me, {:server_request, server_request(conn)})

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

    Page.route!(page, "**/*", &Route.continue/1)

    Page.on(page, :request, fn request ->
      send(me, {:event, "#{Request.method(request)} #{Request.url(request)}"})
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
        {:ok, text} -> text
        {:error, _} -> nil
      end

    assert response == "Hello there!"
    # isBidi: we run the default protocols
    assert server_requests() ==
             if(browser_name == "chromium", do: [], else: ["OPTIONS /cors"]) ++ ["POST /cors"]

    assert received() == ["POST #{server.cross_process_prefix}/cors"]
  end

  test "should return last requests", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/title.html")

    for i <- 0..199//1 do
      TestServer.set_route(server, "/fetch?#{i}", fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          "url:" <> server.prefix <> conn.request_path <> "?" <> conn.query_string
        )
      end)
    end

    # #0 is the navigation request, so start with #1.
    for i <- 0..98//1,
        do: Page.evaluate!(page, "url => fetch(url)", server.prefix <> "/fetch?#{i}")

    [_ | first99_requests] = Page.requests!(page)

    for i <- 99..198//1,
        do: Page.evaluate!(page, "url => fetch(url)", server.prefix <> "/fetch?#{i}")

    last100_requests = Page.requests!(page)
    all_requests = first99_requests ++ last100_requests

    # All 199 requests are fully functional.
    received =
      all_requests
      |> Task.async_stream(
        fn request ->
          response = Request.response!(request)
          %{text: Response.text!(response), url: Request.url(request)}
        end,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    expected =
      for i <- 0..198//1 do
        url = server.prefix <> "/fetch?#{i}"
        %{url: url, text: "url:" <> url}
      end

    assert received == expected
  end

  defp server_requests(acc \\ []) do
    receive do
      {:server_request, request} -> server_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
