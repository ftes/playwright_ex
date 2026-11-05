defmodule PlaywrightEx.TestProxy do
  @upstream "tests/config/proxy.ts"
  @moduledoc """
  Port of upstream `#{@upstream}` (`TestProxy`, `setupSocksForwardingServer`) and of
  `MockSocksServer` (`tests/config/serverFixtures.ts`), on raw `:gen_tcp` sockets.

  Deviations:

    * Upstream wraps the `proxy` npm package (not vendored); this is a minimal HTTP/1.1 forward
      proxy with its behavior: plain requests with an absolute URL are forwarded (hop-by-hop
      headers dropped, one request per connection), `CONNECT` opens a tunnel, upgrade requests
      are forwarded and piped. A failing auth handler answers 407 and closes the socket.
    * The mutable arrays are read with `connect_hosts/1`, `request_urls/1`, `request_hosts/1`,
      `ws_urls/1`; `proxyServer.connectHosts = []` is `clear_connect_hosts/1`.
    * The auth handler gets `%{method:, url:, headers:}` (lowercase header names) and runs in the
      connection's process.
    * The fixtures listen on ephemeral ports: `setup {PlaywrightEx.TestProxy, :proxy_server}`
      gives `proxy_server`, `setup {PlaywrightEx.TestProxy, :socks_port}` gives `socks_port`
      (both stopped after the test). `setup_socks_forwarding_server/1` ignores `:port`.
  """
  use GenServer

  defstruct [:pid, :port, :url, :host]

  # Certain browsers perform telemetry requests which we want to ignore.
  @connect_hosts_to_ignore MapSet.new(["www.bing.com:443", "www.google.com:443"])

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization proxy-connection te trailers upgrade)

  # --- fixtures ------------------------------------------------------------------

  def proxy_server(_context) do
    pid = ExUnit.Callbacks.start_supervised!({__MODULE__, []}, id: __MODULE__)
    %{proxy_server: GenServer.call(pid, :server)}
  end

  def socks_port(_context) do
    pid = ExUnit.Callbacks.start_supervised!({__MODULE__.Socks, handler: &mock_socks_handler/3}, id: :socks_server)
    %{socks_port: __MODULE__.Socks.port(pid)}
  end

  # --- TestProxy -----------------------------------------------------------------

  def create(port \\ 0) do
    {:ok, pid} = start_link(port: port)
    GenServer.call(pid, :server)
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def stop(%__MODULE__{pid: pid}), do: GenServer.stop(pid)

  def forward_to(%__MODULE__{pid: pid}, port, options \\ []),
    do: GenServer.call(pid, {:put, :forward_to, Map.put(Map.new(options), :port, port)})

  def set_auth_handler(%__MODULE__{pid: pid}, handler) when is_function(handler, 1),
    do: GenServer.call(pid, {:put, :authenticate, handler})

  def reset(%__MODULE__{pid: pid}), do: GenServer.call(pid, :reset)

  def connect_hosts(%__MODULE__{pid: pid}), do: GenServer.call(pid, {:get, :connect_hosts})
  def request_urls(%__MODULE__{pid: pid}), do: GenServer.call(pid, {:get, :request_urls})
  def request_hosts(%__MODULE__{pid: pid}), do: GenServer.call(pid, {:get, :request_hosts})
  def ws_urls(%__MODULE__{pid: pid}), do: GenServer.call(pid, {:get, :ws_urls})
  def clear_connect_hosts(%__MODULE__{pid: pid}), do: GenServer.call(pid, {:put, :connect_hosts, []})

  @impl true
  def init(opts) do
    {:ok, listen} =
      :gen_tcp.listen(opts[:port] || 0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    url = "http://localhost:#{port}"
    server = %__MODULE__{pid: self(), port: port, url: url, host: "localhost:#{port}"}
    spawn_link(fn -> accept_loop(listen, &handle_connection(server, &1)) end)

    {:ok,
     %{
       server: server,
       listen: listen,
       connect_hosts: [],
       request_urls: [],
       request_hosts: [],
       ws_urls: [],
       forward_to: nil,
       authenticate: nil
     }}
  end

  @impl true
  def handle_call(:server, _from, state), do: {:reply, state.server, state}
  def handle_call(:config, _from, state), do: {:reply, Map.take(state, [:forward_to, :authenticate]), state}
  def handle_call({:get, key}, _from, state), do: {:reply, Map.fetch!(state, key), state}
  def handle_call({:put, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}
  def handle_call({:push, key, value}, _from, state), do: {:reply, :ok, Map.update!(state, key, &(&1 ++ [value]))}

  def handle_call(:reset, _from, state),
    do:
      {:reply, :ok,
       %{state | connect_hosts: [], request_urls: [], request_hosts: [], forward_to: nil, authenticate: nil}}

  @impl true
  def terminate(_reason, state), do: :gen_tcp.close(state.listen)

  @doc false
  def accept_loop(listen, handler) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> receive(do: (:go -> handler.(socket))) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept_loop(listen, handler)

      {:error, _} ->
        :ok
    end
  end

  defp handle_connection(%__MODULE__{pid: pid}, socket) do
    with {:ok, req, rest} <- read_head(socket, "") do
      config = GenServer.call(pid, :config)

      cond do
        req.method == "CONNECT" -> on_connect(pid, config, socket, req, rest)
        String.downcase(req.headers["upgrade"] || "") == "websocket" -> on_upgrade(pid, config, socket, req, rest)
        true -> on_request(pid, config, socket, req, rest)
      end
    end

    :gen_tcp.close(socket)
  end

  # this._prependHandler('request', ...), then the proxy's own request handler
  defp on_request(pid, config, socket, req, rest) do
    req =
      if forward = config.forward_to do
        GenServer.call(pid, {:push, :request_urls, req.url})
        GenServer.call(pid, {:push, :request_hosts, req.headers["host"]})
        %{req | url: rewrite_url(req, forward)}
      else
        req
      end

    if authenticated?(config, req), do: forward_request(socket, req, rest), else: send_407(socket)
  end

  # this._prependHandler('connect', ...), then the proxy's own connect handler
  defp on_connect(pid, config, socket, req, rest) do
    forward = config.forward_to

    req =
      if forward && forward[:allow_connect_requests] && not MapSet.member?(@connect_hosts_to_ignore, req.url) do
        GenServer.call(pid, {:push, :connect_hosts, req.url})
        %{req | url: "127.0.0.1:#{forward.port}"}
      else
        req
      end

    if authenticated?(config, req), do: tunnel(socket, req, rest), else: send_407(socket)
  end

  defp tunnel(socket, req, rest) do
    [host, port] = String.split(req.url, ":", parts: 2)

    case :gen_tcp.connect(to_charlist(host), String.to_integer(port), [:binary, active: false], 5000) do
      {:ok, target} ->
        :gen_tcp.send(socket, "HTTP/1.1 200 Connection established\r\n\r\n")
        if rest != "", do: :gen_tcp.send(target, rest)
        pipe(socket, target)

      {:error, _} ->
        :gen_tcp.send(socket, "HTTP/1.1 500 Connection error\r\n\r\n")
    end
  end

  # this._prependHandler('upgrade', ...), then the proxy's own upgrade handler
  defp on_upgrade(pid, config, socket, req, rest) do
    req =
      if forward = config.forward_to do
        GenServer.call(pid, {:push, :ws_urls, req.url})
        url = req |> rewrite_url(forward) |> String.replace(~r/^ws:/, "http:") |> String.replace(~r/^wss:/, "https:")
        %{req | url: url}
      else
        req
      end

    if authenticated?(config, req), do: forward_request(socket, req, rest, true), else: send_407(socket)
  end

  defp rewrite_url(req, forward) do
    uri = URI.parse(req.url)
    base = URI.parse("http://#{req.headers["host"]}")
    uri = if uri.host, do: uri, else: %{base | path: uri.path, query: uri.query}

    uri =
      if forward[:preserve_hostname],
        do: %{uri | port: forward.port},
        else: %{uri | host: "127.0.0.1", port: forward.port}

    uri =
      if prefix = forward[:remove_prefix],
        do: %{uri | path: String.replace(uri.path || "/", prefix, "", global: false)},
        else: uri

    URI.to_string(uri)
  end

  defp authenticated?(%{authenticate: nil}, _req), do: true

  defp authenticated?(%{authenticate: handler}, req) do
    handler.(req) == true
  rescue
    _ -> false
  end

  defp send_407(socket) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"proxy\"\r\n" <>
        "Content-Length: 0\r\nConnection: close\r\n\r\n"
    )
  end

  defp forward_request(socket, req, rest, upgrade? \\ false) do
    uri = URI.parse(req.url)
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)

    case :gen_tcp.connect(to_charlist(uri.host || ""), port, [:binary, active: false], 5000) do
      {:ok, target} ->
        path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

        headers = forwarded_headers(req.raw_headers, upgrade?)

        head = [
          req.method,
          " ",
          path,
          " HTTP/1.1\r\n",
          Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
          "\r\n"
        ]

        :gen_tcp.send(target, [head, rest])
        pipe(socket, target)

      {:error, _} ->
        :gen_tcp.send(socket, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    end
  end

  # Upgrade requests keep `Connection`/`Upgrade`; plain requests are one per connection.
  defp forwarded_headers(headers, true),
    do: Enum.reject(headers, fn {name, _} -> String.downcase(name) in ~w(proxy-authorization proxy-connection) end)

  defp forwarded_headers(headers, false),
    do: Enum.reject(headers, fn {name, _} -> String.downcase(name) in @hop_by_hop end) ++ [{"Connection", "close"}]

  # _prependHandler  -- not ported: forward_to/3 options are read by each connection
  # _onSocket  -- not ported: connection processes own their sockets

  # --- sockets -------------------------------------------------------------------

  @doc false
  def read_head(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, url | _] = String.split(request_line, " ")

        raw_headers =
          for line <- header_lines, [name, value] <- [String.split(line, ":", parts: 2)], do: {name, String.trim(value)}

        headers = Map.new(raw_headers, fn {name, value} -> {String.downcase(name), value} end)
        {:ok, %{method: method, url: url, headers: headers, raw_headers: raw_headers}, rest}

      [_] ->
        case :gen_tcp.recv(socket, 0, 10_000) do
          {:ok, data} -> read_head(socket, acc <> data)
          {:error, _} = error -> error
        end
    end
  end

  @doc false
  def pipe(a, b) do
    :inet.setopts(a, active: :once)
    :inet.setopts(b, active: :once)
    pipe_loop(a, b)
  end

  defp pipe_loop(a, b) do
    receive do
      {:tcp, ^a, data} ->
        :gen_tcp.send(b, data)
        :inet.setopts(a, active: :once)
        pipe_loop(a, b)

      {:tcp, ^b, data} ->
        :gen_tcp.send(a, data)
        :inet.setopts(b, active: :once)
        pipe_loop(a, b)

      {:tcp_closed, _} ->
        :gen_tcp.close(a)
        :gen_tcp.close(b)

      {:tcp_error, _, _} ->
        :gen_tcp.close(a)
        :gen_tcp.close(b)
    end
  end

  # --- SOCKS ---------------------------------------------------------------------

  @doc """
  `setupSocksForwardingServer({ port, forwardPort, allowedTargetPort })`: returns
  `%{proxy_server_addr:, close_proxy_server: fun/0, connect_hosts: fun/0}` (`connect_hosts.()`
  reads upstream's `connectHosts` array).
  """
  def setup_socks_forwarding_server(opts) do
    forward_port = Keyword.fetch!(opts, :forward_port)
    allowed_target_port = Keyword.fetch!(opts, :allowed_target_port)
    {:ok, hosts} = Agent.start(fn -> [] end)

    handler = fn socket, host, port ->
      if host in ["127.0.0.1", "fake-localhost-127-0-0-1.nip.io", "localhost"] and port == allowed_target_port,
        do: socks_forward(socket, "#{host}:#{port}", forward_port, hosts),
        # ECONNREFUSED
        else: __MODULE__.Socks.reply(socket, 5)
    end

    {:ok, pid} = __MODULE__.Socks.start(handler: handler)

    %{
      close_proxy_server: fn ->
        GenServer.stop(pid)
        Agent.stop(hosts)
      end,
      proxy_server_addr: "socks5://127.0.0.1:#{__MODULE__.Socks.port(pid)}",
      connect_hosts: fn -> Agent.get(hosts, & &1) end
    }
  end

  defp socks_forward(socket, host, forward_port, hosts) do
    case :gen_tcp.connect(~c"127.0.0.1", forward_port, [:binary, active: false], 5000) do
      {:ok, target} ->
        Agent.update(hosts, &if(host in &1, do: &1, else: &1 ++ [host]))
        __MODULE__.Socks.reply(socket, 0)
        pipe(socket, target)

      {:error, _} ->
        __MODULE__.Socks.reply(socket, 5)
    end
  end

  # MockSocksServer: connects every request, answers any data with a canned page and ends.
  defp mock_socks_handler(socket, _host, _port) do
    __MODULE__.Socks.reply(socket, 0)

    with {:ok, _data} <- :gen_tcp.recv(socket, 0, 10_000) do
      body = "<html><title>Served by the SOCKS proxy</title></html>"

      data =
        Enum.join(
          [
            "HTTP/1.1 200 OK",
            "Connection: close",
            "Content-Type: text/html",
            "Content-Length: #{byte_size(body)}",
            "",
            body
          ],
          "\r\n"
        )

      :gen_tcp.send(socket, data)
    end
  end

  defmodule Socks do
    @moduledoc false
    # A SOCKS5 server (no auth, CONNECT only): `handler.(socket, host, port)` runs in the
    # connection's process after the handshake and must `reply/2`.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def start(opts), do: GenServer.start(__MODULE__, opts)
    def port(pid), do: GenServer.call(pid, :port)

    def reply(socket, code), do: :gen_tcp.send(socket, <<5, code, 0, 1, 127, 0, 0, 1, 0::16>>)

    @impl true
    def init(opts) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      handler = Keyword.fetch!(opts, :handler)

      spawn_link(fn ->
        PlaywrightEx.TestProxy.accept_loop(listen, fn socket ->
          try do
            with {:ok, host, port} <- handshake(socket), do: handler.(socket, host, port)
          after
            :gen_tcp.close(socket)
          end
        end)
      end)

      {:ok, %{listen: listen, port: port}}
    end

    @impl true
    def handle_call(:port, _from, state), do: {:reply, state.port, state}

    @impl true
    def terminate(_reason, state), do: :gen_tcp.close(state.listen)

    defp handshake(socket) do
      with {:ok, <<5, n>>} <- :gen_tcp.recv(socket, 2, 10_000),
           {:ok, _methods} <- :gen_tcp.recv(socket, n, 10_000),
           :ok <- :gen_tcp.send(socket, <<5, 0>>),
           {:ok, <<5, 1, 0, atyp>>} <- :gen_tcp.recv(socket, 4, 10_000),
           {:ok, host} <- read_address(socket, atyp),
           {:ok, <<port::16>>} <- :gen_tcp.recv(socket, 2, 10_000) do
        {:ok, host, port}
      end
    end

    defp read_address(socket, 1) do
      with {:ok, <<a, b, c, d>>} <- :gen_tcp.recv(socket, 4, 10_000), do: {:ok, "#{a}.#{b}.#{c}.#{d}"}
    end

    defp read_address(socket, 3) do
      with {:ok, <<len>>} <- :gen_tcp.recv(socket, 1, 10_000), do: :gen_tcp.recv(socket, len, 10_000)
    end

    defp read_address(socket, 4) do
      with {:ok, <<ip::binary-size(16)>>} <- :gen_tcp.recv(socket, 16, 10_000) do
        {:ok, for(<<x::16 <- ip>>, do: x) |> List.to_tuple() |> :inet.ntoa() |> to_string()}
      end
    end
  end
end
