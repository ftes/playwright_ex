defmodule PlaywrightEx.Examples.WebSocketRouteTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.WebSocketRoute

  example "WebSocketRoute",
    js: ~S"""
    await page.routeWebSocket('wss://example.com/ws', ws => {
      ws.onMessage(message => {
        if (message === 'request')
          ws.send('response');
      });
    });
    """ do
    Page.route_web_socket!(page, "wss://example.com/ws", fn ws ->
      WebSocketRoute.on_message(ws, fn message ->
        if message == "request", do: WebSocketRoute.send(ws, "response")
      end)
    end)
  end

  example "WebSocketRoute",
    js: ~S"""
    await page.routeWebSocket('wss://example.com/ws', ws => {
      ws.onMessage(message => {
        const json = JSON.parse(message);
        if (json.request === 'question')
          ws.send(JSON.stringify({ response: 'answer' }));
      });
    });
    """ do
    Page.route_web_socket!(page, "wss://example.com/ws", fn ws ->
      WebSocketRoute.on_message(ws, fn message ->
        json = JSON.decode!(message)
        if json["request"] == "question", do: WebSocketRoute.send(ws, JSON.encode!(%{response: "answer"}))
      end)
    end)
  end

  example "WebSocketRoute",
    js: ~S"""
    await page.routeWebSocket('/ws', ws => {
      const server = ws.connectToServer();
      ws.onMessage(message => {
        if (message === 'request')
          server.send('request2');
        else
          server.send(message);
      });
    });
    """ do
    Page.route_web_socket!(page, "/ws", fn ws ->
      server = WebSocketRoute.connect_to_server(ws)

      WebSocketRoute.on_message(ws, fn message ->
        if message == "request",
          do: WebSocketRoute.send(server, "request2"),
          else: WebSocketRoute.send(server, message)
      end)
    end)
  end

  example "WebSocketRoute",
    js: ~S"""
    await page.routeWebSocket('/ws', ws => {
      const server = ws.connectToServer();
      ws.onMessage(message => {
        if (message !== 'blocked-from-the-page')
          server.send(message);
      });
      server.onMessage(message => {
        if (message !== 'blocked-from-the-server')
          ws.send(message);
      });
    });
    """ do
    Page.route_web_socket!(page, "/ws", fn ws ->
      server = WebSocketRoute.connect_to_server(ws)

      WebSocketRoute.on_message(ws, fn message ->
        if message != "blocked-from-the-page", do: WebSocketRoute.send(server, message)
      end)

      WebSocketRoute.on_message(server, fn message ->
        if message != "blocked-from-the-server", do: WebSocketRoute.send(ws, message)
      end)
    end)
  end

  example "WebSocketRoute.protocols",
    js: ~S"""
    await page.routeWebSocket('wss://example.com/ws', ws => {
      if (ws.protocols().includes('chat.v2'))
        ws.onMessage(message => ws.send(JSON.stringify({ version: 2, echo: message })));
      else
        ws.close({ code: 1002, reason: 'Unsupported protocol' });
    });
    """ do
    Page.route_web_socket!(page, "wss://example.com/ws", fn ws ->
      if "chat.v2" in WebSocketRoute.protocols(ws) do
        WebSocketRoute.on_message(ws, &WebSocketRoute.send(ws, JSON.encode!(%{version: 2, echo: &1})))
      else
        WebSocketRoute.close(ws, code: 1002, reason: "Unsupported protocol")
      end
    end)
  end
end
