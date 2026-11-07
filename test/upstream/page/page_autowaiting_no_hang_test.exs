defmodule PlaywrightEx.Page.PageAutowaitingNoHangTest do
  @upstream "tests/page/page-autowaiting-no-hang.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp hang(_conn), do: Process.sleep(:infinity)

  # The route handler calls `stallCallback()` (`{:stall, release}` to the test), then awaits
  # `abortPromise` (`release.()` resolves it, for later requests too: the browser may retry).
  defp stall_route(server, test, then_fn) do
    {:ok, released} = Agent.start_link(fn -> {false, []} end)

    release = fn ->
      Agent.update(released, fn {_, waiting} ->
        Enum.each(waiting, &send(&1, :release))
        {true, []}
      end)
    end

    TestServer.set_route(server, "/stall.html", fn conn ->
      send(test, {:stall, release})
      me = self()

      already =
        Agent.get_and_update(released, fn {done, waiting} ->
          {done, {done, if(done, do: waiting, else: [me | waiting])}}
        end)

      if !already do
        receive do
          :release -> :ok
        end
      end

      then_fn.(conn)
    end)
  end

  test "AW-013 clicking on links which do not commit navigation", %{
    page: page,
    server: server,
    https_server: https_server
  } do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<a href='#{https_server.empty_page}'>foobar</a>")
    Page.click!(page, "a")
  end

  test "AW-014 calling window.stop async", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", &hang/1)

    Page.evaluate!(
      page,
      """
      url => {
        window.location.href = url;
        setTimeout(() => window.stop(), 100);
      }
      """,
      server.empty_page
    )
  end

  test "AW-015 calling window.stop sync", %{page: page, server: server} do
    Page.evaluate!(
      page,
      """
      url => {
        window.location.href = url;
        window.stop();
      }
      """,
      server.empty_page
    )
  end

  test "AW-016 assigning location to about:blank", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, ~s|window.location.href = "about:blank";|)
  end

  test "AW-017 assigning location to about:blank after non-about:blank", %{page: page, server: server} do
    TestServer.set_route(server, "/empty.html", &hang/1)

    Page.evaluate!(page, """
        window.location.href = "#{server.empty_page}";
        window.location.href = "about:blank";
    """)
  end

  test "AW-018 calling window.open and window.close", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      const popup = window.open(window.location.href);
      popup.close();
    }
    """)
  end

  test "AW-019 opening a popup", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window.open(window.location.href) && 1") end)
  end

  test "AW-020 clicking in the middle of navigation that aborts", %{page: page, server: server} do
    # req.socket.destroy(): kill the connection's handler process.
    stall_route(server, self(), fn _conn -> Process.exit(self(), :kill) end)

    Page.goto!(page, server.prefix <> "/one-style.html")
    Runtime.Promise.void(fn -> Page.goto(page, server.prefix <> "/stall.html") end)
    assert_receive {:stall, release}, 5000

    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "body") end)
    Page.wait_for_timeout!(page, 1000)
    release.()

    Runtime.Promise.await(click_promise)
  end

  test "AW-021 clicking in the middle of navigation that commits", %{page: page, server: server} do
    stall_route(server, self(), fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "hello world")
    end)

    Page.goto!(page, server.prefix <> "/one-style.html")
    Runtime.Promise.void(fn -> Page.goto(page, server.prefix <> "/stall.html") end)
    assert_receive {:stall, release}, 5000

    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "body") end)
    Page.wait_for_timeout!(page, 1000)
    release.()

    Runtime.Promise.await(click_promise)
    Expect.to_contain_text!(Page.locator(page, "body"), "hello world")
  end

  test "AW-022 clicking a link intercepted by the Navigation API same-document", %{page: page, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/41125' }
    TestServer.set_route(server, "/intercept.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
        <a id="go" href="/other">go</a>
        <p id="status">initial</p>
        <script>
          navigation.addEventListener('navigate', event => {
            if (!event.canIntercept)
              return;
            event.intercept({
              handler: async () => {
                const dest = new URL(event.destination.url).pathname;
                document.getElementById('status').textContent = 'intercepted:' + dest;
              },
            });
          });
        </script>
      """)
    end)

    Page.goto!(page, server.prefix <> "/intercept.html")
    Expect.to_have_text!(Page.locator(page, "#status"), "initial")

    # Should not hang waiting for the same-document navigation to commit.
    Locator.click!(Page.locator(page, "#go"))

    Expect.to_have_text!(Page.locator(page, "#status"), "intercepted:/other")
    assert URI.parse(Page.url(page)).path == "/other"
  end

  test "AW-023 goBack in the middle of navigation that commits", %{page: page, server: server} do
    stall_route(server, self(), fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "hello world")
    end)

    Page.goto!(page, server.prefix <> "/one-style.html")
    Runtime.Promise.void(fn -> Page.goto(page, server.prefix <> "/stall.html") end)
    assert_receive {:stall, release}, 5000

    go_back_promise = Runtime.Promise.async(fn -> Page.go_back(page) end)
    Page.wait_for_timeout!(page, 1000)
    release.()

    Runtime.Promise.await(go_back_promise)
  end
end
