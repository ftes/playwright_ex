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
        thousand_island_options: if(ssl_options, do: [transport_options: ssl_options], else: [])
      )

    # this._server.on('connection', socket => this._onSocket(socket));  -- not ported: Bandit handles socket errors
    # this._wsServer = ...; this._server.on('upgrade', ...)  -- not ported: WebSocket
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
       request_subscribers: %{}
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

  # onceWebSocketConnection, waitForWebSocketConnectionRequest  -- not ported: WebSocket
  # waitForUpgrade, waitForWebSocket, sendOnWebSocketConnection  -- not ported: WebSocket

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

  def handle_call(:reset, _from, state) do
    # this._upgradeCallback = undefined; this._wsServer.removeAllListeners('connection');  -- not ported: WebSocket
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
         request_subscribers: %{}
     }}
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
    def call(conn, server_pid), do: TestServer._on_request(%TestServer{pid: server_pid}, conn)
  end
end
