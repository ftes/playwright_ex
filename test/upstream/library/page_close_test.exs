defmodule PlaywrightEx.Library.PageCloseTest do
  @upstream "tests/library/page-close.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

  # tests/config/errors.ts
  @k_target_closed_error_message "Target page, context or browser has been closed"

  # tests/config/utils.ts stripAnsi
  defp strip_ansi(str), do: String.replace(str, ~r/\e\[[0-9;]*m/, "")

  defp message({:error, e}), do: Exception.message(e)

  test "should close page with active dialog", %{page: page} do
    Page.evaluate!(page, ~s("trigger builtins.setTimeout"))
    Page.set_content!(page, ~s|<button onclick="builtins.setTimeout(() => alert(1))">alert</button>|)
    Task.start(fn -> Page.click(page, "button") end)
    page |> Page.wait_for_event(:dialog) |> Promise.await!()
    Page.close!(page)
  end

  test "expect should not print timed out error message when page closes", %{page: page} do
    Page.set_content!(page, "<div id=node>Text content</div>")

    [error, _] =
      Task.await_many([
        Task.async(fn -> Expect.to_have_text(Page.locator(page, "div"), "hey", timeout: 100_000) end),
        Task.async(fn -> Page.close!(page) end)
      ])

    assert strip_ansi(message(error)) =~ "expect(locator).toHaveText(expected)"
    refute strip_ansi(message(error)) =~ "Timed out"
  end

  test "addLocatorHandler should throw when page closes", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")

    Page.add_locator_handler!(page, Page.get_by_text(page, "This interstitial covers the button"), fn ->
      Page.close!(page, reason: "custom reason")
    end)

    PlaywrightEx.Locator.hover!(Page.locator(page, "#aside"))

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('mouseover', 1);
    }
    """)

    error = PlaywrightEx.Locator.click(Page.locator(page, "#target"))
    assert message(error) =~ "custom reason"
  end

  test "should reject all promises when page is closed", %{page: page} do
    [error, _] =
      Task.await_many([
        Task.async(fn -> Page.evaluate(page, "() => new Promise(r => {})") end),
        Task.async(fn -> Page.close!(page) end)
      ])

    assert message(error) =~ @k_target_closed_error_message
  end

  test "should set the page close state", %{page: page} do
    assert Page.is_closed(page) == false
    Page.close!(page)
    assert Page.is_closed(page) == true
  end

  test "should pass page to close event", %{page: page} do
    closed_promise = Page.wait_for_event(page, :close)
    Page.close!(page)
    closed_page = Promise.await!(closed_promise)
    assert closed_page == page
  end

  test "should terminate network waiters", %{page: page, server: server} do
    request_promise = Page.wait_for_request(page, server.empty_page)
    response_promise = Page.wait_for_response(page, server.empty_page)
    Page.close!(page)
    results = [Promise.await(request_promise), Promise.await(response_promise)]

    for result <- results do
      message = message(result)
      assert message =~ @k_target_closed_error_message
      refute message =~ "Timeout"
    end
  end

  test "should be callable twice", %{page: page} do
    Task.await_many([
      Task.async(fn -> Page.close!(page) end),
      Task.async(fn -> Page.close!(page) end)
    ])

    Page.close!(page)
  end

  test "should return null if parent page has been closed", %{page: page} do
    popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window.open('about:blank')") end)
    Page.close!(page)
    opener = Page.opener!(popup)
    assert opener == nil
  end

  test "should fail with error upon disconnect", %{page: page} do
    wait_for_promise = Page.wait_for_event(page, :download)
    Page.close!(page)
    error = Promise.await(wait_for_promise)
    assert message(error) =~ @k_target_closed_error_message
  end

  test "page.close should work with window.close", %{page: page} do
    me = self()
    Page.on(page, :close, fn x -> send(me, {:closed, x}) end)
    Page.close!(page)
    assert_receive {:closed, _}
  end

  @tag skip:
         if(@browser_name == "firefox" and match?({:win32, _}, :os.type()),
           do: "upstream fixme: makes the next test to always timeout"
         )
  test "should not throw UnhandledPromiseRejection when page closes", %{page: page} do
    Task.await_many([
      Task.async(fn -> Page.close(page) end),
      Task.async(fn -> Mouse.click(Page.mouse(page), 1, 2) end)
    ])
  end

  test "interrupt request.response() and request.allHeaders() on page.close",
       %{page: page, server: server, browser_name: browser_name} do
    # issue: https://github.com/microsoft/playwright/issues/27227
    # res.setHeader without res.end(): the response never comes.
    TestServer.set_route(server, "/one-style.css", fn _conn -> Process.sleep(:infinity) end)
    req_promise = Page.wait_for_request(page, "**/one-style.css")
    Page.goto!(page, server.prefix <> "/one-style.html", wait_until: :domcontentloaded)
    req = Promise.await!(req_promise)
    resp_promise = Task.async(fn -> Request.response(req) end)
    headers_promise = Task.async(fn -> Request.all_headers(req) end)
    Page.close!(page)
    assert message(Task.await(resp_promise)) =~ @k_target_closed_error_message
    # All headers are the same as "provisional" headers in Firefox.
    if browser_name == "firefox" do
      {:ok, headers} = Task.await(headers_promise)
      assert headers["user-agent"]
    else
      assert message(Task.await(headers_promise)) =~ @k_target_closed_error_message
    end
  end

  test "should not treat navigations as new popups", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<a target=_blank rel=noopener href=\"/one-style.html\">yo</a>")
    popup = Page.expect_popup!(page, fn -> Page.click!(page, "a") end)
    me = self()
    Page.on(page, :popup, fn _ -> send(me, :bad_second_popup) end)
    Page.goto!(popup, server.cross_process_prefix <> "/empty.html")
    Page.close!(page)
    refute_received :bad_second_popup
  end

  test "should not result in unhandled rejection", %{page: page} do
    closed_promise = Page.wait_for_event(page, :close)
    Page.expose_function!(page, "foo", fn -> Page.close!(page) end)

    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => window.foo(), 0);
      return undefined;
    }
    """)

    Promise.await!(closed_promise)
    # Make a round-trip to be sure we did not throw immediately after closing.
    assert {:error, %{}} = Page.evaluate(page, "1 + 1")
  end

  test "should reject response.finished if page closes", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    TestServer.set_route(server, "/get", fn conn ->
      # In Firefox, |fetch| will be hanging until it receives |Content-Type| header
      # from server.
      conn =
        conn |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8") |> Plug.Conn.send_chunked(200)

      {:ok, _conn} = Plug.Conn.chunk(conn, "hello ")
      Process.sleep(:infinity)
    end)

    # send request and wait for server response
    page_response =
      Page.expect_event!(page, :response, fn ->
        Page.evaluate!(page, "() => fetch('./get', { method: 'GET' })")
      end)

    finish_promise = Task.async(fn -> Response.finished(page_response) end)
    Page.close!(page)
    error = Task.await(finish_promise)
    assert message(error) =~ "closed"
  end

  test "should not throw when continuing while page is closing", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      # done = Promise.all([void route.continue(), page.close()]): the handler does not await it.
      spawn(fn ->
        Task.start(fn -> Route.continue(route) end)
        send(me, {:done, Page.close(page)})
      end)
    end)

    Page.goto(page, server.empty_page)
    assert_receive {:done, :ok}, 5000
  end

  test "should not throw when continuing after page is closed", %{page: page, server: server} do
    me = self()

    Page.route!(page, "**/*", fn route ->
      Page.close!(page)
      # done = route.continue(): awaited by the test.
      spawn(fn -> send(me, {:done, Route.continue(route)}) end)
    end)

    error = Page.goto(page, server.empty_page)
    assert_receive {:done, :ok}, 5000
    assert {:error, %{}} = error
  end
end
