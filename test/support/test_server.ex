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
    * Listens on `127.0.0.1` and `[::1]` (one port), upstream on all interfaces: clients try
      `localhost` as `[::1]` first, and on Linux a `127.0.0.1` listener's port is free on `[::1]`,
      where another server would take those connections. `ip:` listens on that address only.
    * Responses to HTTP/1.1 requests get Node's `Connection: keep-alive` and
      `Keep-Alive: timeout=5` (Bandit sends neither). `send_resp/4` sends a custom status message.
    * WebSocket: an upgrade request runs in its Bandit connection process, which is also its
      `ws` server socket once upgraded (`PlaywrightEx.TestServer.WebSocket`, upstream: the `ws`
      package). That pid is upstream's `ws` (`wait_for_web_socket/1`,
      `once_web_socket_connection/2`) and the `socket` of `wait_for_upgrade/1` (which resolves to
      `%{do_upgrade: fun/0, socket: pid}`). The `wait_for_*` functions return a `Task`.
  """
  use GenServer

  alias PlaywrightEx.TestServer

  defstruct [:pid, :port, :prefix, :cross_process_prefix, :empty_page, :host, :hostname, :hello_world]
  @type t :: %__MODULE__{}

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

    # this._server.on('connection', socket => this._onSocket(socket));  -- not ported: Bandit handles socket errors
    # this._wsServer = new WebSocketServer({ noServer: true });  -- ported as TestServer.WebSocket
    # this._server.on('upgrade', ...)  -- ported as _on_upgrade/2 (Router dispatches upgrades)
    port = listen(opts, 10)
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
       ws_connection_queue: :queue.new(),
       # Elixir only: the HTTP/1 connections (Bandit connection process => socket) that
       # `this._server.closeAllConnections()` closes; upgraded ones leave (Node detaches them).
       connections: %{}
     }}
  end

  # Listens on `opts[:ip]`, else on both loopback addresses at one port, and returns the port.
  defp listen(opts, attempts) do
    {:ok, bandit} = start_bandit(opts, opts[:ip] || {127, 0, 0, 1}, opts[:port] || 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    retry? = attempts > 1 and opts[:port] in [nil, 0]

    case if(opts[:ip], do: :skip, else: start_bandit(opts, {0, 0, 0, 0, 0, 0, 0, 1}, port)) do
      {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}}
      when retry? ->
        ThousandIsland.stop(bandit)
        listen(opts, attempts - 1)

      # :skip, {:ok, _}, or no IPv6 loopback (e.g. a container without IPv6)
      _ ->
        port
    end
  end

  defp start_bandit(opts, ip, port) do
    ssl_options = opts[:ssl_options]
    # A listener that fails to start exits its caller; trapping turns that into an error.
    trap_exit = Process.flag(:trap_exit, true)

    try do
      Bandit.start_link(
        plug: {TestServer.Router, server: self()},
        scheme: if(ssl_options, do: :https, else: :http),
        ip: ip,
        port: port,
        startup_log: false,
        # Node's http server does not compress responses (gzip only via enable_gzip/2).
        http_options: [compress: false],
        # Node's https server (`createHttpsServer`) speaks HTTP/1.1 only; Bandit offers h2 over TLS.
        http_2_options: [enabled: false],
        thousand_island_options: if(ssl_options, do: [transport_options: ssl_options], else: [])
      )
    after
      Process.flag(:trap_exit, trap_exit)
    end
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

    # Buffer.from((request.headers.authorization || '').split(' ')[1] || '', 'base64'): any
    # scheme; Node skips characters outside the alphabet and missing padding.
    authorization = conn |> Plug.Conn.get_req_header("authorization") |> List.first("")
    encoded = authorization |> String.split(" ") |> Enum.at(1, "") |> String.replace(~r/[^A-Za-z0-9+\/]/, "")
    # A lone trailing character holds no full byte.
    encoded = if rem(byte_size(encoded), 4) == 1, do: binary_part(encoded, 0, byte_size(encoded) - 1), else: encoded
    credentials = Base.decode64!(encoded, padding: false)

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
    GenServer.cast(this.pid, {:upgraded, self()})

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
  @spec do_upgrade(%__MODULE__{}, Plug.Conn.t(), ThousandIsland.Socket.t()) :: no_return()
  defp do_upgrade(this, conn, socket), do: TestServer.WebSocket._handle_upgrade(this, conn, socket)

  @doc """
  `res.writeHead(status, statusMessage); res.end(body)`: Bandit sends no custom status message,
  so this writes the response to the socket and closes the connection.
  """
  @spec send_resp(Plug.Conn.t(), non_neg_integer(), String.t()) :: no_return()
  @spec send_resp(Plug.Conn.t(), non_neg_integer(), String.t(), iodata()) :: no_return()
  def send_resp(conn, status, status_message, body \\ "") do
    socket = raw_socket(conn)
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
    # Plug's default `cache-control` (Node sends none)
    headers = conn.resp_headers -- [{"cache-control", "max-age=0, private, must-revalidate"}]

    ThousandIsland.Socket.send(socket, [
      "HTTP/1.1 #{status} #{status_message}\r\n",
      for({name, value} <- headers, do: "#{name}: #{value}\r\n"),
      "date: #{date}\r\nconnection: close\r\ncontent-length: #{byte_size(body)}\r\n\r\n",
      body
    ])

    ThousandIsland.Socket.shutdown(socket, :write)
    TestServer.WebSocket._destroy(socket)
  end

  defp raw_socket(%Plug.Conn{adapter: {Bandit.Adapter, %{transport: %{socket: socket}}}}), do: socket

  @doc false
  # Elixir only: tracks the request's HTTP/1 connection for `reset/1` (`closeAllConnections()`).
  def _on_connection(%TestServer{pid: pid}, conn) do
    with %Plug.Conn{adapter: {Bandit.Adapter, %{transport: %{socket: socket}}}} <- conn,
         do: GenServer.cast(pid, {:connection, self(), socket})
  end

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
          |> Plug.Conn.put_resp_header(
            "last-modified",
            DateTime.to_iso8601(DateTime.truncate(settings.start_time, :millisecond))
          )
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
    # this._server.closeAllConnections();
    for {_pid, socket} <- state.connections, do: ThousandIsland.Socket.close(socket)

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
         ws_connection_listeners: [],
         connections: %{}
     }}
  end

  @impl true
  def handle_cast({:ws_connection_done, ref}, %{ws_connection: ref} = state), do: {:noreply, next_ws_connection(state)}
  def handle_cast({:ws_connection_done, _ref}, state), do: {:noreply, state}

  def handle_cast({:connection, pid, socket}, state) do
    if !Map.has_key?(state.connections, pid), do: Process.monitor(pid)
    {:noreply, put_in(state.connections[pid], socket)}
  end

  def handle_cast({:upgraded, pid}, state), do: {:noreply, %{state | connections: Map.delete(state.connections, pid)}}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ws_connection: ref} = state),
    do: {:noreply, next_ws_connection(state)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | connections: Map.delete(state.connections, pid)}}

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
        else: on_request(%TestServer{pid: server_pid}, conn)
    end

    defp on_request(server, conn) do
      TestServer._on_connection(server, conn)
      TestServer._on_request(server, Plug.Conn.register_before_send(conn, &keep_alive/1))
    end

    # Node's http server on a persistent connection (Bandit closes it on `connection: close`).
    defp keep_alive(conn) do
      if Plug.Conn.get_http_protocol(conn) == :"HTTP/1.1" and Plug.Conn.get_resp_header(conn, "connection") == [] and
           not Enum.any?(Plug.Conn.get_req_header(conn, "connection"), &(String.downcase(&1) =~ "close")),
         do:
           conn
           |> Plug.Conn.put_resp_header("connection", "keep-alive")
           |> Plug.Conn.put_resp_header("keep-alive", "timeout=5"),
         else: conn
    end
  end
end
