defmodule PlaywrightEx.TestServer.WebSocket do
  @moduledoc """
  The `ws` package's `WebSocket` (RFC 6455 framing, no extensions, as `ws` with
  `perMessageDeflate: false`): the server socket of `PlaywrightEx.TestServer`, and the upgrade
  `socket` before it (`write/2`, `destroy/1`), both the pid of the Bandit connection process;
  or a client (`new/3`, ws:// only), a process linked to its caller.

  Listeners (`on/3`, `once/3`) run in that process: `:open` gets nothing, `:message` gets
  `data, is_binary` (upstream: a `Buffer`), `:close` gets `code, reason`, `:error` gets the
  error; a listener may take fewer arguments. A client holds back an event until a listener for
  it is set (Node: listeners set in the same tick as `new WebSocket()` get every event).
  """

  alias PlaywrightEx.TestServer

  @listeners {__MODULE__, :listeners}
  @held {__MODULE__, :held}
  # ws's closeTimeout
  @close_timeout 30_000

  @doc "`new WebSocket(address, protocols, options)`; options: `headers`."
  def new(address, protocols \\ [], options \\ %{}) do
    spawn_link(fn ->
      Process.put(@held, [])
      connect(URI.parse(address), List.wrap(protocols), options)
      closed()
    end)
  end

  # Holds on to the events of a closed client for listeners set later.
  defp closed do
    receive do
      {__MODULE__, :add_listener, listener, from, ref} ->
        add_listener(self(), listener)
        Kernel.send(from, {ref, :ok})
        closed()

      _message ->
        closed()
    end
  end

  @doc "A string is sent as a text frame, `{:binary, bytes}` as a binary frame."
  def send(ws, data) when is_binary(data) or (is_tuple(data) and elem(data, 0) == :binary),
    do: Kernel.send(ws, {__MODULE__, :send, data})

  @doc "Without `code`, the Close frame has no body (the peer sees 1005)."
  def close(ws, code \\ nil, reason \\ ""), do: Kernel.send(ws, {__MODULE__, :close, code, reason})

  def on(ws, event, listener) when event in [:open, :message, :close, :error],
    do: add_listener(ws, {event, listener, false})

  def once(ws, event, listener) when event in [:open, :message, :close, :error],
    do: add_listener(ws, {event, listener, true})

  @doc "Writes raw bytes to the TCP socket (upstream `socket.write`)."
  def write(socket, data), do: Kernel.send(socket, {__MODULE__, :write, data})

  @doc "Closes the TCP socket (upstream `socket.destroy`)."
  def destroy(socket), do: Kernel.send(socket, {__MODULE__, :destroy})

  defp add_listener(ws, {event, _, _} = listener) when ws == self() do
    Process.put(@listeners, (Process.get(@listeners) || []) ++ [listener])

    if held = Process.get(@held) do
      {now, later} = Enum.split_with(held, &(elem(&1, 0) == event))
      Process.put(@held, later)
      for {^event, args} <- now, do: emit(event, args)
    end

    :ok
  end

  # Synchronous from other processes, so that the listener is set before frames that follow.
  defp add_listener(ws, listener) do
    ref = Process.monitor(ws)
    Kernel.send(ws, {__MODULE__, :add_listener, listener, self(), ref})

    receive do
      {^ref, :ok} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, :process, _, _} -> nil
    end

    :ok
  end

  defp emit(event, args) do
    listeners = Process.get(@listeners) || []
    held = Process.get(@held)

    if held && not Enum.any?(listeners, &(elem(&1, 0) == event)) do
      Process.put(@held, held ++ [{event, args}])
    else
      Process.put(@listeners, Enum.reject(listeners, fn {e, _, once} -> e == event and once end))

      for {^event, listener, _} <- listeners do
        {:arity, arity} = Function.info(listener, :arity)
        apply(listener, Enum.take(args, arity))
      end
    end
  end

  # socket.destroy() in a plug: ends the request as a client closure (which Bandit does not log).
  @doc false
  @spec _destroy(ThousandIsland.Socket.t()) :: no_return()
  def _destroy(socket) do
    ThousandIsland.Socket.close(socket)
    raise Bandit.TransportError, message: "destroyed", error: :closed
  end

  # --- server -------------------------------------------------------------------

  # this._wsServer.handleUpgrade(request, socket, head, ws => this._wsServer.emit('connection', ws, request))
  @doc false
  @spec _handle_upgrade(TestServer.t(), Plug.Conn.t(), ThousandIsland.Socket.t()) :: no_return()
  def _handle_upgrade(%TestServer{pid: server_pid}, conn, socket) do
    [key] = Plug.Conn.get_req_header(conn, "sec-websocket-key")
    # `ws` accepts the first offered subprotocol (its default `handleProtocols`).
    protocol =
      conn
      |> Plug.Conn.get_req_header("sec-websocket-protocol")
      |> Enum.flat_map(&Plug.Conn.Utils.list/1)
      |> List.first()

    ThousandIsland.Socket.send(socket, [
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Accept: #{:cow_ws.encode_key(key)}\r\n",
      if(protocol, do: "Sec-WebSocket-Protocol: #{protocol}\r\n", else: []),
      "\r\n"
    ])

    state = new_state(socket.transport_module, socket.socket, false)
    # Next emit is only for our internal 'connection' listeners.
    {ref, listeners} = GenServer.call(server_pid, :ws_connection, :infinity)

    try do
      for listener <- listeners do
        if is_function(listener, 1), do: listener.(self()), else: listener.(self(), conn)
      end
    after
      GenServer.cast(server_pid, {:ws_connection_done, ref})
    end

    state |> activate() |> loop()
    _destroy(socket)
  end

  # --- client -------------------------------------------------------------------

  defp connect(%URI{scheme: "ws"} = uri, protocols, options) do
    key = :cow_ws.key()
    headers = Map.get(options, :headers, %{})

    {host, inet, authority} =
      case :inet.parse_ipv6strict_address(to_charlist(uri.host)) do
        {:ok, ip} -> {ip, [:inet6], "[#{uri.host}]:#{uri.port}"}
        {:error, _} -> {to_charlist(uri.host), [], "#{uri.host}:#{uri.port}"}
      end

    request = [
      "GET #{uri.path || "/"}#{if uri.query, do: "?" <> uri.query} HTTP/1.1\r\n",
      "Host: #{authority}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: #{key}\r\n",
      "Connection: Upgrade\r\nUpgrade: websocket\r\n",
      if(protocols != [], do: "Sec-WebSocket-Protocol: #{Enum.join(protocols, ",")}\r\n", else: []),
      for({name, value} <- headers, do: "#{name}: #{value}\r\n"),
      "\r\n"
    ]

    with {:ok, socket} <- :gen_tcp.connect(host, uri.port, [:binary, active: false] ++ inet),
         :ok <- :gen_tcp.send(socket, request),
         {:ok, rest} <- read_response(socket, "") do
      state = new_state(ThousandIsland.Transports.TCP, socket, true)
      emit(:open, [])
      state |> receive_data(rest) |> activate() |> loop()
    else
      {:error, error} ->
        emit(:error, [error])
        emit(:close, [1006, ""])
    end
  end

  defp read_response(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [<<"HTTP/1.1 101", _::binary>>, rest] ->
        {:ok, rest}

      [<<"HTTP/1.1 ", status::binary-3, _::binary>>, _] ->
        {:error, "Unexpected server response: #{status}"}

      [_] ->
        with {:ok, data} <- :gen_tcp.recv(socket, 0), do: read_response(socket, acc <> data)
    end
  end

  # --- connection ---------------------------------------------------------------

  defp new_state(transport, socket, mask) do
    %{
      transport: transport,
      socket: socket,
      mask: mask,
      buffer: "",
      frag_state: :undefined,
      utf8_state: 0,
      fragments: nil,
      close_frame_sent: false,
      close_frame_received: false,
      close_code: 1006,
      close_message: ""
    }
  end

  defp activate(state) do
    state.transport.setopts(state.socket, active: :once)
    state
  end

  defp loop(state) do
    socket = state.socket

    receive do
      {tag, ^socket, data} when tag in [:tcp, :ssl] ->
        state |> receive_data(state.buffer <> data) |> activate() |> loop()

      {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] ->
        emit_close(state)

      {tag, ^socket, _reason} when tag in [:tcp_error, :ssl_error] ->
        emit_close(state)

      {__MODULE__, :send, {:binary, data}} ->
        state |> send_frame({:binary, data}) |> loop()

      {__MODULE__, :send, data} ->
        state |> send_frame({:text, data}) |> loop()

      {__MODULE__, :close, code, reason} ->
        state |> do_close(code, reason) |> loop()

      {__MODULE__, :add_listener, listener, from, ref} ->
        add_listener(self(), listener)
        Kernel.send(from, {ref, :ok})
        loop(state)

      {__MODULE__, :write, data} ->
        state.transport.send(socket, data)
        loop(state)

      {__MODULE__, :destroy} ->
        emit_close(state)

      {__MODULE__, :close_timeout} ->
        emit_close(state)
    end
  end

  defp emit_close(state) do
    state.transport.close(state.socket)
    emit(:close, [state.close_code, state.close_message])
  end

  # Frames are parsed and built by cowlib's `cow_ws` (no extensions).
  defp receive_data(state, data) do
    with {type, frag_state, rsv, length, key, rest} when byte_size(rest) >= length <-
           :cow_ws.parse_header(data, %{}, state.frag_state),
         {:ok, code, payload, utf8_state, rest} <-
           parse_payload(rest, key, state.utf8_state, type, length, frag_state, rsv) do
      frame = :cow_ws.make_frame(type, payload, code, frag_state)
      frag_state = if match?({:fin, _, _}, frag_state), do: :undefined, else: frag_state

      %{state | frag_state: frag_state, utf8_state: utf8_state}
      |> handle_frame(frame)
      |> receive_data(rest)
    else
      :error -> protocol_error(state, :badframe)
      {:error, reason} -> protocol_error(state, reason)
      _more -> %{state | buffer: data}
    end
  end

  defp parse_payload(data, key, utf8_state, type, length, frag_state, rsv) do
    case :cow_ws.parse_payload(data, key, utf8_state, 0, type, length, frag_state, %{}, rsv) do
      {:ok, payload, utf8_state, rest} -> {:ok, :undefined, payload, utf8_state, rest}
      result -> result
    end
  end

  # receiverOnError: `ws` emits the error (once) and closes with 1002 (1007 for invalid UTF-8).
  defp protocol_error(state, reason) do
    if not state.close_frame_sent, do: emit(:error, [reason])
    do_close(%{state | buffer: ""}, if(reason == :badencoding, do: 1007, else: 1002), "")
  end

  # After a Close frame, `ws` reads no more data frames.
  defp handle_frame(%{close_frame_received: true} = state, _frame), do: state
  defp handle_frame(state, {type, data}) when type in [:text, :binary], do: message(state, type, data)

  defp handle_frame(state, {:fragment, :nofin, _type, data}),
    do: %{state | fragments: [state.fragments || [], data]}

  defp handle_frame(state, {:fragment, :fin, type, data}),
    do: message(%{state | fragments: nil}, type, [state.fragments || [], data])

  # receiverOnConclude: `ws` answers with the peer's code and reason.
  defp handle_frame(state, :close),
    do: do_close(%{state | close_frame_received: true, close_code: 1005}, nil, "")

  defp handle_frame(state, {:close, code, reason}),
    do: do_close(%{state | close_frame_received: true, close_code: code, close_message: reason}, code, reason)

  defp handle_frame(state, :ping), do: send_frame(state, :pong)
  defp handle_frame(state, {:ping, data}), do: send_frame(state, {:pong, data})
  defp handle_frame(state, _pong), do: state

  defp message(state, type, data) do
    emit(:message, [IO.iodata_to_binary(data), type == :binary])
    state
  end

  defp send_frame(%{close_frame_sent: true} = state, _frame), do: state

  defp send_frame(state, frame) do
    state.transport.send(
      state.socket,
      if(state.mask, do: :cow_ws.masked_frame(frame, %{}), else: :cow_ws.frame(frame, %{}))
    )

    state
  end

  # WebSocket.close: sends the Close frame once; ends the socket when both were exchanged.
  defp do_close(%{close_frame_sent: true} = state, _code, _reason) do
    if state.close_frame_received, do: state.transport.shutdown(state.socket, :write)
    state
  end

  defp do_close(state, code, reason) do
    state = send_frame(state, if(code, do: {:close, code, reason}, else: :close))
    if state.close_frame_received, do: state.transport.shutdown(state.socket, :write)
    Process.send_after(self(), {__MODULE__, :close_timeout}, @close_timeout)
    %{state | close_frame_sent: true}
  end
end
