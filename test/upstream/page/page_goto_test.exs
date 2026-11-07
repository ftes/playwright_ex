defmodule PlaywrightEx.Page.PageGotoTest do
  @upstream "tests/page/page-goto.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import ExUnit.CaptureLog

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.TimeoutError
  alias PlaywrightEx.Utils

  @moduletag :page

  # url.pathToFileURL(path).href
  defp path_to_file_url(path), do: "file://" <> URI.encode(path)

  # tests/config/utils.ts expectedSSLError

  # `server.setRoute(path, (req, res) => {})`: the request hangs.
  defp hang(_conn), do: Process.sleep(:infinity)

  # `server.setRoute(path, async (req, res) => { events.push('started x'); await 2s; res.end(body); events.push('finished x') })`
  defp slow_route(events, name, body) do
    fn conn ->
      Agent.update(events, &(&1 ++ ["started #{name}"]))
      Process.sleep(2000)
      conn = conn |> Plug.Conn.put_resp_header("content-type", "text/html") |> Plug.Conn.send_resp(200, body)
      Agent.update(events, &(&1 ++ ["finished #{name}"]))
      conn
    end
  end

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  # Collects events sent by listeners: `const events = []; page.on(..., () => events.push(...))`.
  defp received(acc \\ []) do
    receive do
      {:event, event} -> received([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "NA-001 should work @smoke", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page
  end

  test "NA-002 should work with file URL", %{page: page, asset: asset} do
    fileurl = path_to_file_url(asset.("empty.html"))
    Page.goto!(page, fileurl)
    assert String.downcase(Page.url(page)) == String.downcase(fileurl)
    assert length(Page.frames(page)) == 1
  end

  test "NA-003 should navigate from file URL to about:blank", %{page: page, asset: asset} do
    Page.goto!(page, path_to_file_url(asset.("empty.html")))
    Page.goto!(page, "about:blank")
  end

  test "NA-004 should work with file URL with subframes", %{page: page, asset: asset} do
    fileurl = path_to_file_url(asset.("frames/two-frames.html"))
    Page.goto!(page, fileurl)
    assert String.downcase(Page.url(page)) == String.downcase(fileurl)
    assert length(Page.frames(page)) == 3
  end

  test "NA-005 should use http for no protocol", %{page: page, server: server} do
    Page.goto!(page, String.replace_prefix(server.empty_page, "http://", ""))
    assert Page.url(page) == server.empty_page
  end

  test "NA-006 should work cross-process", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page

    url = server.cross_process_prefix <> "/empty.html"
    test = self()
    Page.on(page, :request, fn r -> if Request.url(r) == url, do: send(test, {:event, Request.frame(r)}) end)
    response = Page.goto!(page, url)
    assert Page.url(page) == url
    assert Response.frame(response) == Page.main_frame(page)
    assert received() == [Page.main_frame(page)]
    assert Response.url(response) == url
  end

  test "NA-007 should work with cross-process that fails before committing", %{page: page, server: server} do
    # req.socket.destroy(): kill the connection's handler process.
    TestServer.set_route(server, "/empty.html", fn _conn -> Process.exit(self(), :kill) end)
    response1 = Page.goto!(page, server.cross_process_prefix <> "/title.html")
    Response.finished!(response1)
    {:error, error} = Page.goto(page, server.empty_page)
    assert is_exception(error)
  end

  test "NA-008 should work with Cross-Origin-Opener-Policy", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
      # Note: without 'onload', Firefox sometimes does not fire the load event
      # over the protocol. The reason is unclear.
      |> Plug.Conn.send_resp(200, """
        <div>Hello there!</div>
        <script>window.onload = () => console.log('onload')</script>
      """)
    end)

    test = self()
    Page.on(page, :request, fn r -> send(test, {:event, {"request", r}}) end)
    Page.on(page, :request_failed, fn r -> send(test, {:event, {"requestfailed", r}}) end)
    Page.on(page, :request_finished, fn r -> send(test, {:event, {"requestfinished", r}}) end)
    Page.on(page, :response, fn r -> send(test, {:event, {"response", Response.request(r)}}) end)
    response = Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page
    Response.finished!(response)
    {events, requests} = Enum.unzip(received())
    assert events == ["request", "response", "requestfinished"]
    assert MapSet.size(MapSet.new(requests)) == 1
    assert Request.failure(Response.request(response)) == nil
  end

  for cross_origin_embedder_policy <- [nil, "require-corp"] do
    @coep_headers if(cross_origin_embedder_policy,
                    do: [{"cross-origin-embedder-policy", cross_origin_embedder_policy}],
                    else: []
                  )
    test "NA-009 should work with Cross-Origin-Opener-Policy#{if cross_origin_embedder_policy, do: " and Cross-Origin-Embedder-Policy"} and history state",
         %{page: page, server: server} do
      TestServer.set_route(server, "/empty.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
        |> then(
          &Enum.reduce(@coep_headers, &1, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end)
        )
        |> Plug.Conn.send_resp(200, """
          <!doctype html>
          <h1>hello</h1>
          <script type="module">history.replaceState({ key: 1 }, '', location.href);</script>
        """)
      end)

      response = Page.goto!(page, server.empty_page)
      assert Response.status(response) == 200
      assert Page.url(page) == server.empty_page
      assert Page.evaluate!(page, "() => history.state") == %{"key" => 1}
      Expect.to_have_text!(Page.locator(page, "h1"), "hello")
    end
  end

  test "NA-010 should work with Cross-Origin-Opener-Policy and interception", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
      # Note: without 'onload', Firefox sometimes does not fire the load event
      # over the protocol. The reason is unclear.
      |> Plug.Conn.send_resp(200, """
        <div>Hello there!</div>
        <script>window.onload = () => console.log('onload')</script>
      """)
    end)

    test = self()
    Page.on(page, :request, fn r -> send(test, {:event, {"request", r}}) end)
    Page.on(page, :request_failed, fn r -> send(test, {:event, {"requestfailed", r}}) end)
    Page.on(page, :request_finished, fn r -> send(test, {:event, {"requestfinished", r}}) end)
    Page.on(page, :response, fn r -> send(test, {:event, {"response", Response.request(r)}}) end)

    Page.route!(page, "**/*", fn route ->
      Page.wait_for_timeout!(page, 100)
      Route.continue!(route)
    end)

    response = Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page
    Response.finished!(response)
    {events, requests} = Enum.unzip(received())
    assert events == ["request", "response", "requestfinished"]
    assert MapSet.size(MapSet.new(requests)) == 1
    assert Request.failure(Response.request(response)) == nil
  end

  test "NA-011 should work with Cross-Origin-Opener-Policy after redirect", %{page: page, server: server} do
    TestServer.set_redirect(server, "/redirect", "/empty.html")

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
      # Note: without 'onload', Firefox sometimes does not fire the load event
      # over the protocol. The reason is unclear.
      |> Plug.Conn.send_resp(200, """
        <div>Hello there!</div>
        <script>window.onload = () => console.log('onload')</script>
      """)
    end)

    test = self()
    Page.on(page, :request, fn r -> send(test, {:event, {"request", r}}) end)
    Page.on(page, :request_failed, fn r -> send(test, {:event, {"requestfailed", r}}) end)
    Page.on(page, :request_finished, fn r -> send(test, {:event, {"requestfinished", r}}) end)
    Page.on(page, :response, fn r -> send(test, {:event, {"response", Response.request(r)}}) end)
    response = Page.goto!(page, server.prefix <> "/redirect")
    assert Page.url(page) == server.empty_page
    Response.finished!(response)
    {events, requests} = Enum.unzip(received())
    assert events == ["request", "response", "requestfinished", "request", "response", "requestfinished"]
    assert MapSet.size(MapSet.new(requests)) == 2
    assert Request.failure(Response.request(response)) == nil
    first_request = Request.redirected_from(Response.request(response))
    assert first_request
    assert Request.url(first_request) == server.prefix <> "/redirect"
  end

  test "NA-012 should capture iframe navigation request", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page

    test = self()

    Page.on(page, :request, fn r ->
      if Request.url(r) == server.prefix <> "/frames/frame.html", do: send(test, {:event, Request.frame(r)})
    end)

    response = Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    assert Page.url(page) == server.prefix <> "/frames/one-frame.html"
    assert Response.frame(response) == Page.main_frame(page)
    assert Response.url(response) == server.prefix <> "/frames/one-frame.html"

    assert length(Page.frames(page)) == 2
    assert received() == [Enum.at(Page.frames(page), 1)]
  end

  test "NA-013 should capture cross-process iframe navigation request", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page

    test = self()

    Page.on(page, :request, fn r ->
      if Request.url(r) == server.cross_process_prefix <> "/frames/frame.html",
        do: send(test, {:event, Request.frame(r)})
    end)

    response = Page.goto!(page, server.cross_process_prefix <> "/frames/one-frame.html")
    assert Page.url(page) == server.cross_process_prefix <> "/frames/one-frame.html"
    assert Response.frame(response) == Page.main_frame(page)
    assert Response.url(response) == server.cross_process_prefix <> "/frames/one-frame.html"

    assert length(Page.frames(page)) == 2
    assert received() == [Enum.at(Page.frames(page), 1)]
  end

  test "NA-014 should work with anchor navigation", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page
    Page.goto!(page, server.empty_page <> "#foo")
    assert Page.url(page) == server.empty_page <> "#foo"
    Page.goto!(page, server.empty_page <> "#bar")
    assert Page.url(page) == server.empty_page <> "#bar"
  end

  test "NA-015 should work with redirects", %{page: page, server: server} do
    TestServer.set_redirect(server, "/redirect/1.html", "/redirect/2.html")
    TestServer.set_redirect(server, "/redirect/2.html", "/empty.html")
    response = Page.goto!(page, server.prefix <> "/redirect/1.html")
    assert Response.status(response) == 200
    assert Page.url(page) == server.empty_page
  end

  test "NA-016 should navigate to about:blank", %{page: page} do
    response = Page.goto!(page, "about:blank")
    assert response == nil
  end

  test "NA-017 should return response when page changes its URL after load", %{page: page, server: server} do
    response = Page.goto!(page, server.prefix <> "/historyapi.html")
    assert Response.status(response) == 200
  end

  test "NA-018 should work with subframes return 204", %{page: page, server: server} do
    TestServer.set_route(server, "/frames/frame.html", fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
  end

  test "NA-019 should work with subframes return 204 with domcontentloaded", %{page: page, server: server} do
    TestServer.set_route(server, "/frames/frame.html", fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    Page.goto!(page, server.prefix <> "/frames/one-frame.html", wait_until: :domcontentloaded)
  end

  @tag skip:
         if(@browser_name == "webkit" and match?({:unix, :linux}, :os.type()),
           do: "upstream fixme: Regressed in https://github.com/microsoft/playwright-browsers/pull/1297"
         )
  test "NA-020 should fail when server returns 204", %{page: page, server: server, browser_name: browser_name} do
    # WebKit just loads an empty page.
    TestServer.set_route(server, "/empty.html", fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    {:error, error} = Page.goto(page, server.empty_page)

    case browser_name do
      "chromium" -> assert Exception.message(error) =~ "net::ERR_ABORTED"
      "webkit" -> assert Exception.message(error) =~ "Aborted: 204 No Content"
      _ -> assert Exception.message(error) =~ "NS_BINDING_ABORTED"
    end
  end

  test "NA-021 should navigate to empty page with domcontentloaded", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page, wait_until: :domcontentloaded)
    assert Response.status(response) == 200
  end

  test "NA-022 should work when page calls history API in beforeunload", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      window.addEventListener('beforeunload', () => history.replaceState(null, 'initial', window.location.href), false);
    }
    """)

    response = Page.goto!(page, server.prefix <> "/grid.html")
    assert Response.status(response) == 200
  end

  test "NA-023 should fail when navigating to bad url", %{page: page, browser_name: browser_name} do
    {:error, error} = Page.goto(page, "asdfasdf")

    if browser_name in ["chromium", "webkit"],
      do: assert(Exception.message(error) =~ "Cannot navigate to invalid URL"),
      else: assert(Exception.message(error) =~ "Invalid url")
  end

  test "NA-024 should fail when navigating to bad SSL", %{
    page: page,
    browser_name: browser_name,
    https_server: https_server
  } do
    # Make sure that network events do not emit 'undefined'.
    # @see https://crbug.com/750469
    test = self()
    Page.on(page, :request, fn request -> send(test, {:event, request}) end)
    Page.on(page, :request_finished, fn request -> send(test, {:event, request}) end)
    Page.on(page, :request_failed, fn request -> send(test, {:event, request}) end)
    {:error, error} = Page.goto(page, https_server.empty_page)
    assert Enum.all?(received())
    assert Exception.message(error) =~ Utils.expected_ssl_error(browser_name)
  end

  test "NA-025 should fail when navigating to bad SSL after redirects",
       %{page: page, browser_name: browser_name, server: server, https_server: https_server} do
    TestServer.set_redirect(server, "/redirect/1.html", "/redirect/2.html")
    TestServer.set_redirect(server, "/redirect/2.html", "/empty.html")
    {:error, error} = Page.goto(page, https_server.prefix <> "/redirect/1.html")
    assert Exception.message(error) =~ Utils.expected_ssl_error(browser_name)
  end

  test "NA-026 should not crash when navigating to bad SSL after a cross origin navigation",
       %{page: page, server: server, https_server: https_server} do
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    Page.goto(page, https_server.empty_page)
  end

  test "NA-027 should not throw if networkidle0 is passed as an option", %{page: page, server: server} do
    # networkidle0 is undocumented: passed as the wire string.
    Page.goto!(page, server.empty_page, wait_until: "networkidle0")
  end

  test "NA-028 should throw if networkidle2 is passed as an option", %{page: page, server: server} do
    # networkidle2 is not allowed: passed as the wire string.
    {:error, error} = Page.goto(page, server.empty_page, wait_until: "networkidle2")
    assert Exception.message(error) =~ "waitUntil: expected one of (load|domcontentloaded|networkidle|commit)"
  end

  test "NA-029 should fail when main resources failed to load", %{page: page, browser_name: browser_name} do
    {:error, error} = Page.goto(page, "http://localhost:44123/non-existing-url")

    case browser_name do
      "chromium" -> assert Exception.message(error) =~ "net::ERR_CONNECTION_REFUSED"
      "webkit" -> assert Exception.message(error) =~ "Could not connect"
      _ -> assert Exception.message(error) =~ "NS_ERROR_CONNECTION_REFUSED"
    end
  end

  test "NA-030 should fail when exceeding maximum navigation timeout", %{page: page, server: server} do
    # Hang for request to the empty.html
    TestServer.set_route(server, "/empty.html", &hang/1)
    {:error, error} = Page.goto(page, server.prefix <> "/empty.html", timeout: 1)
    assert Exception.message(error) =~ "page.goto: Timeout 1ms exceeded."
    assert Exception.message(error) =~ server.prefix <> "/empty.html"
    assert %TimeoutError{} = error
  end

  test "NA-031 should fail when exceeding default maximum navigation timeout", %{page: page, server: server} do
    # Hang for request to the empty.html
    TestServer.set_route(server, "/empty.html", &hang/1)
    BrowserContext.set_default_navigation_timeout(Page.context(page), 2)
    Page.set_default_navigation_timeout(page, 1)
    {:error, error} = Page.goto(page, server.prefix <> "/empty.html")
    assert Exception.message(error) =~ "page.goto: Timeout 1ms exceeded."
    assert Exception.message(error) =~ server.prefix <> "/empty.html"
    assert %TimeoutError{} = error
  end

  test "NA-032 should fail when exceeding browser context navigation timeout", %{page: page, server: server} do
    # Hang for request to the empty.html
    TestServer.set_route(server, "/empty.html", &hang/1)
    BrowserContext.set_default_navigation_timeout(Page.context(page), 2)
    {:error, error} = Page.goto(page, server.prefix <> "/empty.html")
    assert Exception.message(error) =~ "page.goto: Timeout 2ms exceeded."
    assert Exception.message(error) =~ server.prefix <> "/empty.html"
    assert %TimeoutError{} = error
  end

  test "NA-033 should fail when exceeding default maximum timeout", %{page: page, server: server} do
    # Hang for request to the empty.html
    TestServer.set_route(server, "/empty.html", &hang/1)
    # Undo what harness did.
    BrowserContext.set_default_navigation_timeout(Page.context(page), nil)
    BrowserContext.set_default_timeout(Page.context(page), 2)
    Page.set_default_timeout(page, 1)
    {:error, error} = Page.goto(page, server.prefix <> "/empty.html")
    assert Exception.message(error) =~ "page.goto: Timeout 1ms exceeded."
    assert Exception.message(error) =~ server.prefix <> "/empty.html"
    assert %TimeoutError{} = error
  end

  test "NA-034 should fail when exceeding browser context timeout", %{page: page, server: server} do
    # Hang for request to the empty.html
    TestServer.set_route(server, "/empty.html", &hang/1)
    # Undo what harness did.
    BrowserContext.set_default_navigation_timeout(Page.context(page), nil)
    BrowserContext.set_default_timeout(Page.context(page), 2)
    {:error, error} = Page.goto(page, server.prefix <> "/empty.html")
    assert Exception.message(error) =~ "page.goto: Timeout 2ms exceeded."
    assert Exception.message(error) =~ server.prefix <> "/empty.html"
    assert %TimeoutError{} = error
  end

  test "NA-035 should prioritize default navigation timeout over default timeout", %{page: page, server: server} do
    # Hang for request to the empty.html
    TestServer.set_route(server, "/empty.html", &hang/1)
    Page.set_default_timeout(page, 0)
    Page.set_default_navigation_timeout(page, 1)
    {:error, error} = Page.goto(page, server.prefix <> "/empty.html")
    assert Exception.message(error) =~ "page.goto: Timeout 1ms exceeded."
    assert Exception.message(error) =~ server.prefix <> "/empty.html"
    assert %TimeoutError{} = error
  end

  test "NA-036 should disable timeout when its set to 0", %{page: page, server: server} do
    test = self()
    Page.once(page, :load, fn _ -> send(test, :loaded) end)
    assert {:ok, _} = Page.goto(page, server.prefix <> "/grid.html", timeout: 0, wait_until: :load)
    assert_received :loaded
  end

  test "NA-037 should fail when replaced by another navigation", %{
    page: page,
    server: server,
    browser_name: browser_name
  } do
    test = self()

    TestServer.set_route(server, "/empty.html", fn conn ->
      # anotherPromise = page.goto(...): started by the test when it hears from here.
      send(test, :another)
      # Hang request to empty.html.
      hang(conn)
    end)

    first = Runtime.Promise.async(fn -> Page.goto(page, server.prefix <> "/empty.html") end)
    assert_receive :another, 5_000
    another = Runtime.Promise.async(fn -> Page.goto(page, server.prefix <> "/one-style.html") end)
    {:error, error} = Runtime.Promise.await(first)
    Runtime.Promise.await(another)

    case browser_name do
      "chromium" ->
        assert Exception.message(error) =~ "net::ERR_ABORTED"

      "webkit" ->
        assert Exception.message(error) =~
                 ~s(page.goto: Navigation to "#{server.prefix <> "/empty.html"}" is interrupted by another navigation to "#{server.prefix <> "/one-style.html"}")

      _ ->
        # Firefox might yield either NS_BINDING_ABORTED or 'navigation interrupted by another one'
        assert Exception.message(error) =~
                 ~s(page.goto: Navigation to "#{server.prefix <> "/empty.html"}" is interrupted by another navigation to "#{server.prefix <> "/one-style.html"}") or
                 Exception.message(error) =~ "NS_BINDING_ABORTED"
    end
  end

  test "NA-038 js redirect overrides url bar navigation ", %{page: page, server: server, browser_name: browser_name} do
    # it.skip(trace === 'on', ...);  -- tracing is off
    TestServer.set_route(server, "/a", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
          <body>
            <script>
              setTimeout(() => {
                window.location.pathname = '/c';
              }, 1000);
            </script>
          </body>
      """)
    end)

    {:ok, events} = Agent.start_link(fn -> [] end)
    TestServer.set_route(server, "/b", slow_route(events, "b", "BBB"))
    TestServer.set_route(server, "/c", slow_route(events, "c", "CCC"))
    Page.goto!(page, server.prefix <> "/a")

    error =
      case Page.goto(page, server.prefix <> "/b") do
        {:ok, _} -> nil
        {:error, e} -> e
      end

    expect_events =
      if browser_name == "chromium",
        do: ["started b", "finished b"],
        else: ["started b", "started c", "finished b", "finished c"]

    Utils.to_pass(fn -> assert Agent.get(events, & &1) == expect_events end)
    assert Agent.get(events, & &1) == expect_events

    case browser_name do
      "chromium" ->
        # Chromium prioritizes the url bar navigation over the js redirect.
        refute error
        Expect.to_have_url!(page, server.prefix <> "/b")

      "webkit" ->
        assert Exception.message(error) =~
                 ~s(page.goto: Navigation to "#{server.prefix <> "/b"}" is interrupted by another navigation to "#{server.prefix <> "/c"}")

        Expect.to_have_url!(page, server.prefix <> "/c")

      "firefox" ->
        assert Exception.message(error) =~ "NS_BINDING_ABORTED"
        Expect.to_have_url!(page, server.prefix <> "/c")
    end
  end

  test "NA-039 should succeed on url bar navigation when there is pending navigation", %{page: page, server: server} do
    # it.skip(process.env.PW_CLOCK === 'frozen');  -- not ported: no frozen-clock mode
    TestServer.set_route(server, "/a", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
        <body>
          <script>
            setTimeout(() => {
              window.location.pathname = '/c';
            }, 10);
          </script>
        </body>
      """)
    end)

    {:ok, events} = Agent.start_link(fn -> [] end)
    TestServer.set_route(server, "/b", slow_route(events, "b", "BBB"))
    TestServer.set_route(server, "/c", slow_route(events, "c", "CCC"))
    Page.goto!(page, server.prefix <> "/a")
    Page.wait_for_timeout!(page, 1000)

    error =
      case Page.goto(page, server.prefix <> "/b") do
        {:ok, _} -> nil
        {:error, e} -> e
      end

    expect_events = ["started c", "started b", "finished c", "finished b"]
    Utils.to_pass(fn -> assert Agent.get(events, & &1) == expect_events end, timeout: 5000)
    assert Agent.get(events, & &1) == expect_events
    refute error
    assert Page.url(page) == server.prefix <> "/b"
  end

  test "NA-040 should work when navigating to valid url", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page)
    assert Response.ok(response) == true
  end

  test "NA-041 should work when navigating to data url", %{page: page} do
    response = Page.goto!(page, "data:text/html,hello")
    assert response == nil
  end

  test "NA-042 should work when navigating to 404", %{page: page, server: server} do
    response = Page.goto!(page, server.prefix <> "/not-found")
    assert Response.ok(response) == false
    assert Response.status(response) == 404
  end

  test "NA-043 should return last response in redirect chain", %{page: page, server: server} do
    TestServer.set_redirect(server, "/redirect/1.html", "/redirect/2.html")
    TestServer.set_redirect(server, "/redirect/2.html", "/redirect/3.html")
    TestServer.set_redirect(server, "/redirect/3.html", server.empty_page)
    response = Page.goto!(page, server.prefix <> "/redirect/1.html")
    assert Response.ok(response) == true
    assert Response.url(response) == server.empty_page
  end

  # process.on('warning'): the client's MaxListenersExceededWarning is logged (Logger); the
  # driver's own Node warnings (upstream: the in-process server's) go to its stderr, unchecked.
  test "NA-044 should not leak listeners during navigation", %{page: page, server: server} do
    warning = capture_log(fn -> for _ <- 1..20, do: Page.goto!(page, server.empty_page) end)
    refute warning =~ "MaxListenersExceededWarning"
  end

  # process.on('warning'): the client's MaxListenersExceededWarning is logged (Logger); the
  # driver's own Node warnings (upstream: the in-process server's) go to its stderr, unchecked.
  test "NA-045 should not leak listeners during bad navigation", %{page: page} do
    warning = capture_log(fn -> for _ <- 1..20, do: {:error, _} = Page.goto(page, "asdf") end)
    refute warning =~ "MaxListenersExceededWarning"
  end

  # process.on('warning'): the client's MaxListenersExceededWarning is logged (Logger); the
  # driver's own Node warnings (upstream: the in-process server's) go to its stderr, unchecked.
  test "NA-046 should not leak listeners during 20 waitForNavigation", %{page: page, server: server} do
    warning =
      capture_log(fn ->
        promises = for _ <- 1..20, do: Page.wait_for_navigation(page)
        Page.goto!(page, server.empty_page)
        for promise <- promises, do: PlaywrightEx.Promise.await!(promise)
      end)

    refute warning =~ "MaxListenersExceededWarning"
  end

  test "NA-047 should navigate to dataURL and not fire dataURL requests", %{page: page} do
    test = self()
    Page.on(page, :request, fn request -> send(test, {:event, request}) end)
    data_url = "data:text/html,<div>yo</div>"
    response = Page.goto!(page, data_url)
    assert response == nil
    assert received() == []
  end

  test "NA-048 should navigate to URL with hash and fire requests without hash", %{page: page, server: server} do
    test = self()
    Page.on(page, :request, fn request -> send(test, {:event, request}) end)
    response = Page.goto!(page, server.empty_page <> "#hash")
    assert Response.status(response) == 200
    assert Response.url(response) == server.empty_page
    requests = received()
    assert length(requests) == 1
    assert Request.url(hd(requests)) == server.empty_page
  end

  test "NA-049 should work with self requesting page", %{page: page, server: server} do
    response = Page.goto!(page, server.prefix <> "/self-request.html")
    assert Response.status(response) == 200
    assert Response.url(response) =~ "self-request.html"
  end

  test "NA-050 should fail when navigating and show the url at the error message", %{
    page: page,
    https_server: https_server
  } do
    url = https_server.prefix <> "/redirect/1.html"
    {:error, error} = Page.goto(page, url)
    assert Exception.message(error) =~ url
  end

  test "NA-051 should be able to navigate to a page controlled by service worker", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
    Page.evaluate!(page, "() => window['activationPromise']")
    Page.goto!(page, server.prefix <> "/serviceworkers/fetch/sw.html")
  end

  test "NA-052 should send referer", %{page: page, server: server} do
    request1 = TestServer.wait_for_request(server, "/grid.html")
    request2 = TestServer.wait_for_request(server, "/digits/1.png")
    Page.goto!(page, server.prefix <> "/grid.html", referer: "http://google.com/")
    assert header(Task.await(request1, :infinity), "referer") == "http://google.com/"
    # Make sure subresources do not inherit referer.
    assert header(Task.await(request2, :infinity), "referer") == server.prefix <> "/grid.html"
    assert Page.url(page) == server.prefix <> "/grid.html"
  end

  test "NA-053 should send referer of cross-origin URL", %{page: page, server: server} do
    request1 = TestServer.wait_for_request(server, "/grid.html")
    request2 = TestServer.wait_for_request(server, "/digits/1.png")
    Page.goto!(page, server.prefix <> "/grid.html", referer: "https://microsoft.com/xbox/")
    assert header(Task.await(request1, :infinity), "referer") == "https://microsoft.com/xbox/"
    # Make sure subresources do not inherit referer.
    assert header(Task.await(request2, :infinity), "referer") == server.prefix <> "/grid.html"
    assert Page.url(page) == server.prefix <> "/grid.html"
  end

  test "NA-054 should reject referer option when setExtraHTTPHeaders provides referer", %{page: page, server: server} do
    Page.set_extra_http_headers!(page, %{"referer" => "http://microsoft.com/"})
    {:error, error} = Page.goto(page, server.prefix <> "/grid.html", referer: "http://google.com/")
    assert Exception.message(error) =~ ~s("referer" is already specified as extra HTTP header)
    assert Exception.message(error) =~ server.prefix <> "/grid.html"
  end

  test "NA-055 should override referrer-policy", %{page: page, server: server} do
    TestServer.set_route(server, "/grid.html", fn conn ->
      conn |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer") |> then(&TestServer.serve_file(server, &1))
    end)

    request1 = TestServer.wait_for_request(server, "/grid.html")
    request2 = TestServer.wait_for_request(server, "/digits/1.png")
    Page.goto!(page, server.prefix <> "/grid.html", referer: "http://microsoft.com/")
    assert header(Task.await(request1, :infinity), "referer") == "http://microsoft.com/"
    # Make sure subresources do not inherit referer.
    assert header(Task.await(request2, :infinity), "referer") == nil
    assert Page.url(page) == server.prefix <> "/grid.html"
  end

  test "NA-056 should fail when canceled by another navigation", %{page: page, server: server} do
    TestServer.set_route(server, "/one-style.html", &hang/1)
    request = TestServer.wait_for_request(server, "/one-style.html")
    failed = Runtime.Promise.async(fn -> Page.goto(page, server.prefix <> "/one-style.html") end)
    Task.await(request, :infinity)
    Page.goto!(page, server.prefix <> "/empty.html")
    {:error, error} = Runtime.Promise.await(failed)
    assert Exception.message(error) != ""
  end

  test "NA-057 should work with lazy loading iframes", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/lazy-frame.html")
    assert length(Page.frames(page)) == 2
  end

  test "NA-058 should report raw buffer for main resource", %{page: page, server: server, browser_name: browser_name} do
    # it.fail(browserName === 'chromium', 'Chromium sends main resource as text')
    # it.fail(browserName === 'webkit' && platform === 'win32' && channel !== 'webkit-wsl', 'Same here')
    expected_failure(browser_name == "chromium" or (browser_name == "webkit" and match?({:win32, _}, :os.type())), fn ->
      TestServer.set_route(server, "/empty.html", fn conn -> Plug.Conn.send_resp(conn, 200, "Ü (lowercase ü)") end)
      response = Page.goto!(page, server.prefix <> "/empty.html")
      body = Response.body!(response)
      assert body == "Ü (lowercase ü)"
    end)
  end

  test "NA-059 should not throw unhandled rejections on invalid url", %{page: page} do
    {:error, e} = Page.goto(page, "https://www.youtube Panel Title.com/")
    assert Exception.message(e) =~ "Panel Title"
  end

  test "NA-060 should not crash when RTCPeerConnection is used", %{page: page, server: server} do
    TestServer.set_route(server, "/rtc.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
      <!DOCTYPE html>
      <html>
        <body>
          <script>
            window.RTCPeerConnection && new window.RTCPeerConnection({
              iceServers: []
            });
          </script>
        </body>
      </html>
      """)
    end)

    Page.goto!(page, server.prefix <> "/rtc.html")

    Page.evaluate!(page, """
    () => {
      // RTCPeerConnection is not present on WebKit Linux
      window.RTCPeerConnection && new window.RTCPeerConnection({
        iceServers: []
      });
    }
    """)
  end

  test "NA-061 should properly wait for load", %{page: page, server: server} do
    TestServer.set_route(server, "/slow.js", fn conn ->
      Process.sleep(100)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.send_resp(200, "window.results.push('slow module');export const foo = 'slow';")
    end)

    Page.goto!(page, server.prefix <> "/load-event/load-event.html")
    results = Page.evaluate!(page, "window.results")

    assert results == [
             "script tag after after module",
             "slow module",
             "module",
             "DOMContentLoaded",
             "load"
           ]
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: load/domcontentloaded events are flaky")
  test "NA-062 should not resolve goto upon window.stop()", %{page: page, server: server} do
    # it.fixme(browserName === 'firefox' && !isBidi, 'load/domcontentloaded events are flaky');
    # it.skip(process.env.PW_CLOCK === 'frozen');  -- not ported: no frozen-clock mode
    test = self()

    TestServer.set_route(server, "/module.js", fn conn ->
      conn = conn |> Plug.Conn.put_resp_header("content-type", "text/javascript") |> Plug.Conn.send_chunked(200)
      send(test, {:response, self()})

      receive do
        :end -> conn
      end
    end)

    module_request = TestServer.wait_for_request(server, "/module.js")
    navigation = Runtime.Promise.async(fn -> Page.goto(page, server.prefix <> "/window-stop.html") end, shared: true)
    Task.await(module_request, :infinity)
    done? = fn -> Runtime.Promise.settled?(navigation) and match?({:ok, _}, Runtime.Promise.await(navigation)) end
    refute done?.()
    # give it some time to erroneously resolve
    Page.wait_for_timeout!(page, 1000)
    assert_receive {:response, response}
    send(response, :end)
    # give it more time to erroneously resolve
    Page.wait_for_timeout!(page, 1000)
    refute done?.()
  end

  test "NA-063 should return from goto if new navigation is started", %{page: page, server: server} do
    TestServer.set_route(server, "/slow.js", &hang/1)

    navigation =
      Runtime.Promise.async(fn -> Page.goto!(page, server.prefix <> "/load-event/load-event.html") end, shared: true)

    Process.sleep(500)
    refute Runtime.Promise.settled?(navigation)
    Page.goto!(page, server.empty_page)
    assert Response.status(Runtime.Promise.await(navigation)) == 200
  end

  test "NA-064 should return when navigation is committed if commit is specified", %{page: page, server: server} do
    TestServer.set_route(server, "/script.js", &hang/1)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s(<title>Hello</title><script src="script.js"></script>))
    end)

    response = Page.goto!(page, server.empty_page, wait_until: :commit)
    assert Response.status(response) == 200
    assert Page.title!(page) == "Hello"
  end

  test "NA-065 should wait for load when iframe attaches and detaches", %{page: page, server: server} do
    # it.skip(process.env.PW_CLOCK === 'frozen');  -- not ported: no frozen-clock mode
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
        <body>
          <script>
            const iframe = document.createElement('iframe');
            iframe.src = './iframe.html';
            document.body.appendChild(iframe);
            setTimeout(() => iframe.remove(), 1000);
          </script>
        </body>
      """)
    end)

    TestServer.set_route(server, "/iframe.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s(<link rel="stylesheet" href="./style2.css">))
    end)

    # Stall the css so that 'load' does not fire.
    TestServer.set_route(server, "/style2.css", &hang/1)

    frame_detached = Page.wait_for_event(page, :frame_detached)
    done = Runtime.Promise.async(fn -> Page.goto!(page, server.empty_page, wait_until: :load) end)
    # Make sure that iframe is gone.
    PlaywrightEx.Promise.await!(frame_detached)
    Runtime.Promise.await(done)
    assert Page.query_selector!(page, "iframe") == nil
  end

  test "NA-066 should return url with basic auth info", %{page: page, server: server} do
    url = "http://admin:admin@localhost:#{server.port}/empty.html"
    Page.goto!(page, url)
    assert Page.url(page) == url
  end
end
