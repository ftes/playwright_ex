defmodule PlaywrightEx.Page.PageHistoryTest do
  @upstream "tests/page/page-history.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Response
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  import PlaywrightEx.Utils, only: [to_pass: 1]

  @moduletag :page

  defp hang(_conn), do: Process.sleep(:infinity)

  defp html(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8")
    |> Plug.Conn.send_resp(200, body)
  end

  defp console_text(page, text), do: Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == text))

  defp file_url(path), do: "file://" <> path

  test "NA-071 page.goBack should work @smoke", %{page: page, server: server} do
    assert Page.go_back!(page) == nil

    Page.goto!(page, server.empty_page)
    Page.goto!(page, server.prefix <> "/grid.html")

    response = Page.go_back!(page)
    assert Response.ok(response) == true
    assert Response.url(response) =~ server.empty_page

    response = Page.go_forward!(page)
    assert Response.ok(response) == true
    assert Response.url(response) =~ "/grid.html"

    response = Page.go_forward!(page)
    assert response == nil
  end

  test "NA-072 page.goBack should work with HistoryAPI", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      history.pushState({}, '', '/first.html');
      history.pushState({}, '', '/second.html');
    }
    """)

    assert Page.url(page) == server.prefix <> "/second.html"

    Page.go_back!(page)
    assert Page.url(page) == server.prefix <> "/first.html"
    Page.go_back!(page)
    assert Page.url(page) == server.empty_page
    Page.go_forward!(page)
    assert Page.url(page) == server.prefix <> "/first.html"
  end

  test "NA-073 page.goBack should work for file urls", %{page: page, server: server, asset: asset} do
    url1 = file_url(asset.("consolelog.html"))
    url2 = server.prefix <> "/consolelog.html"
    message = console_text(page, "here:" <> url1)
    Page.goto!(page, url1)
    Promise.await!(message)
    Page.set_content!(page, "<a href='#{url2}'>url2</a>")
    assert String.downcase(Page.url(page)) == String.downcase(url1)

    message = console_text(page, "here:" <> url2)
    Page.click!(page, "a")
    Promise.await!(message)
    assert Page.url(page) == url2

    message = console_text(page, "here:" <> url1)
    Page.go_back!(page)
    Promise.await!(message)
    assert String.downcase(Page.url(page)) == String.downcase(url1)
    # Should be able to evaluate in the new context, and
    # not reach for the old cross-process one.
    assert Page.evaluate!(page, "() => window.scrollX") == 0
    # Should be able to screenshot.
    Page.screenshot!(page)

    message = console_text(page, "here:" <> url2)
    Page.go_forward!(page)
    Promise.await!(message)
    assert Page.url(page) == url2
    assert Page.evaluate!(page, "() => window.scrollX") == 0
    Page.screenshot!(page)
  end

  test "NA-074 goBack/goForward should work with bfcache-able pages", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/cached/bfcached.html")
    Page.set_content!(page, "<a href=#{JSON.encode!(server.prefix <> "/cached/bfcached.html?foo")}>click me</a>")
    Page.click!(page, "a")

    response = Page.go_back!(page)
    assert Response.url(response) == server.prefix <> "/cached/bfcached.html"
    # BFCache should be disabled.
    assert Page.evaluate!(page, "window.didShow") == %{"persisted" => false}

    response = Page.go_forward!(page)
    assert Response.url(response) == server.prefix <> "/cached/bfcached.html?foo"
  end

  test "NA-075 page.reload should work", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => window['_foo'] = 10")
    Page.reload!(page)
    assert Page.evaluate!(page, "() => window['_foo']") == nil
  end

  test "NA-076 page.reload should work with data url", %{page: page} do
    Page.goto!(page, "data:text/html,hello")
    assert Page.content!(page) =~ "hello"
    assert Page.reload!(page) == nil
    assert Page.content!(page) =~ "hello"
  end

  # `page.once('request', async () => { await <navigate>().catch(e => {}); callback(); })`,
  # then `page.click('input[type=submit]').catch(e => {})` and await both.
  defp navigate_during_renderer_initiated_navigation(page, navigate) do
    test = self()

    Page.once(page, :request, fn _request ->
      navigate.()
      send(test, :navigate_failed)
    end)

    click_promise = Runtime.Promise.async(fn -> Page.click(page, "input[type=submit]") end)
    assert_receive :navigate_failed, 30_000
    Runtime.Promise.await(click_promise)
  end

  test "NA-077 page.reload during renderer-initiated navigation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/one-style.html")
    Page.set_content!(page, "<form method='POST' action='/post'>Form is here<input type='submit'></form>")
    TestServer.set_route(server, "/post", &hang/1)

    navigate_during_renderer_initiated_navigation(page, fn -> Page.reload(page) end)

    # Form submit should be canceled, and reload should eventually arrive
    # to the original one-style.html.
    Page.wait_for_selector!(page, "text=hello")
  end

  test "NA-078 page.reload should not resolve with same-document navigation", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    # 1. Make sure execution contexts are ready for fast evaluate.
    Page.evaluate!(page, "1")

    # 2. Stall the reload request.
    test = self()

    TestServer.set_route(server, "/empty.html", fn conn ->
      send(test, {:response, self()})

      receive do
        {:end, body} -> Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    request_promise = TestServer.wait_for_request(server, "/empty.html")

    # 3. Trigger push state that could resolve the reload.
    # deviation: not awaited, as upstream (`.catch(() => {})`): the evaluate after the reload is
    # answered only once the reload commits, which the stalled request holds. `Runtime.Promise`
    # returns once each call is sent, so the three are sent in upstream's order.
    Runtime.Promise.void(fn -> Page.evaluate(page, "() => { window.history.pushState({}, ''); }") end)

    # 4. Trigger the reload, it should not resolve.
    reload_promise = Runtime.Promise.async(fn -> Page.reload!(page) end)

    # 5. Trigger push state again, for the good measure :)
    Runtime.Promise.void(fn -> Page.evaluate(page, "() => { window.history.pushState({}, ''); }") end)

    # 5. Serve the request, it should resolve the reload.
    Task.await(request_promise, :infinity)
    assert_receive {:response, response}
    send(response, {:end, "hello"})

    # 6. Check the reload response.
    got_response = Runtime.Promise.await(reload_promise)
    assert Response.text!(got_response) == "hello"
  end

  test "NA-079 page.reload should work with same origin redirect", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/16147' });
    Page.goto!(page, server.empty_page)
    TestServer.set_redirect(server, "/empty.html", server.prefix <> "/title.html")
    Page.reload!(page)
    Expect.to_have_url!(page, server.prefix <> "/title.html")
  end

  test "NA-080 page.reload should work with cross-origin redirect", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/16147' });
    Page.goto!(page, server.empty_page)
    TestServer.set_redirect(server, "/empty.html", server.cross_process_prefix <> "/title.html")
    Page.reload!(page)
    Expect.to_have_url!(page, server.cross_process_prefix <> "/title.html")
  end

  test "NA-081 page.reload should work on a page with a hash", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/21145' });
    Page.goto!(page, server.empty_page <> "#hash")
    Page.reload!(page)
    Expect.to_have_url!(page, server.empty_page <> "#hash")
  end

  test "NA-082 page.reload should work on a page with a hash at the end", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/21430' });
    Page.goto!(page, server.empty_page <> "#")
    Page.reload!(page)
    Expect.to_have_url!(page, server.empty_page <> "#")
  end

  test "NA-083 page.goBack during renderer-initiated navigation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/one-style.html")
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<form method='POST' action='/post'>Form is here<input type='submit'></form>")
    TestServer.set_route(server, "/post", &hang/1)

    navigate_during_renderer_initiated_navigation(page, fn -> Page.go_back(page) end)

    # Form submit should be canceled, and goBack should eventually arrive
    # to the original one-style.html.
    Page.wait_for_selector!(page, "text=hello")
  end

  test "NA-084 page.goForward during renderer-initiated navigation", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.goto!(page, server.prefix <> "/one-style.html")
    Page.go_back!(page)

    Page.set_content!(page, "<form method='POST' action='/post'>Form is here<input type='submit'></form>")
    TestServer.set_route(server, "/post", &hang/1)

    navigate_during_renderer_initiated_navigation(page, fn -> Page.go_forward(page) end)

    # Form submit should be canceled, and goForward should eventually arrive
    # to the original one-style.html.
    Page.wait_for_selector!(page, "text=hello")
  end

  test "NA-085 regression test for issue 20791", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/20791' });
    # it.skip(process.env.PW_CLOCK === 'frozen');
    TestServer.set_route(server, "/iframe.html", fn conn ->
      # iframe access parent frame to log a value from it.
      html(conn, """
        <!doctype html>
        <script type="text/javascript">
          console.log(window.parent.foo);
        </script>
      """)
    end)

    TestServer.set_route(server, "/main.html", fn conn ->
      html(conn, """
        <!doctype html>
        <iframe id=myframe src="about:blank"></iframe>
        <script type="text/javascript">
          setTimeout(() => window.foo = 'foo', 0);
          setTimeout(() => myframe.contentDocument.location.href = '#{server.prefix}/iframe.html', 0);
        </script>
      """)
    end)

    {:ok, messages} = Agent.start_link(fn -> [] end)
    Page.on(page, :console, fn msg -> Agent.update(messages, &(&1 ++ [ConsoleMessage.text(msg)])) end)
    Page.goto!(page, server.prefix <> "/main.html")
    to_pass(fn -> assert Agent.get(messages, & &1) == ["foo"] end)
    Page.reload!(page)
    to_pass(fn -> assert Agent.get(messages, & &1) == ["foo", "foo"] end)
  end

  test "NA-086 should reload proper page", %{page: page, server: server} do
    counter = :counters.new(2, [])

    TestServer.set_route(server, "/main.html", fn conn ->
      :counters.add(counter, 1, 1)
      html(conn, "<!doctype html><h1>main: #{:counters.get(counter, 1)}</h1>")
    end)

    TestServer.set_route(server, "/popup.html", fn conn ->
      :counters.add(counter, 2, 1)
      html(conn, "<!doctype html><h1>popup: #{:counters.get(counter, 2)}</h1>")
    end)

    Page.goto!(page, server.prefix <> "/main.html")
    popup = Page.wait_for_event(page, :popup)
    Page.evaluate!(page, "() => window.open('/popup.html')")
    popup = Promise.await!(popup)
    Expect.to_have_text!(Page.locator(page, "h1"), "main: 1")
    Expect.to_have_text!(Page.locator(popup, "h1"), "popup: 1")

    Page.reload!(page)
    Expect.to_have_text!(Page.locator(page, "h1"), "main: 2")
    Expect.to_have_text!(Page.locator(popup, "h1"), "popup: 1")

    Page.reload!(popup)
    Expect.to_have_text!(Page.locator(page, "h1"), "main: 2")
    Expect.to_have_text!(Page.locator(popup, "h1"), "popup: 2")
  end
end
