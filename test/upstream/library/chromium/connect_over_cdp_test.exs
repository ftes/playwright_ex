defmodule PlaywrightEx.Library.Chromium.ConnectOverCdpTest do
  @upstream "tests/library/chromium/connect-over-cdp.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Download
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Promise
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Worker

  # Deviations:
  #   * `connectOverCDP({ endpointURL })` is `connect_over_cdp(browser_type, endpoint_url, options)`:
  #     the API docs have the endpoint as the first argument only.
  #   * `9339 + testInfo.workerIndex` is a free port (modules run in parallel).
  #   * `http.get(.../json/version/)` uses the API request context.

  if System.get_env("BROWSER", "chromium") != "chromium", do: @moduletag(skip: "upstream skip: chromium only")

  defp header(conn, name), do: List.first(Plug.Conn.get_req_header(conn, name))

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp launch_with_port(browser_type, args \\ []) do
    port = free_port()
    browser_server = BrowserType.launch!(browser_type, args: ["--remote-debugging-port=#{port}" | args])
    on_exit(fn -> Browser.close(browser_server) end)
    {browser_server, port}
  end

  defp json_version(playwright, port) do
    request = APIRequest.new_context!(Playwright.request(playwright))
    json = request |> APIRequestContext.get!("http://127.0.0.1:#{port}/json/version/") |> APIResponse.text!()
    APIRequestContext.dispose!(request)
    json
  end

  test "should connect to an existing cdp session", %{browser_type: browser_type} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    contexts = Browser.contexts(cdp_browser)
    assert length(contexts) == 1
    Browser.close!(cdp_browser)
    Browser.close!(browser_server)
  end

  test "should connect when an existing page has no renderer", %{browser_type: browser_type, server: server} do
    {browser_server, port} = launch_with_port(browser_type)
    # Prepare a page without a renderer, e.g. one discarded by the Memory Saver.
    cdp_browser1 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    context1 = hd(Browser.contexts(cdp_browser1))
    healthy_page1 = BrowserContext.new_page!(context1)
    Page.goto!(healthy_page1, server.prefix <> "/title.html")
    crashed_page1 = BrowserContext.new_page!(context1)
    Page.goto!(crashed_page1, server.empty_page)
    crash = Page.wait_for_event(crashed_page1, :crash)
    Task.start(fn -> Page.goto(crashed_page1, "chrome://crash") end)
    Promise.await!(crash)
    Browser.close!(cdp_browser1)

    # Connecting again should not hang on the page without a renderer,
    # and should not report it at all.
    cdp_browser2 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    pages = BrowserContext.pages(hd(Browser.contexts(cdp_browser2)))
    assert Enum.map(pages, &Page.url/1) == [server.prefix <> "/title.html"]
    assert Page.title!(hd(pages)) == "Woof-Woof"
    Browser.close!(cdp_browser2)
    Browser.close!(browser_server)
  end

  test "should connect when the opener of an existing page has no renderer", %{
    browser_type: browser_type,
    server: server
  } do
    # The popup should be in a different process to survive the crash of the opener.
    {browser_server, port} = launch_with_port(browser_type, ["--site-per-process"])
    cdp_browser1 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    crashed_page1 = BrowserContext.new_page!(hd(Browser.contexts(cdp_browser1)))
    Page.goto!(crashed_page1, server.empty_page)
    popup = Page.wait_for_event(crashed_page1, :popup)
    Page.evaluate!(crashed_page1, "url => { window.open(url); }", server.cross_process_prefix <> "/title.html")
    popup1 = Promise.await!(popup)
    Page.wait_for_load_state!(popup1)
    crash = Page.wait_for_event(crashed_page1, :crash)
    Task.start(fn -> Page.goto(crashed_page1, "chrome://crash") end)
    Promise.await!(crash)
    Browser.close!(cdp_browser1)

    # Connecting again should not report the opener, and should not wait for it.
    cdp_browser2 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    pages = BrowserContext.pages(hd(Browser.contexts(cdp_browser2)))
    assert Enum.map(pages, &Page.url/1) == [server.cross_process_prefix <> "/title.html"]
    assert Page.title!(hd(pages)) == "Woof-Woof"
    assert Page.opener!(hd(pages)) == nil
    Browser.close!(cdp_browser2)
    Browser.close!(browser_server)
  end

  # Ported, but on macOS headed Chrome shows each page in its own window: the victim stays
  # "visible", so chrome://discards disables [Urgent Discard] and the click times out.
  @tag skip: "headed Chrome on macOS: the page is visible and can't be discarded"
  test "should connect when an existing page has been discarded"

  @tag skip: "not ported: toImpl (server internals)"
  test "should cleanup artifacts dir after connectOverCDP disconnects due to ws close"

  @tag :tmp_dir
  test "should write traces to provided artifactsDir on connectOverCDP", %{browser_type: browser_type, tmp_dir: tmp_dir} do
    # test.skip(trace === 'on');  -- tracing is off
    {browser_server, port} = launch_with_port(browser_type)
    artifacts_dir = Path.join(tmp_dir, "custom-artifacts")

    cdp_browser =
      BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/", artifacts_dir: artifacts_dir)

    # expect(toImpl(cdpBrowser).options.artifactsDir).toBe(artifactsDir);  -- not ported: toImpl (server internals)
    # expect(toImpl(cdpBrowser).options.tracesDir).toBe(artifactsDir);  -- not ported: toImpl (server internals)

    context = hd(Browser.contexts(cdp_browser))
    Tracing.start!(BrowserContext.tracing(context), name: "cdp-trace", snapshots: true, screenshots: true)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<button>Hello</button>")
    Tracing.stop_chunk!(BrowserContext.tracing(context))

    assert File.exists?(Path.join(artifacts_dir, "cdp-trace.trace"))
    assert File.exists?(Path.join(artifacts_dir, "cdp-trace.network"))
    assert File.exists?(Path.join(artifacts_dir, "resources"))

    test = self()
    Browser.on(cdp_browser, :disconnected, fn _ -> send(test, :disconnected) end)
    Browser.close!(browser_server)
    assert_receive :disconnected

    assert File.exists?(artifacts_dir)
  end

  @tag :tmp_dir
  test "should connectOverCDP and manage downloads in default context", %{
    browser_type: browser_type,
    server: server,
    tmp_dir: tmp_dir
  } do
    TestServer.set_route(server, "/downloadWithFilename", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=file.txt")
      |> Plug.Conn.send_resp(200, "Hello world")
    end)

    {_browser_server, port} = launch_with_port(browser_type)
    browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    page = BrowserContext.new_page!(hd(Browser.contexts(browser)))
    Page.set_content!(page, ~s(<a href="#{server.prefix}/downloadWithFilename">download</a>))

    download = Page.wait_for_event(page, :download)
    Page.click!(page, "a")
    download = Promise.await!(download)
    assert Download.page(download) == page
    assert Download.url(download) == "#{server.prefix}/downloadWithFilename"
    assert Download.suggested_filename(download) == "file.txt"

    user_path = Path.join(tmp_dir, "download.txt")
    Download.save_as!(download, user_path)
    assert File.exists?(user_path)
    assert File.read!(user_path) == "Hello world"
  end

  test "should connect to an existing cdp session twice", %{browser_type: browser_type, server: server} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser1 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    cdp_browser2 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    contexts1 = Browser.contexts(cdp_browser1)
    assert length(contexts1) == 1
    [context1] = contexts1
    page1 = BrowserContext.new_page!(context1)
    Page.goto!(page1, server.empty_page)

    contexts2 = Browser.contexts(cdp_browser2)
    assert length(contexts2) == 1
    [context2] = contexts2
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)

    assert length(BrowserContext.pages(context1)) == 2
    assert length(BrowserContext.pages(context2)) == 2

    Page.evaluate!(page1, "() => alert('dialog race')")
    assert Page.title!(hd(BrowserContext.pages(context2))) == ""

    Browser.close!(cdp_browser1)
    Browser.close!(cdp_browser2)
    Browser.close!(browser_server)
  end

  test "should connect to existing page with iframe and navigate", %{browser_type: browser_type, server: server} do
    {browser_server, port} = launch_with_port(browser_type)
    context1 = Browser.new_context!(browser_server)
    page = BrowserContext.new_page!(context1)
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    contexts = Browser.contexts(cdp_browser)
    assert length(contexts) == 1
    Page.goto!(hd(BrowserContext.pages(hd(contexts))), server.empty_page)
    Browser.close!(cdp_browser)
    Browser.close!(browser_server)
  end

  test "should connect to existing service workers", %{browser_type: browser_type, server: server} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser1 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}")
    context = hd(Browser.contexts(cdp_browser1))
    page = BrowserContext.new_page!(hd(Browser.contexts(cdp_browser1)))
    worker = BrowserContext.wait_for_event(context, :service_worker)
    Page.goto!(page, server.prefix <> "/serviceworkers/empty/sw.html")
    worker = Promise.await!(worker)
    assert Worker.evaluate!(worker, "() => self.toString()") == "[object ServiceWorkerGlobalScope]"
    Browser.close!(cdp_browser1)

    cdp_browser2 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}")
    context2 = hd(Browser.contexts(cdp_browser2))
    assert length(BrowserContext.service_workers(context2)) == 1
    Browser.close!(cdp_browser2)
    Browser.close!(browser_server)
  end

  test "should connect over a ws endpoint", %{browser_type: browser_type, playwright: playwright} do
    {browser_server, port} = launch_with_port(browser_type)
    json = json_version(playwright, port)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, JSON.decode!(json)["webSocketDebuggerUrl"])
    contexts = Browser.contexts(cdp_browser)
    assert length(contexts) == 1
    Browser.close!(cdp_browser)

    # also connect with the deprecated wsEndpoint option
    # (the API has no `wsEndpoint` option: the endpoint is the first argument)
    cdp_browser2 = BrowserType.connect_over_cdp!(browser_type, JSON.decode!(json)["webSocketDebuggerUrl"])
    contexts2 = Browser.contexts(cdp_browser2)
    assert length(contexts2) == 1
    Browser.close!(cdp_browser2)
    Browser.close!(browser_server)
  end

  test "should send extra headers with connect request", %{browser_type: browser_type, server: server} do
    # `server.waitForWebSocketConnectionRequest()`: the upgrade request (TestServer has no WebSocket).
    request = TestServer.wait_for_web_socket_connection_request(server)

    BrowserType.connect_over_cdp(browser_type, "ws://localhost:#{server.port}/ws",
      headers: %{"User-Agent" => "Playwright", "foo" => "bar"},
      timeout: 100
    )

    request = Task.await(request)
    assert header(request, "user-agent") == "Playwright"
    assert header(request, "foo") == "bar"

    request = TestServer.wait_for_request(server, "/json/version/")

    BrowserType.connect_over_cdp(browser_type, "http://localhost:#{server.port}",
      headers: %{"User-Agent" => "Playwright", "foo" => "bar"},
      timeout: 100
    )

    request = Task.await(request)
    assert header(request, "user-agent") == "Playwright"
    assert header(request, "foo") == "bar"
  end

  test "should keep URL parameters when adding json/version", %{browser_type: browser_type, server: server} do
    request = TestServer.wait_for_request(server, "/browser/json/version/?foo=bar")
    BrowserType.connect_over_cdp(browser_type, "http://localhost:#{server.port}/browser/?foo=bar")
    Task.await(request)
  end

  test "should append /json/version with a slash if there isnt one", %{browser_type: browser_type, server: server} do
    request = TestServer.wait_for_request(server, "/browser/json/version/?foo=bar")
    BrowserType.connect_over_cdp(browser_type, "http://localhost:#{server.port}/browser?foo=bar")
    Task.await(request)
  end

  test "should send default User-Agent header with connect request", %{browser_type: browser_type, server: server} do
    request = TestServer.wait_for_web_socket_connection_request(server)

    BrowserType.connect_over_cdp(browser_type, "ws://localhost:#{server.port}/ws",
      headers: %{"foo" => "bar"},
      timeout: 100
    )

    request = Task.await(request)
    # `getUserAgent()` of the driver (the test can't compute it): `Playwright/<version> (<os>) ...`.
    assert header(request, "user-agent") =~ ~r"^Playwright/#{PlaywrightEx.Driver.version()} \(.+\) "
    assert header(request, "foo") == "bar"
  end

  test "should report all pages in an existing browser", %{browser_type: browser_type} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    contexts = Browser.contexts(cdp_browser)
    assert length(contexts) == 1
    for _ <- 1..3, do: BrowserContext.new_page!(hd(contexts))
    Browser.close!(cdp_browser)

    cdp_browser2 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    assert length(BrowserContext.pages(hd(Browser.contexts(cdp_browser2)))) == 3

    Browser.close!(cdp_browser2)
    Browser.close!(browser_server)
  end

  # test.skip(mode !== 'default'): out of process, NODE_TLS_REJECT_UNAUTHORIZED can't be set in the driver.
  @tag skip: "upstream skip: Out of process transport does not allow us to set env vars dynamically"
  test "should connect via https"

  test "should return valid browser from context.browser()", %{browser_type: browser_type} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    contexts = Browser.contexts(cdp_browser)
    assert length(contexts) == 1
    assert BrowserContext.browser(hd(contexts)) == cdp_browser

    context2 = Browser.new_context!(cdp_browser)
    assert BrowserContext.browser(context2) == cdp_browser

    Browser.close!(cdp_browser)
    Browser.close!(browser_server)
  end

  test "should report an expected error when the endpointURL returns a non-expected status code", %{
    browser_type: browser_type,
    server: server
  } do
    TestServer.set_route(server, "/json/version/", fn conn ->
      Plug.Conn.send_resp(conn, 404, JSON.encode!(%{webSocketDebuggerUrl: "dont-use-me"}))
    end)

    {:error, error} = BrowserType.connect_over_cdp(browser_type, server.prefix)

    assert Exception.message(error) =~
             "browserType.connectOverCDP: Unexpected status 404 when connecting to #{server.prefix}/json/version/"
  end

  test "should report an expected error when the endpoint URL JSON webSocketDebuggerUrl is undefined", %{
    browser_type: browser_type,
    server: server
  } do
    TestServer.set_route(server, "/json/version/", fn conn ->
      Plug.Conn.send_resp(conn, 200, JSON.encode!(%{}))
    end)

    {:error, error} = BrowserType.connect_over_cdp(browser_type, server.prefix)
    assert Exception.message(error) =~ "browserType.connectOverCDP: Invalid URL"
  end

  test "should connect to an existing cdp session when passed as a first argument", %{browser_type: browser_type} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    contexts = Browser.contexts(cdp_browser)
    assert length(contexts) == 1
    Browser.close!(cdp_browser)
    Browser.close!(browser_server)
  end

  test "should use proxy with connectOverCDP", %{browser_type: browser_type, server: server} do
    TestServer.set_route(server, "/target.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, "<html><title>Served by the proxy</title></html>")
    end)

    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    context = Browser.new_context!(cdp_browser, proxy: %{server: "localhost:#{server.port}"})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "http://non-existent.com/target.html")
    assert Page.title!(page) == "Served by the proxy"
    Browser.close!(cdp_browser)
    Browser.close!(browser_server)
  end

  @tag skip: "upstream skip: Out of process transport does not allow us to set env vars dynamically"
  test "should use env proxy with connectOverCDP discovery request"

  @tag skip: "upstream skip: Out of process transport does not allow us to set env vars dynamically"
  test "should send target Host header when using env HTTP proxy with connectOverCDP"

  test "should be able to connect via localhost", %{browser_type: browser_type} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://localhost:#{port}")
    contexts = Browser.contexts(cdp_browser)
    assert length(contexts) == 1
    Browser.close!(cdp_browser)
    Browser.close!(browser_server)
  end

  test "emulate media should not be affected by second connectOverCDP with noDefaults", %{browser_type: browser_type} do
    {browser_server, port} = launch_with_port(browser_type)
    is_print = fn page -> Page.evaluate!(page, "() => matchMedia('print').matches") end

    browser1 = BrowserType.connect_over_cdp!(browser_type, "http://localhost:#{port}")
    context1 = Browser.new_context!(browser1)
    page1 = BrowserContext.new_page!(context1)
    Page.emulate_media!(page1, media: :print)
    assert is_print.(page1) == true
    browser2 = BrowserType.connect_over_cdp!(browser_type, "http://localhost:#{port}", no_defaults: true)
    assert is_print.(page1) == true
    [browser1, browser2] |> Enum.map(&Task.async(fn -> Browser.close!(&1) end)) |> Task.await_many(:infinity)
    Browser.close!(browser_server)
  end

  @tag :tmp_dir
  test "should allow tracing over cdp session", %{browser_type: browser_type, tmp_dir: tmp_dir} do
    # test.skip(trace === 'on');  -- tracing is off
    {_browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    [context] = Browser.contexts(cdp_browser)
    Tracing.start!(BrowserContext.tracing(context), screenshots: true, snapshots: true)
    page = BrowserContext.new_page!(context)
    Page.evaluate!(page, "() => 2 + 2")
    trace_zip = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(BrowserContext.tracing(context), path: trace_zip)
    Browser.close!(cdp_browser)
    assert File.exists?(trace_zip)
  end

  test "setInputFiles should preserve lastModified timestamp", %{browser_type: browser_type, asset: asset} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    [context] = Browser.contexts(cdp_browser)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<input type=file multiple=true/>")
    input = Page.locator(page, "input")
    files = ["file-to-upload.txt", "file-to-upload-2.txt"]
    Locator.set_input_files!(input, Enum.map(files, asset))
    assert Locator.evaluate!(input, "e => [...e.files].map(f => f.name)") == files
    timestamps = Locator.evaluate!(input, "e => [...e.files].map(f => f.lastModified)")

    expected_timestamps =
      Enum.map(files, fn file -> File.stat!(asset.(file), time: :posix).mtime * 1000 end)

    # On Linux browser sometimes reduces the timestamp by 1ms: 1696272058110.0715  -> 1696272058109 or even
    # rounds it to seconds in WebKit: 1696272058110 -> 1696272058000.
    for {timestamp, expected} <- Enum.zip(timestamps, expected_timestamps),
        do: assert(abs(timestamp - expected) <= 1000)

    Browser.close!(cdp_browser)
    Browser.close!(browser_server)
  end

  @tag skip: "not ported: toImpl (server internals)"
  test "setInputFiles should use local path when isLocal is set"

  test "should print custom ws close error", %{browser_type: browser_type, server: server} do
    TestServer.once_web_socket_connection(server, fn ws ->
      TestServer.WebSocket.on(ws, :message, fn -> TestServer.WebSocket.close(ws, 4123, "Oh my!") end)
    end)

    {:error, error} = BrowserType.connect_over_cdp(browser_type, "ws://localhost:#{server.port}/ws")
    assert Exception.message(error) =~ "Browser logs:\n\nOh my!\n"
  end

  @tag skip: "not ported: toImpl (server internals)"
  test "should not reuse utility worlds between two clients"

  test "should get title and URL of existing page", %{browser_type: browser_type, server: server} do
    {browser_server, port} = launch_with_port(browser_type)
    cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    [context] = Browser.contexts(cdp_browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => document.title = 'my title'")

    cdp_browser2 = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
    [context] = Browser.contexts(cdp_browser2)
    [page] = BrowserContext.pages(context)
    assert Page.url(page) == server.empty_page
    assert Page.title!(page) == "my title"

    Browser.close!(cdp_browser)
    Browser.close!(cdp_browser2)
    Browser.close!(browser_server)
  end

  test "should skip default overrides with noDefaults", %{browser_type: browser_type, server: server} do
    {_browser_server, port} = launch_with_port(browser_type)
    browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/", no_defaults: true)
    default_context = hd(Browser.contexts(browser))
    page = BrowserContext.new_page!(default_context)

    # Browser.setDownloadBehavior was not sent, so no Playwright download event fires.
    TestServer.set_route(server, "/download", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=file.txt")
      |> Plug.Conn.send_resp(200, "Hello world")
    end)

    Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
    test = self()
    Page.on(page, :download, fn _ -> send(test, :saw_download) end)
    Page.click!(page, "a")
    Page.wait_for_timeout!(page, 500)
    refute_received :saw_download

    Browser.close!(browser)
  end

  test "noDefaults should not affect new contexts", %{browser_type: browser_type} do
    {browser_server, port} = launch_with_port(browser_type)
    browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/", no_defaults: true)

    # New contexts should still get normal Playwright defaults.
    new_context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(new_context)
    has_focus = Page.evaluate!(page, "() => document.hasFocus()")
    assert has_focus == true

    BrowserContext.close!(new_context)
    Browser.close!(browser)
    Browser.close!(browser_server)
  end

  @tag skip: "not ported: connectOverCDP(transport) (PLAN: out of scope)"
  test "should connect over CDP using a ConnectionTransport"
end
