defmodule PlaywrightEx.Library.RouteWebSocketTest do
  @upstream "tests/library/route-web-socket.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.WebSocketRoute

  @moduletag :page

  defp setup_ws(target, server, binary_type, protocols \\ nil, relative_url \\ false) do
    Page.goto!(target, server.empty_page)
    ws_url = if relative_url, do: "/ws", else: "ws://" <> server.host <> "/ws"

    Page.evaluate!(
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

      @tag skip: "not ported: expect.poll"
      test "should work with text message"

      @tag skip: "not ported: expect.poll"
      test "should work with binaryType=blob"

      @tag skip: "not ported: expect.poll"
      test "should work with binaryType=arraybuffer"

      @tag skip: "not ported: expect.poll"
      test "should work when connection errors out"

      @tag skip: "not ported: expect.poll"
      test "should work with error after successful open"

      @tag skip: "not ported: expect.poll"
      test "should work with client-side close"

      test "should pass through the required protocol", %{page: page, server: server} do
        setup_ws(page, server, "blob", "my-custom-protocol")
        Page.evaluate!(page, "() => window.wsOpened")
        protocol = Page.evaluate!(page, "() => window.ws.protocol")
        assert protocol == "my-custom-protocol"
      end

      @tag skip: "not ported: expect.poll"
      test "should work with relative WebSocket URL"
    end
  end

  @tag skip: "not ported: expect.poll"
  test "should work with ws.close"

  @tag skip: "not ported: expect.poll"
  test "should observe upstream handshake failure when connectToServer is used"

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

  @tag skip: "not ported: expect.poll"
  test "should pattern match"

  @tag skip: "not ported: expect.poll"
  test "should work with server"

  @tag skip: "not ported: expect.poll"
  test "should work without server"

  @tag skip: "not ported: expect.poll"
  test "should route WebSockets in already loaded documents"

  @tag skip: "not ported: expect.poll"
  test "should emit close upon frame navigation"

  @tag skip: "not ported: expect.poll"
  test "should emit close upon frame detach"

  @tag skip: "not ported: expect.poll"
  test "should route on context"

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

  @tag skip: "not ported: expect.poll"
  test "should not throw with empty handler"

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

  @tag skip: "not ported: expect.poll"
  test "should work with no trailing slash"

  @tag skip: "not ported: expect.poll"
  test "should work with baseURL"

  @tag skip: "not ported: expect.poll"
  test "should work with baseURL regardless of scheme casing"

  @tag skip: "not ported: expect.poll"
  test "should expose protocols to the route handler"

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
