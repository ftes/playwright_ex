defmodule PlaywrightEx.Page.PageEventLoadTest do
  @upstream "tests/page/page-event-load.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp load_count do
    receive do
      :load -> 1 + load_count()
    after
      0 -> 0
    end
  end

  test "should fire once", %{page: page, server: server, browser_name: browser_name} do
    # it.fixme(browserName === 'firefox' && !isBidi, 'Firefox sometimes double fires.');
    if browser_name != "firefox" do
      test = self()
      Page.on(page, :load, fn _ -> send(test, :load) end)
      Page.goto!(page, server.prefix <> "/one-style.html")
      Page.wait_for_timeout!(page, 1000)
      assert load_count() == 1
    end
  end

  test "should fire once with iframe navigation", %{page: page, server: server, browser_name: browser_name} do
    # it.fixme(browserName === 'firefox' && !isBidi, 'Firefox sometimes double fires.');
    if browser_name != "firefox" do
      test = self()
      request_count = :counters.new(1, [])

      TestServer.set_route(server, "/tracker", fn conn ->
        :counters.add(request_count, 1, 1)
        Plug.Conn.send_resp(conn, 200, "request count: #{:counters.get(request_count, 1)}")
      end)

      TestServer.set_route(server, "/home", fn conn ->
        Plug.Conn.send_resp(conn, 200, """
          <!DOCTYPE html>
          <html>
            <head>
            </head>
            <body>
              <script>
                window.eventLog = [];
                window.addEventListener('load', () => {
                  window.eventLog.push('load');
                });
              </script>
              <form id="trackerForm" action="/tracker" method="post" target="tracker">
                <input type="submit">
              </form>
              <iframe name="tracker" src="/tracker">
            </body>
          </html>
        """)
      end)

      Page.on(page, :load, fn _ -> send(test, :load) end)
      Page.goto!(page, server.prefix <> "/home")
      tracking_frame = Page.frame_locator(page, "[name=tracker]")
      Expect.to_contain_text!(FrameLocator.locator(tracking_frame, ":scope"), "request count: 1")
      # Promise.race([waitForEvent('load') -> 'loadfired', waitForTimeout(1000) -> 'timeout']): the
      # waitForEvent timeout plays the waitForTimeout part.
      load_fired = Page.wait_for_event(page, :load, timeout: 1000)
      Locator.click!(Page.locator(page, "input[type=submit]"))
      assert {:error, _timeout} = Promise.await(load_fired)
      assert load_count() == 1
      assert Page.evaluate!(page, "() => window['eventLog']") == ["load"]
    end
  end
end
