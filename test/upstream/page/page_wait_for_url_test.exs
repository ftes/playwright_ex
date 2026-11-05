defmodule PlaywrightEx.Page.PageWaitForUrlTest do
  @upstream "tests/page/page-wait-for-url.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  test "should work", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "url => window.location.href = url", server.prefix <> "/grid.html")
    Page.wait_for_url!(page, "**/grid.html")
  end

  test "should respect timeout", %{page: page, server: server} do
    promise = Task.async(fn -> Page.wait_for_url(page, "**/frame.html", timeout: 2500) end)
    Page.goto!(page, server.empty_page)
    {:error, error} = Task.await(promise, :infinity)
    assert Exception.message(error) =~ "page.waitForURL: Timeout 2500ms exceeded."
  end

  test "should work with both domcontentloaded and load", %{page: page, server: server} do
    test = self()

    TestServer.set_route(server, "/one-style.css", fn conn ->
      send(test, {:response, self()})

      receive do
        :end -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    css_request = TestServer.wait_for_request(server, "/one-style.css")
    navigation_promise = Task.async(fn -> Page.goto!(page, server.prefix <> "/one-style.html") end)

    dom_content_loaded_promise =
      Task.async(fn -> Page.wait_for_url!(page, "**/one-style.html", wait_until: :domcontentloaded) end)

    # `bothFired`: the load wait is still pending once domcontentloaded has fired.
    load_promise = Task.async(fn -> Page.wait_for_url!(page, "**/one-style.html", wait_until: :load) end)

    Task.await(css_request, :infinity)
    assert_receive {:response, response}
    Task.await(dom_content_loaded_promise, :infinity)
    assert Task.yield(load_promise, 0) == nil
    send(response, :end)
    Task.await(load_promise, :infinity)
    Task.await(navigation_promise, :infinity)
  end

  test "should work with commit", %{page: page, server: server} do
    TestServer.set_route(server, "/script.js", fn _conn -> Process.sleep(:infinity) end)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s(<title>Hello</title><script src="script.js"></script>))
    end)

    Task.start(fn -> Page.goto(page, server.empty_page) end)
    Page.wait_for_url!(page, "**/empty.html", wait_until: :commit)
    assert Page.title!(page) == "Hello"
  end

  test "should work with commit and about:blank", %{page: page} do
    Page.wait_for_url!(page, "about:blank", wait_until: :commit)
  end

  test "should work with clicking on anchor links", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<a href='#foobar'>foobar</a>")
    Page.click!(page, "a")
    Page.wait_for_url!(page, "**/*#foobar")
  end

  test "should work with history.pushState()", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <a onclick='javascript:pushState()'>SPA</a>
      <script>
        function pushState() { history.pushState({}, '', 'wow.html') }
      </script>
    """)

    Page.click!(page, "a")
    Page.wait_for_url!(page, "**/wow.html")
    assert Page.url(page) == server.prefix <> "/wow.html"
  end

  test "should work with history.replaceState()", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <a onclick='javascript:replaceState()'>SPA</a>
      <script>
        function replaceState() { history.replaceState({}, '', '/replaced.html') }
      </script>
    """)

    Page.click!(page, "a")
    Page.wait_for_url!(page, "**/replaced.html")
    assert Page.url(page) == server.prefix <> "/replaced.html"
  end

  test "should work with DOM history.back()/history.forward()", %{page: page, server: server} do
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

    Page.click!(page, "a#back")
    Page.wait_for_url!(page, "**/first.html")
    assert Page.url(page) == server.prefix <> "/first.html"

    Page.click!(page, "a#forward")
    Page.wait_for_url!(page, "**/second.html")
    assert Page.url(page) == server.prefix <> "/second.html"
  end

  test "should work with url match for same document navigations", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    wait_promise = Task.async(fn -> Page.wait_for_url!(page, ~r/third\.html/) end)
    assert Task.yield(wait_promise, 0) == nil
    Page.evaluate!(page, "() => { history.pushState({}, '', '/first.html'); }")
    assert Task.yield(wait_promise, 0) == nil
    Page.evaluate!(page, "() => { history.pushState({}, '', '/second.html'); }")
    assert Task.yield(wait_promise, 0) == nil
    Page.evaluate!(page, "() => { history.pushState({}, '', '/third.html'); }")
    assert Task.await(wait_promise, :infinity) == :ok
  end

  test "should work on frame", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    frame = Enum.at(Page.frames(page), 1)
    Frame.evaluate!(frame, "url => window.location.href = url", server.prefix <> "/grid.html")
    Frame.wait_for_url!(frame, "**/grid.html")
  end
end
