defmodule PlaywrightEx.Page.PageNetworkIdleTest do
  @upstream "tests/page/page-network-idle.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  # `server.setRoute(path, (req, res) => response = res)`: the handler sends its pid to the test
  # and answers once it receives `{:end, status, body}`.
  defp hold(server, path, tag) do
    test = self()

    TestServer.set_route(server, path, fn conn ->
      send(test, {tag, self()})

      receive do
        {:end, status, body} -> Plug.Conn.send_resp(conn, status, body)
      end
    end)
  end

  defp hang(_conn), do: Process.sleep(:infinity)

  # The action runs in a task: `actionFinished` is `Task.yield(task, 0) != nil`.
  defp network_idle_test(frame, server, action, is_set_content \\ false) do
    wait_for_request = fn suffix ->
      {TestServer.wait_for_request(server, suffix), Page.wait_for_request(Frame.page(frame), server.prefix <> suffix)}
    end

    await_both = fn {server_request, page_request} ->
      Task.await(server_request, :infinity)
      Promise.await!(page_request)
    end

    # Hold on to a bunch of requests without answering.
    hold(server, "/fetch-request-a.js", :response_a)
    first_fetch_resource_requested = wait_for_request.("/fetch-request-a.js")
    hold(server, "/fetch-request-b.js", :response_b)
    second_fetch_resource_requested = wait_for_request.("/fetch-request-b.js")

    wait_for_load_promise = if !is_set_content, do: Frame.wait_for_navigation(frame, wait_until: :load)

    # Navigate to a page which loads immediately and then does a bunch of
    # requests via javascript's fetch method.
    action_promise = Task.async(action)

    # Wait for the frame's 'load' event.
    if wait_for_load_promise, do: Promise.await!(wait_for_load_promise)
    refute Task.yield(action_promise, 0)

    # Wait for the initial resource to be requested.
    await_both.(first_fetch_resource_requested)
    refute Task.yield(action_promise, 0)

    # Trigger the second request.
    Page.evaluate!(Frame.page(frame), "() => window['fetchSecond']()")
    # Finish the first request.
    assert_receive {:response_a, response_a}
    send(response_a, {:end, 404, "File not found"})

    # Wait for the second round to be requested.
    await_both.(second_fetch_resource_requested)
    refute Task.yield(action_promise, 0)

    # Finishing the second response should trigger networkidle.
    timer = System.monotonic_time(:millisecond)
    assert_receive {:response_b, response_b}
    send(response_b, {:end, 404, "File not found"})

    response = Task.await(action_promise, :infinity)
    timer_triggered = System.monotonic_time(:millisecond) - timer >= 500
    assert timer_triggered == true
    if !is_set_content, do: assert(Response.ok(response) == true)
  end

  test "should navigate to empty page with networkidle", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page, wait_until: :networkidle)
    assert Response.status(response) == 200
  end

  test "should wait for networkidle to succeed navigation", %{page: page, server: server} do
    network_idle_test(Page.main_frame(page), server, fn ->
      Page.goto!(page, server.prefix <> "/networkidle.html", wait_until: :networkidle)
    end)
  end

  test "should wait for networkidle to succeed navigation with request from previous navigation",
       %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/foo.js", &hang/1)
    Page.set_content!(page, "<script>fetch('foo.js');</script>")

    network_idle_test(Page.main_frame(page), server, fn ->
      Page.goto!(page, server.prefix <> "/networkidle.html", wait_until: :networkidle)
    end)
  end

  test "should wait for networkidle in waitForNavigation", %{page: page, server: server} do
    network_idle_test(Page.main_frame(page), server, fn ->
      promise = Page.wait_for_navigation(page, wait_until: :networkidle)
      Task.start(fn -> Page.goto(page, server.prefix <> "/networkidle.html") end)
      Promise.await!(promise)
    end)
  end

  test "should wait for networkidle in setContent", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    network_idle_test(
      Page.main_frame(page),
      server,
      fn -> Page.set_content!(page, "<script src='networkidle.js'></script>", wait_until: :networkidle) end,
      true
    )
  end

  test "should wait for networkidle in setContent with request from previous navigation",
       %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    TestServer.set_route(server, "/foo.js", &hang/1)
    Page.set_content!(page, "<script>fetch('foo.js');</script>")

    network_idle_test(
      Page.main_frame(page),
      server,
      fn -> Page.set_content!(page, "<script src='networkidle.js'></script>", wait_until: :networkidle) end,
      true
    )
  end

  test "should wait for networkidle when navigating iframe", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    frame = page |> Page.main_frame() |> Frame.child_frames() |> hd()

    network_idle_test(frame, server, fn ->
      Frame.goto!(frame, server.prefix <> "/networkidle.html", wait_until: :networkidle)
    end)
  end

  test "should wait for networkidle in setContent from the child frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    network_idle_test(
      Page.main_frame(page),
      server,
      fn -> Page.set_content!(page, "<iframe src='networkidle.html'></iframe>", wait_until: :networkidle) end,
      true
    )
  end

  test "should wait for networkidle from the child frame", %{page: page, server: server} do
    network_idle_test(Page.main_frame(page), server, fn ->
      Page.goto!(page, server.prefix <> "/networkidle-frame.html", wait_until: :networkidle)
    end)
  end

  test "should wait for networkidle from the popup", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <button id=box1 onclick="window.open('./popup/popup.html')">Button1</button>
    <button id=box2 onclick="window.open('./popup/popup.html')">Button2</button>
    <button id=box3 onclick="window.open('./popup/popup.html')">Button3</button>
    <button id=box4 onclick="window.open('./popup/popup.html')">Button4</button>
    <button id=box5 onclick="window.open('./popup/popup.html')">Button5</button>
    """)

    for i <- 1..5 do
      popup = Page.expect_popup!(page, fn -> Page.click!(page, "#box#{i}") end)
      Page.wait_for_load_state!(popup, :networkidle)
    end
  end

  test "should wait for networkidle when iframe attaches and detaches", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", &hang/1)

    promise =
      Task.async(fn ->
        Page.set_content!(
          page,
          """
          <body>
            <script>
              const iframe = document.createElement('iframe');
              iframe.src = #{JSON.encode!(server.empty_page)};
              document.body.appendChild(iframe);
            </script>
          </body>
          """,
          wait_until: :networkidle
        )
      end)

    Page.wait_for_timeout!(page, 600)
    refute Task.yield(promise, 0)
    Page.evaluate!(page, "() => { document.querySelector('iframe').remove(); }")
    Task.await(promise, :infinity)
  end

  # issue: https://github.com/microsoft/playwright/issues/18283
  test "should work after repeated navigations in the same page", %{page: page, server: server} do
    request_count = :counters.new(1, [])

    Page.route!(page, "**/empty.html", fn route ->
      Route.fulfill(route,
        content_type: "text/html",
        body: """
        <script>
          fetch('http://localhost:8000/sample').then(res => console.log(res.json()))
        </script>
        """
      )
    end)

    Page.route!(page, "**/sample", fn route ->
      :counters.add(request_count, 1, 1)
      Route.fulfill(route, content_type: "application/json", body: JSON.encode!(%{content: "sample"}))
    end)

    Page.goto!(page, server.empty_page, wait_until: :networkidle)
    assert :counters.get(request_count, 1) == 1
    Page.goto!(page, server.empty_page, wait_until: :networkidle)
    assert :counters.get(request_count, 1) == 2
  end

  defp sse(conn) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("connection", "keep-alive")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.send_chunked(200)

    {:ok, _conn} = Plug.Conn.chunk(conn, "data: hello\n\n")
    Process.sleep(:infinity)
  end

  # issue: https://github.com/microsoft/playwright/issues/37226
  test "should not wait for an open EventSource connection", %{page: page, server: server} do
    TestServer.set_route(server, "/sse", &sse/1)

    TestServer.set_route(server, "/sse-page.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<script>new EventSource('/sse');</script>")
    end)

    response = Page.goto!(page, server.prefix <> "/sse-page.html", wait_until: :networkidle)
    assert Response.status(response) == 200
  end

  # issue: https://github.com/microsoft/playwright/issues/37226
  test "should not wait for an open EventSource connection in setContent", %{page: page, server: server} do
    TestServer.set_route(server, "/sse", &sse/1)

    Page.goto!(page, server.empty_page)

    Page.set_content!(
      page,
      """
      <script>
        window.__sseOpened = new Promise(resolve => {
          const es = new EventSource('/sse');
          es.onmessage = () => resolve();
        });
      </script>
      """,
      wait_until: :networkidle
    )

    Page.evaluate!(page, "() => window['__sseOpened']")
  end
end
