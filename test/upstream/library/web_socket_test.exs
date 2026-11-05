defmodule PlaywrightEx.Library.WebSocketTest do
  @upstream "tests/library/web-socket.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.WebSocket

  @moduletag :page

  # `const log = []; ... log.push(x)`: the listeners send to the test process.
  defp log(acc \\ []) do
    receive do
      {:log, x} -> log([x | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # `page.waitForEvent('websocket').then(ws => ws.waitForEvent('framereceived'))`: a `once`
  # listener starts the frame wait as soon as the socket is announced, as `.then` does.
  defp wait_for_web_socket_frame_received(page) do
    me = self()
    Page.once(page, :web_socket, fn ws -> send(me, {:ws, ws, WebSocket.wait_for_event(ws, :frame_received)}) end)

    fn ->
      assert_receive {:ws, ws, frame_received}, 5000
      Promise.await!(frame_received)
      ws
    end
  end

  test "should work @smoke", %{page: page, server: server} do
    TestServer.send_on_web_socket_connection(server, "incoming")

    value =
      Page.evaluate!(
        page,
        """
        host => {
          let cb;
          const result = new Promise(f => cb = f);
          const ws = new WebSocket('ws://' + host + '/ws');
          ws.addEventListener('message', data => { ws.close(); cb(data.data); });
          return result;
        }
        """,
        server.host
      )

    assert value == "incoming"
  end

  test "should emit close events", %{page: page, server: server} do
    me = self()

    Page.on(page, :web_socket, fn ws ->
      send(me, {:log, "open<#{WebSocket.url(ws)}>"})
      send(me, {:web_socket, ws})

      WebSocket.on(ws, :close, fn _ ->
        send(me, {:log, "close"})
        send(me, :socket_closed)
      end)
    end)

    Page.evaluate!(
      page,
      """
      host => {
        const ws = new WebSocket('ws://' + host + '/ws');
        ws.addEventListener('open', () => ws.close());
      }
      """,
      server.host
    )

    assert_receive :socket_closed, 5000
    assert Enum.join(log(), ":") == "open<ws://#{server.host}/ws>:close"
    assert_received {:web_socket, web_socket}
    assert WebSocket.is_closed(web_socket)
  end

  test "should emit frame events", %{page: page, server: server} do
    TestServer.once_web_socket_connection(server, fn ws ->
      TestServer.WebSocket.on(ws, :message, fn -> TestServer.WebSocket.send(ws, "incoming") end)
    end)

    me = self()

    Page.on(page, :web_socket, fn ws ->
      send(me, {:log, "open"})
      WebSocket.on(ws, :frame_sent, fn d -> send(me, {:log, "sent<" <> d.payload <> ">"}) end)
      WebSocket.on(ws, :frame_received, fn d -> send(me, {:log, "received<" <> d.payload <> ">"}) end)

      WebSocket.on(ws, :close, fn _ ->
        send(me, {:log, "close"})
        send(me, :socket_closed)
      end)
    end)

    Page.evaluate!(
      page,
      """
      host => {
        const ws = new WebSocket('ws://' + host + '/ws');
        ws.addEventListener('open', () => ws.send('outgoing'));
        ws.addEventListener('message', () => { ws.close(); });
        window.ws = ws;
      }
      """,
      server.host
    )

    assert_receive :socket_closed, 5000
    assert log() == ["open", "sent<outgoing>", "received<incoming>", "close"]
  end

  test "should filter out the close events when the server closes with a message", %{page: page, server: server} do
    TestServer.once_web_socket_connection(server, fn ws ->
      TestServer.WebSocket.send(ws, "incoming")

      TestServer.WebSocket.on(ws, :message, fn ->
        TestServer.WebSocket.close(ws, 1003, "closed by Playwright test-server")
      end)
    end)

    me = self()

    Page.on(page, :web_socket, fn ws ->
      send(me, {:log, "open"})
      WebSocket.on(ws, :frame_sent, fn d -> send(me, {:log, "sent<" <> d.payload <> ">"}) end)
      WebSocket.on(ws, :frame_received, fn d -> send(me, {:log, "received<" <> d.payload <> ">"}) end)

      WebSocket.on(ws, :close, fn _ ->
        send(me, {:log, "close"})
        send(me, :socket_closed)
      end)
    end)

    Page.evaluate!(
      page,
      """
      host => {
        const ws = new WebSocket('ws://' + host + '/ws');
        ws.addEventListener('message', () => ws.send('outgoing'));
        window.ws = ws;
      }
      """,
      server.host
    )

    assert_receive :socket_closed, 5000
    assert log() == ["open", "received<incoming>", "sent<outgoing>", "close"]
  end

  test "should pass self as argument to close event", %{page: page, server: server} do
    me = self()

    Page.on(page, :web_socket, fn ws ->
      send(me, {:web_socket, ws})
      WebSocket.on(ws, :close, fn event_arg -> send(me, {:socket_closed, event_arg}) end)
    end)

    Page.evaluate!(
      page,
      """
      host => {
        const ws = new WebSocket('ws://' + host + '/ws');
        ws.addEventListener('open', () => ws.close());
      }
      """,
      server.host
    )

    assert_receive {:socket_closed, event_arg}, 5000
    assert_received {:web_socket, web_socket}
    assert event_arg == web_socket
  end

  test "should emit binary frame events", %{page: page, server: server} do
    me = self()

    Page.on(page, :web_socket, fn ws ->
      WebSocket.on(ws, :close, fn _ -> send(me, :done) end)
      WebSocket.on(ws, :frame_sent, fn d -> send(me, {:log, d.payload}) end)
    end)

    Page.evaluate!(
      page,
      """
      host => {
        const ws = new WebSocket('ws://' + host + '/ws');
        ws.addEventListener('open', () => {
          const binary = new Uint8Array(5);
          for (let i = 0; i < 5; ++i)
            binary[i] = i;
          ws.send('text');
          ws.send(binary);
          ws.close();
        });
      }
      """,
      server.host
    )

    assert_receive :done, 5000
    sent = log()
    assert Enum.at(sent, 0) == "text"
    # A JS Buffer payload is `{:binary, bytes}`.
    {:binary, bytes} = Enum.at(sent, 1)
    for i <- 0..4, do: assert(:binary.at(bytes, i) == i)
  end

  test "should emit error", %{page: page, server: server} do
    me = self()
    Page.on(page, :web_socket, fn ws -> WebSocket.on(ws, :socket_error, &send(me, {:socket_error, &1})) end)

    Page.evaluate!(
      page,
      """
      host => {
        new WebSocket('ws://' + host + '/bogus-ws');
      }
      """,
      server.host
    )

    assert_receive {:socket_error, message}, 5000
    # channel?.includes('msedge') ? '' : ': 400'
    assert message =~ ": 400"
  end

  test "should not have stray error events", %{page: page, server: server} do
    TestServer.send_on_web_socket_connection(server, "incoming")
    me = self()
    Page.on(page, :web_socket, fn ws -> WebSocket.on(ws, :socket_error, &send(me, {:error, &1})) end)
    ws = wait_for_web_socket_frame_received(page)

    Page.evaluate!(
      page,
      """
      host => {
        window.ws = new WebSocket('ws://' + host + '/ws');
      }
      """,
      server.host
    )

    ws.()
    Page.evaluate!(page, "window.ws.close()")
    refute_received {:error, _}
  end

  test "should reject waitForEvent on socket close", %{page: page, server: server} do
    TestServer.send_on_web_socket_connection(server, "incoming")
    ws = wait_for_web_socket_frame_received(page)

    Page.evaluate!(
      page,
      """
      host => {
        window.ws = new WebSocket('ws://' + host + '/ws');
      }
      """,
      server.host
    )

    ws = ws.()
    error = WebSocket.wait_for_event(ws, :frame_sent)
    Page.evaluate!(page, "window.ws.close()")
    {:error, error} = Promise.await(error)
    assert Exception.message(error) =~ "Socket closed"
  end

  test "should reject waitForEvent on page close", %{page: page, server: server} do
    TestServer.send_on_web_socket_connection(server, "incoming")
    ws = wait_for_web_socket_frame_received(page)

    Page.evaluate!(
      page,
      """
      host => {
        window.ws = new WebSocket('ws://' + host + '/ws');
      }
      """,
      server.host
    )

    ws = ws.()
    error = WebSocket.wait_for_event(ws, :frame_sent)
    Page.close!(page)
    {:error, error} = Promise.await(error)
    # kTargetClosedErrorMessage
    assert Exception.message(error) =~ "Target page, context or browser has been closed"
  end

  test "should not tear down the page when a WebSocket is opened inside a worker", %{page: page, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/41742' }
    TestServer.send_on_web_socket_connection(server, "incoming")
    Page.goto!(page, server.empty_page)

    received =
      Page.evaluate!(
        page,
        """
        host => {
          const code = `
            const ws = new WebSocket(${JSON.stringify('ws://' + host + '/ws')});
            ws.addEventListener('message', event => self.postMessage(event.data));
          `;
          const worker = new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
          return new Promise(resolve => worker.addEventListener('message', event => resolve(event.data)));
        }
        """,
        server.host
      )

    assert received == "incoming"
    # Opening a `WebSocket` inside a worker must not tear down the page session.
    assert Page.evaluate!(page, "() => 1 + 1") == 2
  end

  @tag skip: "upstream fixme: it.fixme() (no reason given)"
  test "should turn off when offline"

  @tag skip:
         if(@browser_name == "chromium" and @browser_major_version < 151,
           do: "upstream fixme: Chromium before 151 does not send extra HTTP headers on WebSocket handshake"
         )
  test "should send extra HTTP headers on WebSocket handshake", %{
    page: page,
    server: server
  } do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/28948' }
    Page.set_extra_http_headers!(page, %{foo: "bar"})
    Page.goto!(page, server.empty_page)
    req_promise = TestServer.wait_for_web_socket_connection_request(server)
    Page.evaluate!(page, "host => { new WebSocket(`ws://${host}/ws`); }", server.host)
    req = Task.await(req_promise, :infinity)
    assert Plug.Conn.get_req_header(req, "foo") == ["bar"]
  end

  @tag skip:
         if(@browser_name == "chromium" and @browser_major_version < 151,
           do: "upstream fixme: Chromium before 151 does not send extra HTTP headers on WebSocket handshake"
         )
  test "should send extra HTTP headers on WebSocket handshake from a worker", %{
    page: page,
    server: server
  } do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/28948' }
    Page.set_extra_http_headers!(page, %{foo: "bar"})
    Page.goto!(page, server.empty_page)
    req_promise = TestServer.wait_for_web_socket_connection_request(server)

    Page.evaluate!(
      page,
      """
      host => {
        const code = `new WebSocket(${JSON.stringify('ws://' + host + '/ws')});`;
        new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
      }
      """,
      server.host
    )

    req = Task.await(req_promise, :infinity)
    assert Plug.Conn.get_req_header(req, "foo") == ["bar"]
  end
end
