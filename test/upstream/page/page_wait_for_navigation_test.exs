defmodule PlaywrightEx.Page.PageWaitForNavigationTest do
  @upstream "tests/page/page-wait-for-navigation.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Expect

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Response
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils

  @moduletag :page

  # tests/config/utils.ts expectedSSLError

  defp hang(_conn), do: Process.sleep(:infinity)

  # `promise.then(() => resolved = true)`: `resolved?(ref)` tells whether it has settled.
  defp then_resolved(promise) do
    test = self()
    ref = make_ref()
    spawn(fn -> send(test, {:resolved, ref, Promise.await(promise)}) end)
    ref
  end

  defp resolved?(ref) do
    receive do
      {:resolved, ^ref, _} = message ->
        send(self(), message)
        true
    after
      0 -> false
    end
  end

  test "WA-095 should work", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    response =
      Page.expect_navigation!(page, fn ->
        Page.evaluate!(page, "url => window.location.href = url", server.prefix <> "/grid.html")
      end)

    assert Response.ok(response) == true
    assert Response.url(response) =~ "grid.html"
  end

  test "WA-096 should respect timeout", %{page: page, server: server} do
    promise = Page.wait_for_navigation(page, url: "**/frame.html", timeout: 5000)
    Page.goto!(page, server.empty_page)
    {:error, error} = Promise.await(promise)
    assert Exception.message(error) =~ "page.waitForNavigation: Timeout 5000ms exceeded."
    assert Exception.message(error) =~ ~s(waiting for navigation to "**/frame.html" until "load")
    assert Exception.message(error) =~ ~s(navigated to "#{server.empty_page}")
  end

  test "WA-097 should work with both domcontentloaded and load", %{page: page, server: server} do
    test = self()

    TestServer.set_route(server, "/one-style.css", fn conn ->
      send(test, {:response, self()})

      receive do
        :end -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    css_request = TestServer.wait_for_request(server, "/one-style.css")
    # deviation: subscribe-first (OTP runtime)
    dom_content_loaded_promise = Page.wait_for_navigation(page, wait_until: :domcontentloaded)
    # `bothFired` is false while the load wait is pending.
    load_promise = Page.wait_for_navigation(page, wait_until: :load)
    both_fired = then_resolved(load_promise)
    navigation_promise = Runtime.Promise.async(fn -> Page.goto!(page, server.prefix <> "/one-style.html") end)

    Task.await(css_request, :infinity)
    assert_receive {:response, response}
    Promise.await!(dom_content_loaded_promise)
    refute resolved?(both_fired)
    send(response, :end)
    Promise.await!(load_promise)
    Runtime.Promise.await(navigation_promise)
  end

  test "WA-098 should work with commit", %{page: page, server: server} do
    TestServer.set_route(server, "/script.js", &hang/1)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s(<title>Hello</title><script src="script.js"></script>))
    end)

    # deviation: subscribe-first (OTP runtime)
    navigation = Page.wait_for_navigation(page, wait_until: :commit)
    Runtime.Promise.void(fn -> Page.goto(page, server.empty_page) end)
    Promise.await!(navigation)
    assert Page.title!(page) == "Hello"
  end

  test "WA-099 should work with clicking on anchor links", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<a href='#foobar'>foobar</a>")
    response = Page.expect_navigation!(page, fn -> Page.click!(page, "a") end)
    assert response == nil
    assert Page.url(page) == server.empty_page <> "#foobar"
  end

  test "WA-100 should work with clicking on links which do not commit navigation",
       %{page: page, server: server, https_server: https_server, browser_name: browser_name} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<a href='#{https_server.empty_page}'>foobar</a>")
    {:error, error} = Page.expect_navigation(page, fn -> Page.click!(page, "a") end)
    assert Exception.message(error) =~ Utils.expected_ssl_error(browser_name)
  end

  test "WA-101 should work with history.pushState()", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <a onclick='javascript:pushState()'>SPA</a>
      <script>
        function pushState() { history.pushState({}, '', 'wow.html') }
      </script>
    """)

    response = Page.expect_navigation!(page, fn -> Page.click!(page, "a") end)
    assert response == nil
    assert Page.url(page) == server.prefix <> "/wow.html"
  end

  test "WA-102 should work with history.replaceState()", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <a onclick='javascript:replaceState()'>SPA</a>
      <script>
        function replaceState() { history.replaceState({}, '', '/replaced.html') }
      </script>
    """)

    response = Page.expect_navigation!(page, fn -> Page.click!(page, "a") end)
    assert response == nil
    assert Page.url(page) == server.prefix <> "/replaced.html"
  end

  test "WA-103 should work with DOM history.back()/history.forward()", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <a id=back onclick='javascript:goBack()'>back</a>
      <a id=forward onclick='javascript:goForward()'>forward</a>
      <script>
        function goBack() { history.back(); }
        function goForward() { history.forward(); }
        history.pushState({}, '', '/first.html');
        history.pushState({}, '', '/second.html');
      </script>
    """)

    assert Page.url(page) == server.prefix <> "/second.html"
    back_response = Page.expect_navigation!(page, fn -> Page.click!(page, "a#back") end)
    assert back_response == nil
    assert Page.url(page) == server.prefix <> "/first.html"
    forward_response = Page.expect_navigation!(page, fn -> Page.click!(page, "a#forward") end)
    assert forward_response == nil
    assert Page.url(page) == server.prefix <> "/second.html"
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream fixme: WebKit issues load event in some cases, but not always")
  test "WA-104 should work when subframe issues window.stop()", %{page: page, server: server} do
    # it.fixme(browserName === 'webkit', 'WebKit issues load event in some cases, but not always');
    test = self()
    TestServer.set_route(server, "/frames/style.css", &hang/1)
    Page.once(page, :frame_attached, fn frame -> send(test, {:attached, frame}) end)
    Page.on(page, :frame_navigated, fn frame -> send(test, {:navigated, frame}) end)
    done = Runtime.Promise.async(fn -> Page.goto(page, server.prefix <> "/frames/one-frame.html") end, shared: true)
    assert_receive {:attached, frame}, 5000
    assert_receive {:navigated, ^frame}, 5000
    Frame.evaluate!(frame, "() => window.stop()")
    # `expect(done).toBe(true)`: the goto reply may still be in flight here, so a short bound.
    Expect.to_pass!(fn -> assert Runtime.Promise.settled?(done) end, timeout: 1000, intervals: [10])
    assert {:ok, _} = Runtime.Promise.await(done)
  end

  test "WA-105 should work with url match", %{page: page, server: server} do
    response1_promise = Page.wait_for_navigation(page, url: ~r/one-style\.html/)
    response2_promise = Page.wait_for_navigation(page, url: ~r/\/frame.html/)

    response3_promise =
      Page.wait_for_navigation(page, url: fn url -> URI.decode_query(URI.parse(url).query || "")["foo"] == "bar" end)

    {resolved1, resolved2, resolved3} =
      {then_resolved(response1_promise), then_resolved(response2_promise), then_resolved(response3_promise)}

    refute resolved?(resolved1)
    refute resolved?(resolved2)
    refute resolved?(resolved3)
    Page.goto!(page, server.empty_page)
    refute resolved?(resolved1)
    refute resolved?(resolved2)
    refute resolved?(resolved3)
    Page.goto!(page, server.prefix <> "/frame.html")
    refute resolved?(resolved1)
    response2 = Promise.await!(response2_promise)
    assert response2 != nil
    refute resolved?(resolved3)
    Page.goto!(page, server.prefix <> "/one-style.html")
    response1 = Promise.await!(response1_promise)
    assert response1 != nil
    refute resolved?(resolved3)
    Page.goto!(page, server.prefix <> "/frame.html?foo=bar")
    response3 = Promise.await!(response3_promise)
    assert response3 != nil
    Page.goto!(page, server.prefix <> "/empty.html")
    assert Response.url(response1) == server.prefix <> "/one-style.html"
    assert Response.url(response2) == server.prefix <> "/frame.html"
    assert Response.url(response3) == server.prefix <> "/frame.html?foo=bar"
  end

  test "WA-106 should work with url match for same document navigations", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    wait_promise = Page.wait_for_navigation(page, url: ~r/third\.html/)
    resolved = then_resolved(wait_promise)
    refute resolved?(resolved)
    Page.evaluate!(page, "() => { history.pushState({}, '', '/first.html'); }")
    refute resolved?(resolved)
    Page.evaluate!(page, "() => { history.pushState({}, '', '/second.html'); }")
    refute resolved?(resolved)
    Page.evaluate!(page, "() => { history.pushState({}, '', '/third.html'); }")
    Promise.await!(wait_promise)
    assert_receive {:resolved, ^resolved, {:ok, nil}}
  end

  test "WA-107 should work for cross-process navigations", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    wait_promise = Page.wait_for_navigation(page, wait_until: :domcontentloaded)
    url = server.cross_process_prefix <> "/empty.html"
    goto_promise = Runtime.Promise.async(fn -> Page.goto!(page, url) end)
    response = Promise.await!(wait_promise)
    assert Response.url(response) == url
    assert Page.url(page) == url
    assert Page.evaluate!(page, "document.location.href") == url
    Runtime.Promise.await(goto_promise)
  end

  test "WA-108 should work on frame", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    frame = Enum.at(Page.frames(page), 1)

    response =
      Frame.expect_navigation!(frame, fn ->
        Frame.evaluate!(frame, "url => window.location.href = url", server.prefix <> "/grid.html")
      end)

    assert Response.ok(response) == true
    assert Response.url(response) =~ "grid.html"
    assert Response.frame(response) == frame
    assert Page.url(page) =~ "/frames/one-frame.html"
  end

  test "WA-109 should fail when frame detaches", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    frame = Enum.at(Page.frames(page), 1)
    TestServer.set_route(server, "/empty.html", &hang/1)
    TestServer.set_route(server, "/one-style.css", &hang/1)
    css_request = TestServer.wait_for_request(server, "/one-style.css")
    promise = Frame.wait_for_navigation(frame)
    Page.eval_on_selector!(page, "iframe", "frame => { frame.contentWindow.location.href = '/one-style.html'; }")
    # Make sure policy checks pass and navigation actually begins before removing the frame to avoid other errors
    Task.await(css_request, :infinity)
    Page.eval_on_selector!(page, "iframe", "frame => window.builtins.setTimeout(() => frame.remove(), 0)")
    {:error, error} = Promise.await(promise)
    assert Exception.message(error) =~ ~s(waiting for navigation until "load")
    assert Exception.message(error) =~ "frame was detached"
  end
end
