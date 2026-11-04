defmodule PlaywrightEx.TestServer do
  @upstream "tests/config/testserver/index.ts"
  @moduledoc """
  Port of upstream `#{@upstream}` on Bandit.

  Deviations:

    * A route handler is `fn conn -> conn end` on a `Plug.Conn` (upstream: `(req, res)`), run
      in the request's process, with the request body read into `conn.assigns.post_body`.
      Response header names must be lowercase (Plug).
    * `wait_for_request/2` returns a `Task` resolving to that `Plug.Conn`.
    * The URL constants are snake_case fields: `server.prefix` is `PREFIX`, likewise `port`,
      `cross_process_prefix`, `empty_page`, `host`, `hostname`, `hello_world`.
    * Listens on an ephemeral port by default.
    * WebSocket: an upgrade request runs in its Bandit connection process, which is also its
      `ws` server socket once upgraded (Bandit + `WebSock`, upstream: the `ws` package). That
      pid is upstream's `ws` (`wait_for_web_socket/1`, `once_web_socket_connection/2`) and the
      `socket` of `wait_for_upgrade/1` (which resolves to `%{do_upgrade: fun/0, socket: pid}`),
      driven by `PlaywrightEx.TestServer.WebSocket`: `send/2` (a string is a text frame,
      `{:binary, bytes}` a binary one), `close/1..3`, `on/3`, `once/3`, `write/2`, `destroy/1`.
      Listeners run in that process. A `:message` listener gets the payload binary (upstream:
      a `Buffer`); a `:close` listener gets `code, reason`, `nil, ""` when the peer closed
      (Bandit does not expose the peer's Close frame, and answers it with code 1000 where `ws`
      echoes the peer's code). The `wait_for_*` functions return a `Task`.
  """
  use GenServer

  alias PlaywrightEx.TestServer

  defstruct [:pid, :port, :prefix, :cross_process_prefix, :empty_page, :host, :hostname, :hello_world]

  def create(dir_path, port \\ 0, loopback \\ nil), do: start!(dir_path: dir_path, port: port, loopback: loopback)

  def cert_options do
    dir = Path.join(PlaywrightEx.Upstream.ensure!(), "tests/config/testserver")

    [
      keyfile: to_charlist(Path.join(dir, "key.pem")),
      certfile: to_charlist(Path.join(dir, "cert.pem")),
      password: ~c"aaaa"
    ]
  end

  def create_https(dir_path, port \\ 0, loopback \\ nil),
    do: start!(dir_path: dir_path, port: port, loopback: loopback, ssl_options: cert_options())

  @doc "Options: `:dir_path`, `:port`, `:loopback`, `:ssl_options`, `:ip` (default `{127, 0, 0, 1}`). See `server/1`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The `%TestServer{}` of a started server."
  def server(pid), do: GenServer.call(pid, :server)

  defp start!(opts) do
    {:ok, pid} = start_link(opts)
    server(pid)
  end

  @impl true
  def init(opts) do
    ssl_options = opts[:ssl_options]

    {:ok, bandit} =
      Bandit.start_link(
        plug: {TestServer.Router, server: self()},
        scheme: if(ssl_options, do: :https, else: :http),
        ip: opts[:ip] || {127, 0, 0, 1},
        port: opts[:port] || 0,
        startup_log: false,
        # Node's http server does not compress responses (gzip only via enable_gzip/2).
        http_options: [compress: false],
        thousand_island_options: if(ssl_options, do: [transport_options: ssl_options], else: [])
      )

    # this._server.on('connection', socket => this._onSocket(socket));  -- not ported: Bandit handles socket errors
    # this._wsServer = new WebSocketServer({ noServer: true });  -- ported as TestServer.WebSocket
    # this._server.on('upgrade', ...)  -- ported as _on_upgrade/2 (Router dispatches upgrades)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    # this.debugServer = require('debug')('pw:testserver');  -- not ported

    cross_origin = opts[:loopback] || "127.0.0.1"
    same_origin = opts[:loopback] || "localhost"
    protocol = if ssl_options, do: "https", else: "http"
    empty_page = "#{protocol}://#{same_origin}:#{port}/empty.html"
    uri = URI.parse(empty_page)

    server = %TestServer{
      pid: self(),
      port: port,
      prefix: "#{protocol}://#{same_origin}:#{port}",
      cross_process_prefix: "#{protocol}://#{cross_origin}:#{port}",
      empty_page: empty_page,
      host: "#{uri.host}:#{uri.port}",
      hostname: uri.host,
      hello_world: "#{protocol}://#{same_origin}:#{port}/hello-world"
    }

    {:ok,
     %{
       server: server,
       dir_path: opts[:dir_path],
       start_time: DateTime.utc_now(),
       cached_path_prefix: nil,
       routes: %{},
       auths: %{},
       csp: %{},
       extra_headers: %{},
       gzip_routes: MapSet.new(),
       request_subscribers: %{},
       upgrade_callback: nil,
       # this._wsServer's 'connection' listeners (all `once`)
       ws_connection_listeners: [],
       # Node emits 'connection' events one at a time: a connection runs the listeners popped
       # here (monitor ref while it does), the next one waits in the queue.
       ws_connection: nil,
       ws_connection_queue: :queue.new()
     }}
  end

  # waitUntilReady  -- ported as create/3 (Bandit listens once started)
  # _onSocket  -- not ported: Bandit handles socket errors

  def enable_http_cache(%TestServer{pid: pid}, path_prefix),
    do: GenServer.call(pid, {:put, :cached_path_prefix, path_prefix})

  def set_auth(%TestServer{pid: pid}, path, username, password),
    do: GenServer.call(pid, {:map_put, :auths, path, %{username: username, password: password}})

  def enable_gzip(%TestServer{pid: pid}, path), do: GenServer.call(pid, {:gzip, path})

  def set_csp(%TestServer{pid: pid}, path, csp), do: GenServer.call(pid, {:map_put, :csp, path, csp})

  def set_extra_headers(%TestServer{pid: pid}, path, object),
    do: GenServer.call(pid, {:map_put, :extra_headers, path, object})

  def stop(%TestServer{pid: pid} = this) do
    reset(this)
    GenServer.stop(pid)
  end

  def set_content(this, path, content, mime_type) do
    set_route(this, path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", mime_type)
      |> Plug.Conn.send_resp(200, if(mime_type == "text/html", do: "<!DOCTYPE html>#{content}", else: content))
    end)
  end

  def set_route(%TestServer{pid: pid}, path, handler) when is_function(handler, 1),
    do: GenServer.call(pid, {:map_put, :routes, path, handler})

  def set_redirect(this, from, to) do
    set_route(this, from, fn conn ->
      headers = settings(this).extra_headers[path_with_search(conn)] || %{}

      headers
      |> Enum.reduce(conn, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, header_name(name), value) end)
      |> Plug.Conn.put_resp_header("location", to)
      |> Plug.Conn.send_resp(302, "")
    end)
  end

  def wait_for_request(%TestServer{pid: pid}, path) do
    task =
      Task.async(fn ->
        receive do
          {:request, conn} -> conn
          {:reject, message} -> exit({:shutdown, message})
        end
      end)

    GenServer.call(pid, {:subscribe, path, task.pid})
    task
  end

  def reset(%TestServer{pid: pid}), do: GenServer.call(pid, :reset)

  @doc false
  def _on_request(this, conn) do
    # request.on('error', ...)  -- not ported: Bandit handles connection errors
    conn = read_post_body(conn)
    path_with_search = path_with_search(conn)
    auth = settings(this).auths[path_with_search]

    credentials =
      with ["Basic " <> encoded | _] <- Plug.Conn.get_req_header(conn, "authorization"),
           {:ok, decoded} <- Base.decode64(encoded),
           do: decoded,
           else: (_ -> "")

    if auth && credentials != "#{auth.username}:#{auth.password}" do
      conn
      |> Plug.Conn.put_resp_header("www-authenticate", ~s(Basic realm="Secure Area"))
      |> Plug.Conn.send_resp(401, "HTTP Error 401 Unauthorized: Access is denied")
    else
      # Notify request subscriber.
      handler = GenServer.call(this.pid, {:on_request, path_with_search, conn})

      if handler,
        do: handler.(conn),
        else: serve_file(this, conn)
    end
  end

  # this._server.on('upgrade', async (request, socket, head) => ...)
  @doc false
  def _on_upgrade(this, conn) do
    socket = raw_socket(conn)

    if upgrade_callback = settings(this).upgrade_callback do
      ws = self()

      send(
        upgrade_callback,
        {:upgrade, %{do_upgrade: fn -> send(ws, {TestServer.WebSocket, :do_upgrade}) end, socket: ws}}
      )

      await_upgrade_actions(this, conn, socket)
    else
      case conn.request_path do
        "/ws-401" ->
          ThousandIsland.Socket.send(socket, "HTTP/1.1 401 Unauthorized\r\n\r\nUnauthorized body")
          TestServer.WebSocket._destroy(socket)

        path_name ->
          if path_name == "/ws-slow", do: Process.sleep(2000)

          if path_name in ["/ws", "/ws-slow"] do
            do_upgrade(this, conn, socket)
          else
            ThousandIsland.Socket.send(socket, "HTTP/1.1 400 Bad Request\r\n\r\n")
            TestServer.WebSocket._destroy(socket)
          end
      end
    end
  end

  # The upgrade socket's `write`/`destroy` before `doUpgrade()` is called.
  defp await_upgrade_actions(this, conn, socket) do
    receive do
      {TestServer.WebSocket, :do_upgrade} ->
        do_upgrade(this, conn, socket)

      {TestServer.WebSocket, :write, data} ->
        ThousandIsland.Socket.send(socket, data)
        await_upgrade_actions(this, conn, socket)

      {TestServer.WebSocket, :destroy} ->
        TestServer.WebSocket._destroy(socket)
    end
  end

  # this._wsServer.handleUpgrade(request, socket, head, ws => this._wsServer.emit('connection', ws, request))
  defp do_upgrade(this, conn, socket) do
    # `ws` accepts the first offered subprotocol (its default `handleProtocols`).
    conn =
      case conn |> Plug.Conn.get_req_header("sec-websocket-protocol") |> Enum.flat_map(&Plug.Conn.Utils.list/1) do
        [protocol | _] -> Plug.Conn.put_resp_header(conn, "sec-websocket-protocol", protocol)
        [] -> conn
      end

    Plug.Conn.upgrade_adapter(conn, :websocket, {TestServer.WebSocket, %{server: this, conn: conn, socket: socket}, []})
  end

  defp raw_socket(%Plug.Conn{adapter: {Bandit.Adapter, %{transport: %{socket: socket}}}}), do: socket

  def serve_file(this, conn, file_path \\ nil), do: _serve_file(this, conn, file_path)

  defp _serve_file(this, conn, file_path) do
    settings = settings(this)
    path_name = if conn.request_path == "/", do: "/index.html", else: conn.request_path
    file_path = file_path || Path.join(settings.dir_path, String.slice(path_name, 1..-1//1))
    cached = settings.cached_path_prefix != nil and String.starts_with?(file_path, settings.cached_path_prefix)

    if cached and Plug.Conn.get_req_header(conn, "if-modified-since") != [] do
      # not modified
      Plug.Conn.send_resp(conn, 304, "")
    else
      conn =
        if cached do
          conn
          |> Plug.Conn.put_resp_header("cache-control", "public, max-age=31536000, no-cache")
          |> Plug.Conn.put_resp_header("last-modified", DateTime.to_iso8601(settings.start_time))
        else
          Plug.Conn.put_resp_header(conn, "cache-control", "no-cache, no-store")
        end

      conn =
        if csp = settings.csp[path_name],
          do: Plug.Conn.put_resp_header(conn, "content-security-policy", csp),
          else: conn

      conn =
        Enum.reduce(settings.extra_headers[path_name] || %{}, conn, fn {key, value}, conn ->
          Plug.Conn.put_resp_header(conn, header_name(key), value)
        end)

      case File.read(file_path) do
        {:error, _} ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.send_resp(404, if(conn.method != "HEAD", do: "File not found: #{file_path}", else: ""))

        {:ok, data} ->
          mime_type = MIME.from_path(file_path)
          is_text_encoding = Regex.match?(~r/^text\/|^application\/(javascript|json)/, mime_type)
          content_type = if is_text_encoding, do: "#{mime_type}; charset=utf-8", else: mime_type
          conn = Plug.Conn.put_resp_header(conn, "content-type", content_type)

          if MapSet.member?(settings.gzip_routes, path_name) do
            conn
            |> Plug.Conn.put_resp_header("content-encoding", "gzip")
            |> Plug.Conn.send_resp(200, if(conn.method != "HEAD", do: :zlib.gzip(data), else: ""))
          else
            Plug.Conn.send_resp(conn, 200, if(conn.method != "HEAD", do: data, else: ""))
          end
      end
    end
  end

  @doc "`handler` is `fn ws -> ... end` or `fn ws, conn -> ... end`, run in the `ws` process."
  def once_web_socket_connection(%TestServer{pid: pid}, handler)
      when is_function(handler, 1) or is_function(handler, 2),
      do: GenServer.call(pid, {:once_ws_connection, handler})

  @doc "A `Task` resolving to the upgrade request's `Plug.Conn`."
  def wait_for_web_socket_connection_request(this) do
    task = Task.async(fn -> receive do: ({:ws_connection, _ws, conn} -> conn) end)
    once_web_socket_connection(this, fn ws, conn -> send(task.pid, {:ws_connection, ws, conn}) end)
    task
  end

  @doc "A `Task` resolving to `%{do_upgrade: fun/0, socket: pid}`."
  def wait_for_upgrade(%TestServer{pid: pid}) do
    task = Task.async(fn -> receive do: ({:upgrade, actions} -> actions) end)
    GenServer.call(pid, {:put, :upgrade_callback, task.pid})
    task
  end

  @doc "A `Task` resolving to the `ws` server socket (a pid, see `PlaywrightEx.TestServer.WebSocket`)."
  def wait_for_web_socket(this) do
    task = Task.async(fn -> receive do: ({:ws_connection, ws, _conn} -> ws) end)
    once_web_socket_connection(this, fn ws, conn -> send(task.pid, {:ws_connection, ws, conn}) end)
    task
  end

  def send_on_web_socket_connection(this, data),
    do: once_web_socket_connection(this, fn ws -> TestServer.WebSocket.send(ws, data) end)

  # --- server state ------------------------------------------------------------

  defp settings(%TestServer{pid: pid}), do: GenServer.call(pid, :settings)

  @impl true
  def handle_call(:server, _from, state), do: {:reply, state.server, state}
  def handle_call(:settings, _from, state), do: {:reply, state, state}
  def handle_call({:put, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}
  def handle_call({:map_put, key, k, v}, _from, state), do: {:reply, :ok, Map.update!(state, key, &Map.put(&1, k, v))}

  def handle_call({:gzip, path}, _from, state),
    do: {:reply, :ok, Map.update!(state, :gzip_routes, &MapSet.put(&1, path))}

  def handle_call({:subscribe, path, pid}, _from, state),
    do: {:reply, :ok, update_in(state.request_subscribers[path], &[pid | &1 || []])}

  def handle_call({:on_request, path_with_search, conn}, _from, state) do
    {subscribers, request_subscribers} = Map.pop(state.request_subscribers, path_with_search, [])
    for pid <- subscribers, do: send(pid, {:request, conn})
    {:reply, state.routes[path_with_search], %{state | request_subscribers: request_subscribers}}
  end

  def handle_call({:once_ws_connection, handler}, _from, state),
    do: {:reply, :ok, update_in(state.ws_connection_listeners, &(&1 ++ [handler]))}

  def handle_call(:ws_connection, from, %{ws_connection: nil} = state), do: {:noreply, start_ws_connection(from, state)}

  def handle_call(:ws_connection, from, state),
    do: {:noreply, update_in(state.ws_connection_queue, &:queue.in(from, &1))}

  def handle_call(:reset, _from, state) do
    # this._server.closeAllConnections();  -- not ported: requests end with their handler
    for {path, pids} <- state.request_subscribers,
        pid <- pids,
        do: send(pid, {:reject, "Request #{path} was not received before the test finished."})

    {:reply, :ok,
     %{
       state
       | routes: %{},
         auths: %{},
         csp: %{},
         extra_headers: %{},
         gzip_routes: MapSet.new(),
         request_subscribers: %{},
         upgrade_callback: nil,
         ws_connection_listeners: []
     }}
  end

  @impl true
  def handle_cast({:ws_connection_done, ref}, %{ws_connection: ref} = state), do: {:noreply, next_ws_connection(state)}
  def handle_cast({:ws_connection_done, _ref}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ws_connection: ref} = state),
    do: {:noreply, next_ws_connection(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp start_ws_connection({pid, _} = from, state) do
    ref = Process.monitor(pid)
    GenServer.reply(from, {ref, state.ws_connection_listeners})
    %{state | ws_connection_listeners: [], ws_connection: ref}
  end

  defp next_ws_connection(state) do
    Process.demonitor(state.ws_connection, [:flush])

    case :queue.out(state.ws_connection_queue) do
      {{:value, from}, queue} -> start_ws_connection(from, %{state | ws_connection_queue: queue})
      {:empty, _} -> %{state | ws_connection: nil}
    end
  end

  defp read_post_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> Plug.Conn.assign(conn, :post_body, IO.iodata_to_binary([acc, body]))
      {:more, body, conn} -> read_post_body(conn, [acc, body])
    end
  end

  defp path_with_search(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp path_with_search(%Plug.Conn{request_path: path, query_string: query}), do: "#{path}?#{query}"

  defp header_name(name), do: name |> to_string() |> String.downcase()

  defmodule Router do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: Keyword.fetch!(opts, :server)

    @impl true
    def call(conn, server_pid) do
      # Node emits 'upgrade' instead of 'request' for upgrade requests.
      if conn |> Plug.Conn.get_req_header("upgrade") |> Enum.any?(&(String.downcase(&1) == "websocket")),
        do: TestServer._on_upgrade(%TestServer{pid: server_pid}, conn),
        else: TestServer._on_request(%TestServer{pid: server_pid}, conn)
    end
  end

  defmodule WebSocket do
    @moduledoc """
    The `ws` server socket of `PlaywrightEx.TestServer` (upstream: a `ws` package `WebSocket`),
    and the upgrade `socket` before it (`write/2`, `destroy/1`): the pid of the connection
    process. Listeners (`on/3`, `once/3`) run in it; `:message` gets the payload, `:close` gets
    `code, reason`; a listener may take fewer arguments.
    """
    @behaviour WebSock

    alias PlaywrightEx.TestServer

    @listeners {__MODULE__, :listeners}

    @doc "A string is sent as a text frame, `{:binary, bytes}` as a binary frame."
    def send(ws, data) when is_binary(data) or (is_tuple(data) and elem(data, 0) == :binary),
      do: Kernel.send(ws, {__MODULE__, :send, data})

    # ws.close() sends no status code; Bandit sends 1000.
    def close(ws, code \\ 1000, reason \\ ""), do: Kernel.send(ws, {__MODULE__, :close, code, reason})

    def on(ws, event, listener) when event in [:message, :close], do: add_listener(ws, {event, listener, false})
    def once(ws, event, listener) when event in [:message, :close], do: add_listener(ws, {event, listener, true})

    @doc "Writes raw bytes to the TCP socket (upstream `socket.write`)."
    def write(socket, data), do: Kernel.send(socket, {__MODULE__, :write, data})

    @doc "Closes the TCP socket (upstream `socket.destroy`)."
    def destroy(socket), do: Kernel.send(socket, {__MODULE__, :destroy})

    defp add_listener(ws, listener) when ws == self(),
      do: Process.put(@listeners, (Process.get(@listeners) || []) ++ [listener])

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
      Process.put(@listeners, Enum.reject(listeners, fn {e, _, once} -> e == event and once end))

      for {^event, listener, _} <- listeners do
        {:arity, arity} = Function.info(listener, :arity)
        apply(listener, Enum.take(args, arity))
      end
    end

    # socket.destroy() in a plug: ends the request as a client closure (which Bandit does not log).
    @doc false
    def _destroy(socket) do
      ThousandIsland.Socket.close(socket)
      raise Bandit.TransportError, message: "destroyed", error: :closed
    end

    @impl WebSock
    def init(%{server: %TestServer{pid: server_pid}, conn: conn, socket: socket}) do
      # Next emit is only for our internal 'connection' listeners.
      {ref, listeners} = GenServer.call(server_pid, :ws_connection, :infinity)

      try do
        for listener <- listeners do
          if is_function(listener, 1), do: listener.(self()), else: listener.(self(), conn)
        end
      after
        GenServer.cast(server_pid, {:ws_connection_done, ref})
      end

      {:ok, %{socket: socket, close: {nil, ""}}}
    end

    @impl WebSock
    def handle_in({data, opcode: _opcode}, state) do
      emit(:message, [data])
      {:ok, state}
    end

    @impl WebSock
    def handle_info({__MODULE__, :send, {:binary, data}}, state), do: {:push, {:binary, data}, state}
    def handle_info({__MODULE__, :send, data}, state), do: {:push, {:text, data}, state}

    def handle_info({__MODULE__, :close, code, reason}, state),
      do: {:stop, :normal, {code, reason}, %{state | close: {code, reason}}}

    def handle_info({__MODULE__, :add_listener, listener, from, ref}, state) do
      add_listener(self(), listener)
      Kernel.send(from, {ref, :ok})
      {:ok, state}
    end

    def handle_info({__MODULE__, :write, data}, state) do
      ThousandIsland.Socket.send(state.socket, data)
      {:ok, state}
    end

    def handle_info({__MODULE__, :destroy}, state) do
      ThousandIsland.Socket.close(state.socket)
      {:stop, :normal, state}
    end

    def handle_info(_message, state), do: {:ok, state}

    @impl WebSock
    def terminate(_reason, %{close: {code, reason}}), do: emit(:close, [code, reason])
  end
end
