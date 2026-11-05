defmodule PlaywrightEx.Library.RouteWebSocketTest do
  @upstream "tests/library/route-web-socket.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils
  alias PlaywrightEx.WebSocketRoute

  @moduletag :page

  # `target: Page | Frame`
  defp setup_ws(target, server, binary_type, protocols \\ nil, relative_url \\ false) do
    facade = if is_struct(target, PlaywrightEx.Client.Frame), do: Frame, else: Page
    facade.goto!(target, server.empty_page)
    ws_url = if relative_url, do: "/ws", else: "ws://" <> server.host <> "/ws"

    facade.evaluate!(
      target,
      """
      ({ wsUrl, binaryType, protocols }) => {
        window.log = [];
        window.ws = new WebSocket(wsUrl, protocols);
        window.ws.binaryType = binaryType;
        window.ws.addEventListener('open', () => window.log.push('open'));
        window.ws.addEventListener('close', event => window.log.push(`close code=${event.code} reason=${event.reason} wasClean=${event.wasClean}`));
        window.ws.addEventListener('error', event => window.log.push(`error`));
        window.ws.addEventListener('message', async event => {
          let data;
          if (typeof event.data === 'string')
            data = event.data;
          else if (event.data instanceof Blob)
            data = 'blob:' + await event.data.text();
          else
            data = 'arraybuffer:' + await (new Blob([event.data])).text();
          window.log.push(`message: data=${data} origin=${event.origin} lastEventId=${event.lastEventId}`);
        });
        window.wsOpened = new Promise(f => window.ws.addEventListener('open', () => f()));
      }
      """,
      # `protocols: undefined` (`nil` would be `null`, a protocol named "null")
      Map.reject(%{wsUrl: ws_url, binaryType: binary_type, protocols: protocols}, fn {_, v} -> is_nil(v) end)
    )
  end

  for mock <- ["no-mock", "no-match", "pass-through"] do
    describe mock do
      setup %{page: page} do
        case unquote(mock) do
          "no-match" ->
            Page.route_web_socket!(page, ~r/zzz/, fn _ -> nil end)

          "pass-through" ->
            Page.route_web_socket!(page, ~r/.*/, fn ws ->
              server = WebSocketRoute.connect_to_server(ws)
              WebSocketRoute.on_message(ws, &WebSocketRoute.send(server, &1))
              WebSocketRoute.on_message(server, &WebSocketRoute.send(ws, &1))
            end)

          "no-mock" ->
            nil
        end

        :ok
      end

      test "should work with text message", %{page: page, server: server} do
        ws_promise = TestServer.wait_for_web_socket(server)
        upgrade_promise = TestServer.wait_for_upgrade(server)
        setup_ws(page, server, "blob")
        assert Page.evaluate!(page, "() => window.ws.readyState") == 0
        %{do_upgrade: do_upgrade} = Task.await(upgrade_promise)
        assert Page.evaluate!(page, "() => window.ws.readyState") == 0
        assert Page.evaluate!(page, "() => window.log") == []
        do_upgrade.()
        Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 1))
        assert Page.evaluate!(page, "() => window.log") == ["open"]
        ws = Task.await(ws_promise)
        TestServer.WebSocket.send(ws, "hello")

        Utils.poll(
          fn -> Page.evaluate!(page, "() => window.log") end,
          &assert(&1 == ["open", "message: data=hello origin=ws://#{server.host} lastEventId="])
        )

        assert Page.evaluate!(page, "() => window.ws.readyState") == 1
        me = self()
        TestServer.WebSocket.once(ws, :message, &send(me, {:message, &1}))
        Page.evaluate!(page, "() => window.ws.send('hi')")
        assert_receive {:message, "hi"}, 5000
        TestServer.WebSocket.close(ws, 1008, "oops")
        Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 3))

        assert Page.evaluate!(page, "() => window.log") == [
                 "open",
                 "message: data=hello origin=ws://#{server.host} lastEventId=",
                 "close code=1008 reason=oops wasClean=true"
               ]
      end

      test "should work with binaryType=blob", %{page: page, server: server} do
        ws_promise = TestServer.wait_for_web_socket(server)
        setup_ws(page, server, "blob")
        ws = Task.await(ws_promise)
        TestServer.WebSocket.send(ws, {:binary, "hi"})

        Utils.poll(
          fn -> Page.evaluate!(page, "() => window.log") end,
          &assert(&1 == ["open", "message: data=blob:hi origin=ws://#{server.host} lastEventId="])
        )

        me = self()
        TestServer.WebSocket.once(ws, :message, &send(me, {:message, &1}))
        Page.evaluate!(page, "() => window.ws.send(new Blob([new Uint8Array(['h'.charCodeAt(0), 'i'.charCodeAt(0)])]))")
        assert_receive {:message, "hi"}, 5000
      end

      test "should work with binaryType=arraybuffer", %{page: page, server: server} do
        ws_promise = TestServer.wait_for_web_socket(server)
        setup_ws(page, server, "arraybuffer")
        ws = Task.await(ws_promise)
        TestServer.WebSocket.send(ws, {:binary, "hi"})

        Utils.poll(
          fn -> Page.evaluate!(page, "() => window.log") end,
          &assert(&1 == ["open", "message: data=arraybuffer:hi origin=ws://#{server.host} lastEventId="])
        )

        me = self()
        TestServer.WebSocket.once(ws, :message, &send(me, {:message, &1}))
        Page.evaluate!(page, "() => window.ws.send(new Uint8Array(['h'.charCodeAt(0), 'i'.charCodeAt(0)]).buffer)")
        assert_receive {:message, "hi"}, 5000
      end

      if System.get_env("BROWSER") == "webkit",
        do: @tag(skip: "upstream skip: WebKit ignores the connection error and fires no events!")

      test "should work when connection errors out", %{page: page, server: server} do
        upgrade_promise = TestServer.wait_for_upgrade(server)
        setup_ws(page, server, "blob")
        %{socket: socket} = Task.await(upgrade_promise)
        assert Page.evaluate!(page, "() => window.ws.readyState") == 0
        assert Page.evaluate!(page, "() => window.log") == []
        TestServer.WebSocket.destroy(socket)
        Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 3))
        assert ["error", close] = Page.evaluate!(page, "() => window.log")
        assert close =~ ~r/close code=\d+ reason= wasClean=false/
      end

      cond do
        System.get_env("BROWSER") == "firefox" ->
          @tag skip: "upstream skip: Firefox does not close the websocket upon a bad frame"

        System.get_env("BROWSER") == "webkit" and match?({:unix, :linux}, :os.type()) ->
          @tag skip: "upstream skip: WebKit linux does not close the websocket upon a bad frame"

        System.get_env("BROWSER") == "webkit" and match?({:win32, _}, :os.type()) ->
          @tag skip: "upstream skip: WebKit Windows does not close the websocket upon a bad frame"

        true ->
          nil
      end

      test "should work with error after successful open", %{page: page, server: server} do
        upgrade_promise = TestServer.wait_for_upgrade(server)
        setup_ws(page, server, "blob")
        %{socket: socket, do_upgrade: do_upgrade} = Task.await(upgrade_promise)
        do_upgrade.()
        Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 1))
        assert Page.evaluate!(page, "() => window.log") == ["open"]
        TestServer.WebSocket.write(socket, "garbage")
        Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 3))
        assert ["open", "error", close] = Page.evaluate!(page, "() => window.log")
        assert close =~ ~r/close code=\d+ reason= wasClean=false/
      end

      test "should work with client-side close", %{page: page, server: server} do
        ws_promise = TestServer.wait_for_web_socket(server)
        upgrade_promise = TestServer.wait_for_upgrade(server)
        setup_ws(page, server, "blob")
        assert Page.evaluate!(page, "() => window.ws.readyState") == 0
        %{do_upgrade: do_upgrade} = Task.await(upgrade_promise)
        assert Page.evaluate!(page, "() => window.ws.readyState") == 0
        assert Page.evaluate!(page, "() => window.log") == []
        do_upgrade.()
        Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 1))
        assert Page.evaluate!(page, "() => window.log") == ["open"]
        ws = Task.await(ws_promise)
        me = self()
        TestServer.WebSocket.once(ws, :close, &send(me, {:closed, %{code: &1, reason: &2}}))

        ready_state =
          Page.evaluate!(page, """
          () => {
            window.ws.close(3002, 'oops');
            return window.ws.readyState;
          }
          """)

        assert ready_state == 2
        Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 3))
        assert Page.evaluate!(page, "() => window.log") == ["open", "close code=3002 reason=oops wasClean=true"]
        assert_receive {:closed, closed}, 5000
        assert closed.code == 3002
        assert closed.reason == "oops"
      end

      test "should pass through the required protocol", %{page: page, server: server} do
        setup_ws(page, server, "blob", "my-custom-protocol")
        Page.evaluate!(page, "() => window.wsOpened")
        protocol = Page.evaluate!(page, "() => window.ws.protocol")
        assert protocol == "my-custom-protocol"
      end

      test "should work with relative WebSocket URL", %{page: page, server: server} do
        ws_promise = TestServer.wait_for_web_socket(server)
        setup_ws(page, server, "blob", nil, true)
        ws = Task.await(ws_promise)
        TestServer.WebSocket.send(ws, {:binary, "hi"})

        Utils.poll(
          fn -> Page.evaluate!(page, "() => window.log") end,
          &assert(&1 == ["open", "message: data=blob:hi origin=ws://#{server.host} lastEventId="])
        )

        me = self()
        TestServer.WebSocket.once(ws, :message, &send(me, {:message, &1}))
        Page.evaluate!(page, "() => window.ws.send(new Blob([new Uint8Array(['h'.charCodeAt(0), 'i'.charCodeAt(0)])]))")
        assert_receive {:message, "hi"}, 5000
      end
    end
  end

  test "should work with ws.close", %{page: page, server: server} do
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      WebSocketRoute.connect_to_server(ws)
      send(me, {:route, ws})
    end)

    ws_promise = TestServer.wait_for_web_socket(server)
    setup_ws(page, server, "blob")
    ws = Task.await(ws_promise)

    assert_receive {:route, route}, 5000
    WebSocketRoute.send(route, "hello")

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(&1 == ["open", "message: data=hello origin=ws://#{server.host} lastEventId="])
    )

    TestServer.WebSocket.once(ws, :close, &send(me, {:closed, %{code: &1, reason: &2}}))
    WebSocketRoute.close!(route, code: 3009, reason: "oops")

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(
        &1 == [
          "open",
          "message: data=hello origin=ws://#{server.host} lastEventId=",
          "close code=3009 reason=oops wasClean=true"
        ]
      )
    )

    assert_receive {:closed, closed}, 5000
    assert closed == %{code: 3009, reason: "oops"}
  end

  test "should observe upstream handshake failure when connectToServer is used", %{page: page, server: server} do
    # Exercises the WebSocket-as-network-request path used by Firefox after the
    # har-WebSocket plumbing change, where a 4xx handshake response is synthesized
    # into a full lifecycle in FFPage._onWebSocketRequestFinished.
    {:ok, server_closes} = Agent.start_link(fn -> [] end)
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      send(me, :route_handler_invoked)
      server_route = WebSocketRoute.connect_to_server(ws)

      WebSocketRoute.on_close(server_route, fn code, reason ->
        Agent.update(server_closes, &(&1 ++ [%{code: code, reason: reason}]))
        WebSocketRoute.close(ws)
      end)
    end)

    upgrade_promise = TestServer.wait_for_upgrade(server)
    setup_ws(page, server, "blob")
    %{socket: socket} = Task.await(upgrade_promise)
    TestServer.WebSocket.write(socket, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
    TestServer.WebSocket.destroy(socket)

    # Server-side route handler observes the close caused by the rejected handshake.
    Utils.poll(fn -> length(Agent.get(server_closes, & &1)) end, &assert(&1 == 1))
    assert hd(Agent.get(server_closes, & &1)).code >= 1000

    # Once the route closes the page-side socket, the page sees the close.
    Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 3))
    assert_received :route_handler_invoked
    refute_received :route_handler_invoked
  end

  # Echo all incoming messages on whichever connection arrives; re-register after each.
  defp handle_connection(server, ws) do
    TestServer.WebSocket.on(ws, :message, fn data -> TestServer.WebSocket.send(ws, "echo-#{data}") end)
    TestServer.once_web_socket_connection(server, &handle_connection(server, &1))
  end

  test "should observe multiple concurrent routed WebSockets with connectToServer", %{page: page, server: server} do
    # Exercises FFNetworkManager._webSocketRequestIds tracking by routing two
    # simultaneous WebSocket connections through `connectToServer()`. Each request
    # gets a distinct id in the new Firefox WebSocket-as-network-request flow.
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      send(me, :routed_connection)
      server_route = WebSocketRoute.connect_to_server(ws)
      WebSocketRoute.on_message(ws, &WebSocketRoute.send(server_route, &1))
      WebSocketRoute.on_message(server_route, &WebSocketRoute.send(ws, &1))
    end)

    TestServer.once_web_socket_connection(server, &handle_connection(server, &1))

    Page.goto!(page, server.empty_page)

    results =
      Page.evaluate!(
        page,
        """
        async host => {
          const collect = (tag) => new Promise(resolve => {
            const ws = new WebSocket(`ws://${host}/ws`);
            ws.addEventListener('open', () => ws.send(`hi-${tag}`));
            ws.addEventListener('message', event => {
              resolve(event.data);
              ws.close();
            });
          });
          return Promise.all([collect('a'), collect('b')]);
        }
        """,
        server.host
      )

    assert Enum.sort(results) == ["echo-hi-a", "echo-hi-b"]
    assert_received :routed_connection
    assert_received :routed_connection
    refute_received :routed_connection
  end

  test "should pattern match", %{page: page, server: server} do
    Page.route_web_socket!(page, ~r/.*\/ws$/, &WebSocketRoute.connect_to_server/1)

    Page.route_web_socket!(page, "**/mock-ws", fn ws ->
      WebSocketRoute.on_message(ws, fn _message -> WebSocketRoute.send(ws, "mock-response") end)
    end)

    ws_promise = TestServer.wait_for_web_socket(server)

    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      """
      async ({ host }) => {
        window.log = [];
        window.ws1 = new WebSocket('ws://' + host + '/ws');
        window.ws1.addEventListener('message', event => window.log.push(`ws1:${event.data}`));
        window.ws2 = new WebSocket('ws://' + host + '/something/something/mock-ws');
        window.ws2.addEventListener('message', event => window.log.push(`ws2:${event.data}`));
        await Promise.all([
          new Promise(f => window.ws1.addEventListener('open', f)),
          new Promise(f => window.ws2.addEventListener('open', f)),
        ]);
      }
      """,
      %{host: server.host}
    )

    ws = Task.await(ws_promise)
    TestServer.WebSocket.on(ws, :message, fn -> TestServer.WebSocket.send(ws, "response") end)

    Page.evaluate!(page, "() => window.ws1.send('request')")
    Utils.poll(fn -> Page.evaluate!(page, "() => window.log") end, &assert(&1 == ["ws1:response"]))

    Page.evaluate!(page, "() => window.ws2.send('request')")
    Utils.poll(fn -> Page.evaluate!(page, "() => window.log") end, &assert(&1 == ["ws1:response", "ws2:mock-response"]))
  end

  test "should work with server", %{page: page, server: server} do
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      server = WebSocketRoute.connect_to_server(ws)

      WebSocketRoute.on_message(ws, fn
        "to-respond" -> WebSocketRoute.send(ws, "response")
        "to-block" -> nil
        "to-modify" -> WebSocketRoute.send(server, "modified")
        message -> WebSocketRoute.send(server, message)
      end)

      WebSocketRoute.on_message(server, fn
        "to-block" -> nil
        "to-modify" -> WebSocketRoute.send(ws, "modified")
        message -> WebSocketRoute.send(ws, message)
      end)

      WebSocketRoute.send(server, "fake")
      send(me, {:route, ws})
    end)

    ws_promise = TestServer.wait_for_web_socket(server)
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = &Agent.update(log, fn log -> log ++ [&1] end)

    TestServer.once_web_socket_connection(server, fn ws ->
      TestServer.WebSocket.on(ws, :message, &push.("message: #{&1}"))
      TestServer.WebSocket.on(ws, :close, &push.("close: code=#{&1} reason=#{&2}"))
    end)

    setup_ws(page, server, "blob")
    ws = Task.await(ws_promise)
    Utils.poll(fn -> Agent.get(log, & &1) end, &assert(&1 == ["message: fake"]))

    TestServer.WebSocket.send(ws, "to-modify")
    TestServer.WebSocket.send(ws, "to-block")
    TestServer.WebSocket.send(ws, "pass-server")

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(
        &1 == [
          "open",
          "message: data=modified origin=ws://#{server.host} lastEventId=",
          "message: data=pass-server origin=ws://#{server.host} lastEventId="
        ]
      )
    )

    Page.evaluate!(page, """
    () => {
      window.ws.send('to-respond');
      window.ws.send('to-modify');
      window.ws.send('to-block');
      window.ws.send('pass-client');
    }
    """)

    Utils.poll(
      fn -> Agent.get(log, & &1) end,
      &assert(&1 == ["message: fake", "message: modified", "message: pass-client"])
    )

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(
        &1 == [
          "open",
          "message: data=modified origin=ws://#{server.host} lastEventId=",
          "message: data=pass-server origin=ws://#{server.host} lastEventId=",
          "message: data=response origin=ws://#{server.host} lastEventId="
        ]
      )
    )

    assert_receive {:route, route}, 5000
    WebSocketRoute.send(route, "another")

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(
        &1 == [
          "open",
          "message: data=modified origin=ws://#{server.host} lastEventId=",
          "message: data=pass-server origin=ws://#{server.host} lastEventId=",
          "message: data=response origin=ws://#{server.host} lastEventId=",
          "message: data=another origin=ws://#{server.host} lastEventId="
        ]
      )
    )

    Page.evaluate!(page, """
    () => {
      window.ws.send('pass-client-2');
    }
    """)

    Utils.poll(
      fn -> Agent.get(log, & &1) end,
      &assert(&1 == ["message: fake", "message: modified", "message: pass-client", "message: pass-client-2"])
    )

    Page.evaluate!(page, """
    () => {
      window.ws.close(3009, 'problem');
    }
    """)

    Utils.poll(
      fn -> Agent.get(log, & &1) end,
      &assert(
        &1 == [
          "message: fake",
          "message: modified",
          "message: pass-client",
          "message: pass-client-2",
          "close: code=3009 reason=problem"
        ]
      )
    )
  end

  test "should work without server", %{page: page, server: server} do
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      WebSocketRoute.on_message(ws, fn
        "to-respond" -> WebSocketRoute.send(ws, "response")
        _ -> nil
      end)

      send(me, {:route, ws})
    end)

    setup_ws(page, server, "blob")

    Page.evaluate!(page, """
    async () => {
      await window.wsOpened;
      window.ws.send('to-respond');
      window.ws.send('to-block');
      window.ws.send('to-respond');
    }
    """)

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(
        &1 == [
          "open",
          "message: data=response origin=ws://#{server.host} lastEventId=",
          "message: data=response origin=ws://#{server.host} lastEventId="
        ]
      )
    )

    assert_receive {:route, route}, 5000
    WebSocketRoute.send(route, "another")
    WebSocketRoute.close!(route, code: 3008, reason: "oops")

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(
        &1 == [
          "open",
          "message: data=response origin=ws://#{server.host} lastEventId=",
          "message: data=response origin=ws://#{server.host} lastEventId=",
          "message: data=another origin=ws://#{server.host} lastEventId=",
          "close code=3008 reason=oops wasClean=true"
        ]
      )
    )
  end

  test "should route WebSockets in already loaded documents", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Utils.attach_frame(page, "frame1", server.empty_page)

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      WebSocketRoute.on_message(ws, &WebSocketRoute.send(ws, "mock-" <> &1))
    end)

    for target <- [Page.main_frame(page), frame] do
      Frame.evaluate!(
        target,
        """
        ({ host }) => {
          window.log = [];
          window.ws = new WebSocket('ws://' + host + '/ws');
          window.ws.addEventListener('message', event => window.log.push(event.data));
          window.ws.addEventListener('close', () => window.log.push('close'));
          window.ws.addEventListener('open', () => window.ws.send('hi'));
        }
        """,
        %{host: server.host}
      )

      Utils.poll(fn -> Frame.evaluate!(target, "() => window.log") end, &assert(&1 == ["mock-hi"]))
    end
  end

  test "should emit close upon frame navigation", %{page: page, server: server} do
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      WebSocketRoute.connect_to_server(ws)
      send(me, {:route, ws})
    end)

    setup_ws(page, server, "blob")

    assert_receive {:route, route}, 5000
    WebSocketRoute.send(route, "hello")

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(&1 == ["open", "message: data=hello origin=ws://#{server.host} lastEventId="])
    )

    WebSocketRoute.on_close(route, fn _, _ -> send(me, :closed) end)
    Page.goto!(page, server.empty_page)
    assert_receive :closed, 5000
  end

  test "should emit close upon frame detach", %{page: page, server: server} do
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      WebSocketRoute.connect_to_server(ws)
      send(me, {:route, ws})
    end)

    frame = Utils.attach_frame(page, "frame1", server.empty_page)
    setup_ws(frame, server, "blob")

    assert_receive {:route, route}, 5000
    WebSocketRoute.send(route, "hello")

    Utils.poll(
      fn -> Frame.evaluate!(frame, "() => window.log") end,
      &assert(&1 == ["open", "message: data=hello origin=ws://#{server.host} lastEventId="])
    )

    WebSocketRoute.on_close(route, fn _, _ -> send(me, :closed) end)
    Utils.detach_frame(page, "frame1")
    assert_receive :closed, 5000
  end

  test "should route on context", %{page: page, server: server} do
    Page.route_web_socket!(page, ~r/ws1/, fn ws ->
      WebSocketRoute.on_message(ws, fn _message -> WebSocketRoute.send(ws, "page-mock-1") end)
    end)

    Page.route_web_socket!(page, ~r/ws1/, fn ws ->
      WebSocketRoute.on_message(ws, fn _message -> WebSocketRoute.send(ws, "page-mock-2") end)
    end)

    BrowserContext.route_web_socket!(Page.context(page), ~r/.*/, fn ws ->
      WebSocketRoute.on_message(ws, fn _message -> WebSocketRoute.send(ws, "context-mock-1") end)
      WebSocketRoute.on_message(ws, fn _message -> WebSocketRoute.send(ws, "context-mock-2") end)
    end)

    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      """
      ({ host }) => {
        window.log = [];
        window.ws1 = new WebSocket('ws://' + host + '/ws1');
        window.ws1.addEventListener('message', event => window.log.push(`ws1:${event.data}`));
        window.ws2 = new WebSocket('ws://' + host + '/ws2');
        window.ws2.addEventListener('message', event => window.log.push(`ws2:${event.data}`));
      }
      """,
      %{host: server.host}
    )

    Page.evaluate!(page, "() => window.ws1.send('request')")
    Utils.poll(fn -> Page.evaluate!(page, "() => window.log") end, &assert(&1 == ["ws1:page-mock-2"]))

    Page.evaluate!(page, "() => window.ws2.send('request')")

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(&1 == ["ws1:page-mock-2", "ws2:context-mock-2"])
    )
  end

  test "should not throw after page closure", %{page: page, server: server} do
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      WebSocketRoute.connect_to_server(ws)
      send(me, {:route, ws})
    end)

    setup_ws(page, server, "blob")

    assert_receive {:route, route}, 5000
    close = Task.async(fn -> Page.close!(page) end)
    assert WebSocketRoute.send(route, "hello") == :ok
    Task.await(close)
  end

  test "should not throw with empty handler", %{page: page, server: server} do
    Page.route_web_socket!(page, ~r/.*/, fn _ -> nil end)
    setup_ws(page, server, "blob")
    Utils.poll(fn -> Page.evaluate!(page, "() => window.log") end, &assert(&1 == ["open"]))
    Page.evaluate!(page, "() => window.ws.send('hi')")
    Page.evaluate!(page, "() => window.ws.send('hi2')")
    Utils.poll(fn -> Page.evaluate!(page, "() => window.log") end, &assert(&1 == ["open"]))
  end

  test "should throw when connecting twice", %{page: page, server: server} do
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      WebSocketRoute.connect_to_server(ws)

      try do
        WebSocketRoute.connect_to_server(ws)
      rescue
        e -> send(me, {:error, e})
      end
    end)

    setup_ws(page, server, "blob")
    assert_receive {:error, error}, 5000
    assert Exception.message(error) =~ "Already connected to the server"
  end

  test "should work with no trailing slash", %{page: page, server: server} do
    {:ok, log} = Agent.start_link(fn -> [] end)
    # No trailing slash!
    Page.route_web_socket!(page, "ws://" <> server.host, fn ws ->
      WebSocketRoute.on_message(ws, fn message ->
        Agent.update(log, &(&1 ++ [message]))
        WebSocketRoute.send(ws, "response")
      end)
    end)

    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      """
      ({ host }) => {
        window.log = [];
        // No trailing slash!
        window.ws = new WebSocket('ws://' + host);
        window.ws.addEventListener('message', event => window.log.push(event.data));
      }
      """,
      %{host: server.host}
    )

    Utils.poll(fn -> Page.evaluate!(page, "() => window.ws.readyState") end, &assert(&1 == 1))
    Page.evaluate!(page, "() => window.ws.send('query')")
    Utils.poll(fn -> Agent.get(log, & &1) end, &assert(&1 == ["query"]))
    assert Page.evaluate!(page, "() => window.log") == ["response"]
  end

  @tag page: false
  test "should work with baseURL", %{context_factory: context_factory, server: server} do
    context = context_factory.(base_url: "http://" <> server.host)
    page = BrowserContext.new_page!(context)

    Page.route_web_socket!(page, "/ws", fn ws ->
      WebSocketRoute.on_message(ws, &WebSocketRoute.send(ws, &1))
    end)

    setup_ws(page, server, "blob")

    Page.evaluate!(page, """
    async () => {
      await window.wsOpened;
      window.ws.send('echo');
    }
    """)

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(&1 == ["open", "message: data=echo origin=ws://#{server.host} lastEventId="])
    )
  end

  @tag page: false
  test "should work with baseURL regardless of scheme casing", %{context_factory: context_factory, server: server} do
    # baseURL schemes are case-insensitive, same as everywhere else in URL matching.
    context = context_factory.(base_url: "HTTP://" <> server.host)
    page = BrowserContext.new_page!(context)

    Page.route_web_socket!(page, "/ws", fn ws ->
      WebSocketRoute.on_message(ws, &WebSocketRoute.send(ws, &1))
    end)

    setup_ws(page, server, "blob")

    Page.evaluate!(page, """
    async () => {
      await window.wsOpened;
      window.ws.send('echo');
    }
    """)

    Utils.poll(
      fn -> Page.evaluate!(page, "() => window.log") end,
      &assert(&1 == ["open", "message: data=echo origin=ws://#{server.host} lastEventId="])
    )
  end

  test "should expose protocols to the route handler", %{page: page, server: server} do
    {:ok, routes} = Agent.start_link(fn -> [] end)
    Page.route_web_socket!(page, ~r/.*/, fn ws -> Agent.update(routes, &(&1 ++ [ws])) end)

    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      """
      ({ host }) => {
        window.wsNone = new WebSocket('ws://' + host + '/ws-none');
        window.wsString = new WebSocket('ws://' + host + '/ws-string', 'chat.v1');
        window.wsArray = new WebSocket('ws://' + host + '/ws-array', ['chat.v2', 'chat.v1']);
      }
      """,
      %{host: server.host}
    )

    Utils.poll(fn -> length(Agent.get(routes, & &1)) end, &assert(&1 == 3))

    by_url = Map.new(Agent.get(routes, & &1), &{URI.parse(WebSocketRoute.url(&1)).path, &1})
    assert WebSocketRoute.protocols(by_url["/ws-none"]) == []
    assert WebSocketRoute.protocols(by_url["/ws-string"]) == ["chat.v1"]
    assert WebSocketRoute.protocols(by_url["/ws-array"]) == ["chat.v2", "chat.v1"]
  end

  test "should expose protocols on server-side route", %{page: page, server: server} do
    me = self()

    Page.route_web_socket!(page, ~r/.*/, fn ws ->
      server_route = WebSocketRoute.connect_to_server(ws)
      send(me, {:routes, ws, server_route})
    end)

    setup_ws(page, server, "blob", ["chat.v2", "chat.v1"])
    assert_receive {:routes, page_route, server_route}, 5000
    assert WebSocketRoute.protocols(page_route) == ["chat.v2", "chat.v1"]
    assert WebSocketRoute.protocols(server_route) == ["chat.v2", "chat.v1"]
  end
end
