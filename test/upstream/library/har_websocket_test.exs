defmodule PlaywrightEx.Library.HarWebsocketTest do
  @upstream "tests/library/har-websocket.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils
  alias PlaywrightEx.WebSocket
  alias PlaywrightEx.WebSocketRoute

  # Browser-reported message times are derived from a wall-clock baseline plus
  # monotonic timestamps in the browser process, so they can drift by a few
  # milliseconds relative to Date.now() in the test process.
  @clock_skew_ms 100

  # testInfo.outputPath(): a fresh directory per test.
  setup do
    dir = Path.join(System.tmp_dir!(), "playwright_ex-har-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{output_path: &Path.join(dir, &1)}
  end

  defp page_with_har(context_factory, output_path, options \\ %{}) do
    {name, options} = Map.pop(options, :outputPath)
    har_path = output_path.(name || "test.har")
    context = context_factory.(record_har: Map.put(options, :path, har_path), ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    %{page: page, context: context, har_path: har_path}
  end

  defp get_log(%{context: context, har_path: har_path}) do
    BrowserContext.close!(context)
    har_path |> File.read!() |> JSON.decode!() |> Map.fetch!("log")
  end

  defp get_zip(%{context: context, har_path: har_path}) do
    BrowserContext.close!(context)
    parse_har(har_path)
  end

  # parseHar (tests/config/utils.ts): the zip entries by name.
  defp parse_har(file) do
    {:ok, entries} = :zip.unzip(to_charlist(file), [:memory])
    Map.new(entries, fn {name, data} -> {to_string(name), data} end)
  end

  defp headers_size(headers) do
    Enum.reduce(headers, 0, fn %{"name" => name, "value" => value}, result ->
      result + byte_size(name) + byte_size(": ") + byte_size(value) + byte_size("\r\n")
    end)
  end

  defp request_headers_size(headers), do: byte_size("GET /ws HTTP/1.1\r\n") + headers_size(headers)

  defp response_headers_size(headers),
    do: byte_size("HTTP/1.1 101 Switching Protocols\r\n") + headers_size(headers) + byte_size("\r\n")

  defp message_size(message) do
    length = byte_size(message)

    cond do
      # The payload is short enough that they only need the minimum frame header size.
      length <= 125 -> 6 + length
      # The payload is large enough that additional bytes are needed to represent the payload length.
      length < 2 ** 16 -> 6 + 2 + length
      true -> 6 + 8 + length
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp date_ms(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end

  defp find_entry(log, url), do: Enum.find(log["entries"], &(&1["request"]["url"] == url))

  defp header_names(headers), do: Enum.map(headers, &String.downcase(&1["name"]))

  # `{ type, opcode, data }` with binary data decoded from base64.
  defp decode_messages(messages) do
    Enum.map(messages, fn m ->
      data = if m["opcode"] == 1, do: m["data"], else: Base.decode64!(m["data"])
      %{type: m["type"], opcode: m["opcode"], data: data}
    end)
  end

  defp parse_jsonl(data) do
    data |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.map(&JSON.decode!/1)
  end

  defp close_after_message(server) do
    TestServer.once_web_socket_connection(server, fn ws ->
      TestServer.WebSocket.on(ws, :message, fn _ -> TestServer.WebSocket.close(ws) end)
    end)
  end

  @send_ping_until_closed """
  url => new Promise(resolve => {
    const ws = new WebSocket(url);
    ws.addEventListener('open', () => ws.send('ping'));
    ws.addEventListener('close', () => resolve());
  })
  """

  test "HA-101 should only have one websocket entry", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    close_after_message(server)
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    ws_url = "ws://#{server.host}/ws"
    Page.evaluate!(page, @send_ping_until_closed, ws_url)
    log = get_log(session)
    ws_entries = Enum.filter(log["entries"], &String.ends_with?(&1["request"]["url"], "://#{server.host}/ws"))
    assert length(ws_entries) == 1

    [ws_entry] = ws_entries
    assert ws_entry["_resourceType"] == "websocket"
  end

  test "HA-102 should include websocket handshake headers and status", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    close_after_message(server)

    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    before_ms = now_ms()
    ws_url = "ws://#{server.host}/ws"
    Page.evaluate!(page, @send_ping_until_closed, ws_url)
    log = get_log(session)
    after_ms = now_ms()

    ws_entry = find_entry(log, ws_url)
    assert ws_entry["_resourceType"] == "websocket"
    assert ws_entry["request"]["headersSize"] == request_headers_size(ws_entry["request"]["headers"])
    assert ws_entry["response"]["status"] == 101
    assert ws_entry["response"]["statusText"] == "Switching Protocols"
    assert ws_entry["response"]["headersSize"] == response_headers_size(ws_entry["response"]["headers"])

    wall_time_ms = date_ms(ws_entry["startedDateTime"])
    assert wall_time_ms >= before_ms - @clock_skew_ms
    assert wall_time_ms <= after_ms + @clock_skew_ms

    request_header_names = header_names(ws_entry["request"]["headers"])
    assert "upgrade" in request_header_names
    assert "connection" in request_header_names
    assert "sec-websocket-key" in request_header_names
    assert "sec-websocket-version" in request_header_names
    upgrade_header = Enum.find(ws_entry["request"]["headers"], &(String.downcase(&1["name"]) == "upgrade"))
    assert String.downcase(upgrade_header["value"]) == "websocket"

    response_header_names = header_names(ws_entry["response"]["headers"])
    assert "upgrade" in response_header_names
    assert "connection" in response_header_names
    assert "sec-websocket-accept" in response_header_names
  end

  defp send_incoming(ws, incoming_text, incoming_binary, delay_ms) do
    for text <- incoming_text do
      TestServer.WebSocket.send(ws, text)
      Process.sleep(delay_ms)
    end

    for binary <- incoming_binary do
      Process.sleep(delay_ms)
      TestServer.WebSocket.send(ws, {:binary, binary})
    end
  end

  defp test_web_socket_messages(context_factory, server, output_path, content) do
    sizes = [125, 126, 2 ** 16]
    incoming_text = Enum.map(sizes, &String.duplicate("x", &1))
    incoming_binary = Enum.map(sizes, &:binary.copy(<<0x01>>, &1))
    outgoing_text = Enum.map(sizes, &String.duplicate("y", &1))
    outgoing_binary = Enum.map(sizes, &:binary.copy(<<0x02>>, &1))
    incoming_count = length(incoming_text) + length(incoming_binary)
    delay_ms = 100

    # Upstream's async handler; the listener runs in the ws process, which must stay free to send.
    TestServer.once_web_socket_connection(server, fn ws ->
      spawn(fn -> send_incoming(ws, incoming_text, incoming_binary, delay_ms) end)
    end)

    har_output_path = if content == "embed", do: nil, else: "test.har.zip"

    %{page: page} =
      session = page_with_har(context_factory, output_path, %{content: content, outputPath: har_output_path})

    Page.goto!(page, server.empty_page)

    before_ms = now_ms()
    ws_url = "ws://#{server.host}/ws"

    Page.evaluate!(
      page,
      """
      ({ url, incomingCount, outgoingText, outgoingBinary, delayMs }) => new Promise(resolve => {
        let count = 0;
        const ws = new WebSocket(url);
        ws.addEventListener('message', async () => {
          if (++count < incomingCount)
            return;
          for (const text of outgoingText) {
            ws.send(text);
            await new Promise(resolve => window.builtins.setTimeout(resolve, delayMs));
          }
          for (const binary of outgoingBinary) {
            await new Promise(resolve => window.builtins.setTimeout(resolve, delayMs));
            ws.send(new Uint8Array(binary));
          }
          ws.close();
        });
        ws.addEventListener('close', () => resolve());
      })
      """,
      %{
        url: ws_url,
        incomingCount: incoming_count,
        outgoingText: outgoing_text,
        outgoingBinary: Enum.map(outgoing_binary, &:binary.bin_to_list/1),
        delayMs: delay_ms
      }
    )

    after_ms = now_ms()

    {zip, log} =
      if har_output_path do
        zip = get_zip(session)
        {zip, zip |> Map.fetch!("har.har") |> JSON.decode!() |> Map.fetch!("log")}
      else
        {nil, get_log(session)}
      end

    ws_entry = find_entry(log, ws_url)

    assert ws_entry["response"]["_transferSize"] ==
             response_headers_size(ws_entry["response"]["headers"]) +
               Enum.sum_by(incoming_text ++ incoming_binary, &message_size/1)

    assert ws_entry["time"] <= after_ms - before_ms

    if content == "omit" do
      assert ws_entry["response"]["content"]["_file"] == nil
    else
      messages =
        if content == "attach" do
          assert ws_entry["_webSocketMessages"] == nil
          file = ws_entry["response"]["content"]["_file"]
          assert file =~ ~r/^[0-9a-f]+\.jsonl$/
          parse_jsonl(Map.fetch!(zip, file))
        else
          ws_entry["_webSocketMessages"]
        end

      assert decode_messages(messages) ==
               Enum.map(incoming_text, &%{type: "receive", opcode: 1, data: &1}) ++
                 Enum.map(incoming_binary, &%{type: "receive", opcode: 2, data: &1}) ++
                 Enum.map(outgoing_text, &%{type: "send", opcode: 1, data: &1}) ++
                 Enum.map(outgoing_binary, &%{type: "send", opcode: 2, data: &1})

      # if (channel !== 'webkit-wsl')  -- we never run webkit-wsl
      for m <- messages do
        assert m["time"] >= before_ms - @clock_skew_ms
        assert m["time"] <= after_ms + @clock_skew_ms
      end

      assert Enum.at(messages, 0)["time"] <= Enum.at(messages, 1)["time"]
      assert ws_entry["time"] >= List.last(messages)["time"] - hd(messages)["time"]
    end
  end

  test "HA-103 should embed websocket messages", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    test_web_socket_messages(context_factory, server, output_path, "embed")
  end

  test "HA-104 should attach websocket messages", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    test_web_socket_messages(context_factory, server, output_path, "attach")
  end

  test "HA-105 should attach websocket messages for a still open websocket after stopping", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    incoming_text = "incoming"
    incoming_binary = <<0x01, 0x02, 0x03, 0x04>>
    outgoing_text = "outgoing"
    outgoing_binary = <<0x05, 0x06, 0x07, 0x08>>

    TestServer.once_web_socket_connection(server, fn ws ->
      count = :counters.new(1, [])

      TestServer.WebSocket.on(ws, :message, fn _ ->
        :counters.add(count, 1, 1)

        TestServer.WebSocket.send(
          ws,
          if(:counters.get(count, 1) < 2, do: incoming_text, else: {:binary, incoming_binary})
        )
      end)
    end)

    %{page: page} =
      session = page_with_har(context_factory, output_path, %{content: "attach", outputPath: "test.har.zip"})

    Page.goto!(page, server.empty_page)

    before_ms = now_ms()
    ws_url = "ws://#{server.host}/ws"
    me = self()

    # page.waitForEvent('websocket') then ws.waitForEvent('framesent' / 'framereceived') twice
    # each: listeners from the moment the socket is announced, so no frame is missed.
    Page.once(page, :web_socket, fn ws ->
      WebSocket.on(ws, :frame_sent, fn _ -> send(me, :frame_sent) end)
      WebSocket.on(ws, :frame_received, fn _ -> send(me, :frame_received) end)
    end)

    evaluate_promise =
      Runtime.Promise.async(fn ->
        Page.evaluate!(
          page,
          """
          ({ url, outgoingText, outgoingBinary }) => {
            const ws = new WebSocket(url);
            window.ws = ws;
            let count = 0;
            ws.addEventListener('open', () => ws.send(outgoingText));
            ws.addEventListener('message', () => {
              if (++count < 2)
                ws.send(new Uint8Array(outgoingBinary));
            });
          }
          """,
          %{url: ws_url, outgoingText: outgoing_text, outgoingBinary: :binary.bin_to_list(outgoing_binary)}
        )
      end)

    # Wait for all frames so the HAR tracer has observed them before the context is closed.
    for event <- [:frame_sent, :frame_received, :frame_sent, :frame_received], do: assert_receive(^event)
    Runtime.Promise.await(evaluate_promise)
    after_ms = now_ms()

    # Do not close the WebSocket on the page side. Closing the context should still flush messages.
    assert Page.evaluate!(page, "() => window.ws.readyState") == 1

    zip = get_zip(session)
    log = zip |> Map.fetch!("har.har") |> JSON.decode!() |> Map.fetch!("log")

    ws_entry = find_entry(log, ws_url)

    assert ws_entry["response"]["_transferSize"] ==
             response_headers_size(ws_entry["response"]["headers"]) + message_size(incoming_text) +
               message_size(incoming_binary)

    assert ws_entry["time"] <= after_ms - before_ms
    assert ws_entry["_webSocketMessages"] == nil

    file = ws_entry["response"]["content"]["_file"]
    assert file =~ ~r/^[0-9a-f]+\.jsonl$/

    messages = parse_jsonl(Map.fetch!(zip, file))

    assert decode_messages(messages) == [
             %{type: "send", opcode: 1, data: outgoing_text},
             %{type: "receive", opcode: 1, data: incoming_text},
             %{type: "send", opcode: 2, data: outgoing_binary},
             %{type: "receive", opcode: 2, data: incoming_binary}
           ]

    # if (channel !== 'webkit-wsl')  -- we never run webkit-wsl
    for m <- messages do
      assert m["time"] >= before_ms - @clock_skew_ms
      assert m["time"] <= after_ms + @clock_skew_ms
    end

    assert Enum.at(messages, 0)["time"] <= Enum.at(messages, 1)["time"]
    assert ws_entry["time"] >= List.last(messages)["time"] - hd(messages)["time"]
  end

  test "HA-106 should omit websocket messages", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    test_web_socket_messages(context_factory, server, output_path, "omit")
  end

  test "HA-107 should record websocket connection failure", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    # it.skip(channel === 'webkit-wsl')  -- we never run webkit-wsl
    # Reserve a port and immediately release it so the WebSocket connect attempt is refused.
    {:ok, port_reservation} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(port_reservation)
    :ok = :gen_tcp.close(port_reservation)

    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    ws_url = "ws://127.0.0.1:#{port}/ws-connect-fail"
    ws_promise = Page.wait_for_event(page, :web_socket)

    Page.evaluate!(
      page,
      """
      url => new Promise(resolve => {
        const ws = new WebSocket(url);
        ws.addEventListener('close', () => resolve());
        ws.addEventListener('error', () => resolve());
      })
      """,
      ws_url
    )

    Promise.await!(ws_promise)
    log = get_log(session)

    ws_entry = find_entry(log, ws_url)
    assert ws_entry["_resourceType"] == "websocket"
    Utils.assert_truthy(ws_entry["response"]["_failureText"])
  end

  test "HA-108 should record websocket handshake failure", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path,
    browser_name: browser_name
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    ws_url = "ws://#{server.host}/ws-handshake-fail"
    upgrade_promise = TestServer.wait_for_upgrade(server)

    ws_close =
      Runtime.Promise.async(fn ->
        Page.evaluate!(
          page,
          """
          url => new Promise(resolve => {
            const ws = new WebSocket(url);
            ws.addEventListener('close', () => resolve());
            ws.addEventListener('error', () => resolve());
          })
          """,
          ws_url
        )
      end)

    %{socket: socket} = Task.await(upgrade_promise, :infinity)
    TestServer.WebSocket.write(socket, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
    TestServer.WebSocket.destroy(socket)
    Runtime.Promise.await(ws_close)
    log = get_log(session)

    ws_entry = find_entry(log, ws_url)
    assert ws_entry["_resourceType"] == "websocket"

    if browser_name != "chromium" do
      # Chromium only reports an error instead of giving a status code and text.
      assert ws_entry["response"]["status"] == 403
      assert ws_entry["response"]["statusText"] == "Forbidden"
    end

    Utils.assert_truthy(ws_entry["response"]["_failureText"])
  end

  @collect_messages_until_closed """
  ({ url, message }) => new Promise(resolve => {
    const seen = [];
    const ws = new WebSocket(url);
    ws.addEventListener('open', () => ws.send(message));
    ws.addEventListener('message', event => {
      seen.push(event.data);
      ws.close();
    });
    ws.addEventListener('close', () => resolve(seen));
  })
  """

  test "HA-109 should still capture websocket when route passes messages through", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    TestServer.once_web_socket_connection(server, fn ws ->
      TestServer.WebSocket.on(ws, :message, fn _ -> TestServer.WebSocket.send(ws, "incoming") end)
    end)

    %{page: page} = session = page_with_har(context_factory, output_path)
    route_handler_called = :counters.new(1, [])

    Page.route_web_socket!(page, ~r/\/ws$/, fn ws ->
      :counters.add(route_handler_called, 1, 1)
      server_route = WebSocketRoute.connect_to_server(ws)
      WebSocketRoute.on_message(ws, &WebSocketRoute.send(server_route, &1))
      WebSocketRoute.on_message(server_route, &WebSocketRoute.send(ws, &1))
    end)

    Page.goto!(page, server.empty_page)

    ws_url = "ws://#{server.host}/ws"
    messages = Page.evaluate!(page, @collect_messages_until_closed, %{url: ws_url, message: "outgoing"})
    assert :counters.get(route_handler_called, 1) == 1
    assert messages == ["incoming"]
    log = get_log(session)

    ws_entries = Enum.filter(log["entries"], &(&1["request"]["url"] == ws_url))
    assert length(ws_entries) == 1
    assert hd(ws_entries)["_resourceType"] == "websocket"
    assert hd(ws_entries)["response"]["status"] == 101

    assert Enum.map(hd(ws_entries)["_webSocketMessages"], &%{type: &1["type"], data: &1["data"]}) == [
             %{type: "send", data: "outgoing"},
             %{type: "receive", data: "incoming"}
           ]
  end

  test "HA-110 should still allow routeWebSocket to fully mock the connection when capturing HAR", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    route_handler_called = :counters.new(1, [])

    Page.route_web_socket!(page, ~r/\/ws$/, fn ws ->
      :counters.add(route_handler_called, 1, 1)

      WebSocketRoute.on_message(ws, fn message ->
        if message == "ping", do: WebSocketRoute.send(ws, "pong")
      end)
    end)

    Page.goto!(page, server.empty_page)

    ws_url = "ws://#{server.host}/ws"
    messages = Page.evaluate!(page, @collect_messages_until_closed, %{url: ws_url, message: "ping"})
    assert :counters.get(route_handler_called, 1) == 1
    assert messages == ["pong"]
    log = get_log(session)

    # Fully mocked routes never create a native WebSocket, so nothing should be recorded.
    ws_entries = Enum.filter(log["entries"], &(&1["request"]["url"] == ws_url))
    assert ws_entries == []
  end

  test "HA-111 should still allow routeWebSocket to modify messages when capturing HAR", %{
    context_factory: context_factory,
    server: server,
    output_path: output_path
  } do
    TestServer.once_web_socket_connection(server, fn ws ->
      TestServer.WebSocket.on(ws, :message, fn message -> TestServer.WebSocket.send(ws, "server-saw-#{message}") end)
    end)

    %{page: page} = session = page_with_har(context_factory, output_path)
    route_handler_called = :counters.new(1, [])

    Page.route_web_socket!(page, ~r/\/ws$/, fn ws ->
      :counters.add(route_handler_called, 1, 1)
      server_route = WebSocketRoute.connect_to_server(ws)
      WebSocketRoute.on_message(ws, &WebSocketRoute.send(server_route, "modified-#{&1}"))
      WebSocketRoute.on_message(server_route, &WebSocketRoute.send(ws, "page-got-#{&1}"))
    end)

    Page.goto!(page, server.empty_page)

    ws_url = "ws://#{server.host}/ws"
    messages = Page.evaluate!(page, @collect_messages_until_closed, %{url: ws_url, message: "hello"})
    assert :counters.get(route_handler_called, 1) == 1
    # The page sees the route-modified server response.
    assert messages == ["page-got-server-saw-modified-hello"]
    log = get_log(session)

    # HAR records actual wire traffic from the native WebSocket: outgoing messages
    # are modified by the client-side route handler before they hit the server,
    # and incoming messages are recorded before the server-side route handler modifies them.
    ws_entries = Enum.filter(log["entries"], &(&1["request"]["url"] == ws_url))
    assert length(ws_entries) == 1

    assert Enum.map(hd(ws_entries)["_webSocketMessages"], &%{type: &1["type"], data: &1["data"]}) == [
             %{type: "send", data: "modified-hello"},
             %{type: "receive", data: "server-saw-modified-hello"}
           ]
  end

  # it.skip(mode !== 'default', 'no env vars in non-default mode')
  test "HA-112 should respect PLAYWRIGHT_HAR_NO_WEBSOCKET_FRAMES", %{server: server, output_path: output_path} do
    # it.skip(mode !== 'default', 'no env vars in non-default mode');  -- we always run the default mode

    # process.env.PLAYWRIGHT_HAR_NO_WEBSOCKET_FRAMES = '1';
    # deviation: upstream sets the variable in the test process, which also runs the Playwright
    # server. Our driver reads it when it starts (as playwright-python does): start another
    # driver with it set, and record the HAR in a browser of that driver.
    name = Module.concat(__MODULE__, NoWebSocketFrames)

    playwright = start_playwright(name, [{"PLAYWRIGHT_HAR_NO_WEBSOCKET_FRAMES", "1"}])
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
    context_factory = &Browser.new_context!(browser, &1)

    close_after_message(server)
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    ws_url = "ws://#{server.host}/ws"
    Page.evaluate!(page, @send_ping_until_closed, ws_url)
    log = get_log(session)
    ws_entry = log["entries"] |> Enum.filter(&String.ends_with?(&1["request"]["url"], "://#{server.host}/ws")) |> hd()
    assert ws_entry["_resourceType"] == "websocket"
    refute Map.has_key?(ws_entry, "_webSocketMessages")
    refute Map.has_key?(ws_entry["response"]["content"], "_file")
    # delete process.env.PLAYWRIGHT_HAR_NO_WEBSOCKET_FRAMES;  -- the driver stops after the test
    Browser.close!(browser)
  end
end
