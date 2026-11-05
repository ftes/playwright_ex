defmodule PlaywrightEx.Page.PageAutowaitingBasicTest do
  @upstream "tests/page/page-autowaiting-basic.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.TestServer

  @moduletag :page

  # `messages.push(m)` is `send(test, {:message, m})`; `messages/0` joins them with "|".
  defp init_server(server) do
    test = self()

    TestServer.set_route(server, "/empty.html", fn conn ->
      send(test, {:message, "route"})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<link rel='stylesheet' href='./one-style.css'>")
    end)
  end

  defp messages(acc \\ []) do
    receive do
      {:message, message} -> messages([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("|")
    end
  end

  defp hang(_conn), do: Process.sleep(:infinity)

  # Promise.all([page.click(selector).then(() => messages.push('click')),
  #              page.waitForEvent('framenavigated').then(() => messages.push('navigated'))])
  # Test port: JS runs the `.then` push as a microtask of the event, before the click reply. Two
  # tasks that push after their awaits race each other, so the push runs in a `once` listener
  # (the connection waits for it before dispatching the click reply); the wait still awaits the
  # event, as `Promise.all` does.
  defp click_and_wait_for_navigated(page, selector) do
    test = self()
    Page.once(page, :frame_navigated, fn _ -> send(test, {:message, "navigated"}) end)
    navigated = Page.wait_for_event(page, :frame_navigated)
    Page.click!(page, selector)
    send(test, {:message, "click"})
    Promise.await!(navigated)
  end

  test "should await navigation when clicking anchor", %{page: page, server: server} do
    init_server(server)
    Page.set_content!(page, ~s(<a id="anchor" href="#{server.empty_page}">empty.html</a>))
    click_and_wait_for_navigated(page, "a")
    assert messages() == "route|navigated|click"
  end

  test "should not stall on JS navigation link", %{page: page} do
    Page.set_content!(page, ~s[<a href="javascript:console.log(1)">console.log</a>])
    Page.click!(page, "a")
  end

  test "should await cross-process navigation when clicking anchor", %{page: page, server: server} do
    init_server(server)
    Page.set_content!(page, ~s(<a href="#{server.cross_process_prefix <> "/empty.html"}">empty.html</a>))

    click_and_wait_for_navigated(page, "a")
    assert messages() == "route|navigated|click"
  end

  test "should await form-get on click", %{page: page, server: server} do
    test = self()

    TestServer.set_route(server, "/empty.html?foo=bar", fn conn ->
      send(test, {:message, "route"})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<link rel='stylesheet' href='./one-style.css'>")
    end)

    Page.set_content!(page, """
      <form action="#{server.empty_page}" method="get">
        <input name="foo" value="bar">
        <input type="submit" value="Submit">
      </form>
    """)

    click_and_wait_for_navigated(page, "input[type=submit]")
    assert messages() == "route|navigated|click"
  end

  test "should await form-post on click", %{page: page, server: server} do
    init_server(server)

    Page.set_content!(page, """
      <form action="#{server.empty_page}" method="post">
        <input name="foo" value="bar">
        <input type="submit" value="Submit">
      </form>
    """)

    click_and_wait_for_navigated(page, "input[type=submit]")
    assert messages() == "route|navigated|click"
  end

  test "should work with noWaitAfter: true", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", &hang/1)
    Page.set_content!(page, ~s(<a id="anchor" href="#{server.empty_page}">empty.html</a>))
    Page.click!(page, "a", no_wait_after: true)
  end

  test "should work with dblclick without noWaitAfter when navigation is stalled", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", &hang/1)
    Page.set_content!(page, ~s(<a id="anchor" href="#{server.empty_page}">empty.html</a>))
    Page.dblclick!(page, "a")
  end

  # Promise.all([page.click('a').then(() => page.waitForLoadState('load')).then(() => messages.push('clickload')),
  #              page.waitForEvent('load').then(() => messages.push('load'))])
  # Test port: as in `click_and_wait_for_navigated/2`, the 'load' push runs in a `once` listener
  # (which also stands for the waitForEvent, as in playwright-python). JS runs it as a microtask
  # of the event that resolves waitForLoadState, before the 'clickload' continuation; here it runs
  # in its own process, so `removeAllListeners` with `behavior: 'wait'` (the fired `once` left no
  # listener to remove) awaits it before 'clickload' is pushed.
  test "should work with waitForLoadState(load)", %{page: page, server: server} do
    init_server(server)
    Page.set_content!(page, ~s(<a id="anchor" href="#{server.empty_page}">empty.html</a>))
    test = self()
    Page.once(page, :load, fn _ -> send(test, {:message, "load"}) end)
    Page.click!(page, "a")
    Page.wait_for_load_state!(page, "load")
    Page.remove_all_listeners!(page, :load, behavior: :wait)
    send(test, {:message, "clickload"})
    assert messages() == "route|load|clickload"
  end

  test "should work with goto following click", %{page: page, server: server} do
    TestServer.set_route(server, "/login.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "You are logged in")
    end)

    Page.set_content!(page, """
      <form action="#{server.prefix}/login.html" method="get">
        <input type="text">
        <input type="submit" value="Submit">
      </form>
    """)

    Page.fill!(page, "input[type=text]", "admin")
    Page.click!(page, "input[type=submit]")
    Page.goto!(page, server.empty_page)
  end

  test "should report navigation in the log when clicking anchor"

  test "should report and collapse log in action", %{page: page} do
    Page.set_content!(page, ~s(<input id='checkbox' type='checkbox' style="visibility: hidden"></input>))
    {:error, error} = Locator.click(Page.locator(page, "input"), timeout: 5000)
    message = Exception.message(error)
    assert message =~ "Call log:"
    assert message =~ ~r/\d+ × waiting for/
    {index, _} = :binary.match(message, "Call log:")
    log_lines = message |> binary_part(index, byte_size(message) - index) |> String.split("\n")
    assert length(log_lines) < 30
  end

  test "should report and collapse log in expect", %{page: page} do
    Page.set_content!(page, ~s(<input id='checkbox' type='checkbox' style="visibility: hidden"></input>))
    {:error, error} = Expect.to_be_visible(Page.locator(page, "input"), timeout: 5000)
    message = Exception.message(error)
    assert message =~ "Call log:"
    assert message =~ ~r/\d+ × locator resolved to/
  end
end
