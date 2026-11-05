defmodule PlaywrightEx.Library.IgnorehttpserrorsTest do
  @upstream "tests/library/ignorehttpserrors.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @browser_name System.get_env("BROWSER", "chromium")

  @ws_evaluate """
  endpoint => {
    let cb;
    const result = new Promise(f => cb = f);
    const ws = new WebSocket(endpoint);
    ws.addEventListener('message', data => { ws.close(); cb(data.data); });
    ws.addEventListener('error', error => cb('Error'));
    return result;
  }
  """

  test "should work @smoke", %{browser: browser, https_server: https_server} do
    context = Browser.new_context!(browser, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    {:ok, response} = Page.goto(page, https_server.empty_page)
    assert Response.ok(response) == true
    BrowserContext.close!(context)
  end

  test "should isolate contexts", %{browser: browser, https_server: https_server} do
    context = Browser.new_context!(browser, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    {:ok, response} = Page.goto(page, https_server.empty_page)
    assert Response.ok(response) == true
    BrowserContext.close!(context)

    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    assert {:error, _} = Page.goto(page, https_server.empty_page)
    BrowserContext.close!(context)
  end

  @tag skip:
         if(@browser_name == "webkit" and match?({:unix, :linux}, :os.type()),
           do: "fixme: See https://bugs.webkit.org/show_bug.cgi?id=293148"
         )
  test "should isolated contexts that share network process", %{browser: browser, https_server: https_server} do
    context = Browser.new_context!(browser, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, https_server.empty_page)
    assert Response.ok(response) == true
    # Closing the context will remove WebsiteDataStore and stop the network process
    # which will make the test pass.
    # BrowserContext.close!(context)

    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    assert {:error, _} = Page.goto(page, https_server.empty_page), "A TLS error expected, but the request succeeded."
    BrowserContext.close!(context)
  end

  test "should work with mixed content", %{browser: browser, server: server, https_server: https_server} do
    TestServer.set_route(https_server, "/mixedcontent.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, "<iframe src=#{server.empty_page}></iframe>")
    end)

    context = Browser.new_context!(browser, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, https_server.prefix <> "/mixedcontent.html", wait_until: :load)
    assert length(Page.frames(page)) == 2
    # Make sure blocked iframe has functional execution context
    # @see https://github.com/GoogleChrome/puppeteer/issues/2709
    assert Frame.evaluate!(Enum.at(Page.frames(page), 0), "1 + 2") == 3
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "2 + 3") == 5
    BrowserContext.close!(context)
  end

  test "should work with WebSocket", %{browser: browser, https_server: https_server} do
    TestServer.send_on_web_socket_connection(https_server, "incoming")
    context = Browser.new_context!(browser, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    value = Page.evaluate!(page, @ws_evaluate, String.replace(https_server.prefix, "https", "wss") <> "/ws")
    assert value == "incoming"
    BrowserContext.close!(context)
  end

  test "should fail with WebSocket if not ignored", %{browser: browser, https_server: https_server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    value = Page.evaluate!(page, @ws_evaluate, String.replace(https_server.prefix, "https", "wss") <> "/ws")
    assert value == "Error"
    BrowserContext.close!(context)
  end

  @tag skip:
         if(@browser_name == "chromium",
           do: "fixme: Failed to register a ServiceWorker: An SSL certificate error occurred when fetching the script."
         )
  test "serviceWorker should intercept document request", %{browser: browser, https_server: https_server} do
    context = Browser.new_context!(browser, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    BrowserContext.route!(context, "**/*", fn route -> Route.continue!(route) end)

    TestServer.set_route(https_server, "/sw.js", fn conn ->
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

    Page.goto!(page, https_server.empty_page)

    Page.evaluate!(page, """
    async () => {
      const waitForControllerChange = new Promise(resolve => navigator.serviceWorker.oncontrollerchange = resolve);
      await navigator.serviceWorker.register('/sw.js');
      await waitForControllerChange;
    }
    """)

    Page.reload!(page)
    assert Page.text_content!(page, "body") == "intercepted"
    BrowserContext.close!(context)
  end
end
