defmodule PlaywrightEx.Client.Connect do
  @upstream "packages/playwright-core/src/client/connect.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  The remote connection goes through the local driver's `LocalUtils.connect` (the driver opens
  the WebSocket, `JsonPipeTransport`). It is a connection process of its own
  (`PlaywrightEx.Runtime.Conn`, guids repeat across connections), linked to the local one.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.Events
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.TimeoutRunner
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Promise

  # Elixir only: a `let` assigned later and read by closures.
  defmodule Cell do
    @moduledoc false
    defstruct [:guid, :conn, :table]
  end

  def connect_to_browser(playwright, params) do
    deadline =
      if params[:timeout] && params.timeout != 0, do: System.monotonic_time(:millisecond) + params.timeout, else: 0

    name_param = if params[:browserName], do: %{"x-playwright-browser" => params.browserName}, else: %{}
    headers = Map.merge(name_param, params[:headers] || %{})

    connect_params = %{
      endpoint: params.endpoint,
      headers: headers,
      exposeNetwork: params[:exposeNetwork],
      slowMo: params[:slowMo]
    }

    connect_params =
      if params[:__testHookRedirectPortForwarding],
        do: Map.put(connect_params, :socksProxyRedirectPortForTest, params.__testHookRedirectPortForwarding),
        else: connect_params

    connection =
      connect_to_endpoint(get(playwright, :_connection), connect_params, %{signal: nil, timeout: params[:timeout] || 0})

    # let browser: Browser;
    browser_cell = new_object(Cell, connection)

    Connection.on(connection, "close", fn _ ->
      browser = get(browser_cell, :browser)
      # Emulate all pages, contexts and the browser closing upon disconnect.
      for context <- (browser && Browser.contexts(browser)) || [] do
        for page <- BrowserContext.pages(context), do: Page._on_close(page)
        BrowserContext._on_close(context)
      end

      # setTimeout(() => browser?._didClose(), 0)
      Promise.void(fn -> browser && Browser._did_close(browser) end)
    end)

    result =
      TimeoutRunner.race_against_deadline(
        fn ->
          # For tests.
          if params[:__testHookBeforeCreateBrowser], do: params.__testHookBeforeCreateBrowser.()

          playwright = Connection.initialize_playwright(connection)

          if !get(playwright, :_initializer)[:preLaunchedBrowser] do
            Connection.close(connection)
            raise "Malformed endpoint. Did you use BrowserType.launchServer method?"
          end

          put(playwright, :selectors, get(playwright, :selectors))
          browser = Browser.from(get(playwright, :_initializer).preLaunchedBrowser)
          put(browser_cell, :browser, browser)
          put(browser, :_shouldCloseConnectionOnClose, true)
          # Elixir only: `Connection.close` in one step (its check-then-set races the transport's close).
          Browser.on(browser, Events.Browser.disconnected(), fn _ ->
            atomic(connection, fn -> Connection.close(connection) end)
          end)

          browser
        end,
        deadline
      )

    if !result.timedOut do
      result.result
    else
      Connection.close(connection)
      raise "Timeout #{params.timeout}ms exceeded"
    end
  end

  def connect_to_endpoint(parent_connection, params, timeout) do
    local_utils = Connection.local_utils(parent_connection)

    # const transport = localUtils ? new JsonPipeTransport(localUtils) : new WebSocketTransport();  -- the driver always has LocalUtils
    transport = __MODULE__.JsonPipeTransport.new(local_utils)
    connect_headers = __MODULE__.JsonPipeTransport.connect(transport, params, timeout)

    # const connection = new Connection(localUtils, instrumentation, connectHeaders): a process,
    # started by (and linked to) the local connection. Its messages go through `forwarder` (see
    # `connection.onmessage` below).
    {child, forwarder} =
      Conn.run(parent_connection.conn, fn ->
        forwarder = spawn_link(fn -> _forward(transport) end)

        {:ok, child} =
          Conn.start_link(
            local_utils: local_utils,
            headers: connect_headers,
            transport: fn messages -> send(forwarder, {:send, messages}) end,
            on_dispatch_error: fn e -> send(forwarder, {:dispatch_error, e}) end
          )

        {child, forwarder}
      end)

    connection = Conn.connection(child)
    Connection.mark_as_remote(connection)
    Connection.on(connection, "close", fn _ -> __MODULE__.JsonPipeTransport.close(transport) end)

    # let closeError: string | undefined;
    close_error = new_object(Cell, connection)
    # `reason || closeError`, JS truthiness: the pipe reports an empty reason.
    on_transport_closed = fn reason ->
      atomic(connection, fn ->
        Connection.close(connection, Enum.find([reason, get(close_error, :value)], &(&1 not in [nil, ""])))
      end)
    end

    __MODULE__.JsonPipeTransport.on_close(transport, fn reason -> on_transport_closed.(reason) end)

    # connection.onmessage = message => transport.send(message).catch(() => onTransportClosed());
    # (Elixir: the connection process hands its messages to `forwarder`, which sends them in order.)
    send(forwarder, {:start, child, on_transport_closed, close_error})

    # transport.onmessage = message => { try { connection!.dispatch(message); } catch (e) { ... } };
    # (Elixir: dispatched by the connection process; a dispatch error is reported to `forwarder`.)
    __MODULE__.JsonPipeTransport.on_message(transport, fn message -> send(child, {:pw_msg, message}) end)

    connection
  end

  # Elixir only: sends the remote connection's messages through the pipe, in order (each call
  # is written before the next starts), and closes the pipe on a dispatch error.
  defp _forward(transport) do
    receive do
      {:start, child, on_transport_closed, close_error} ->
        mon = Process.monitor(child)
        _forward_loop(transport, mon, on_transport_closed, close_error)
    end
  end

  defp _forward_loop(transport, mon, on_transport_closed, close_error) do
    receive do
      {:send, messages} ->
        for message <- messages do
          Promise.void(fn ->
            try do
              __MODULE__.JsonPipeTransport.send_message(transport, message)
            rescue
              _ -> on_transport_closed.(nil)
            end
          end)
        end

        _forward_loop(transport, mon, on_transport_closed, close_error)

      {:dispatch_error, e} ->
        put(close_error, :value, Exception.message(e))
        Promise.void(fn -> __MODULE__.JsonPipeTransport.close(transport) end)
        _forward_loop(transport, mon, on_transport_closed, close_error)

      {:DOWN, ^mon, :process, _, _} ->
        :ok
    end
  end

  # interface Transport  -- the JsonPipeTransport functions
  # class WebSocketTransport  -- not ported: browser builds only (window.WebSocket)

  defmodule JsonPipeTransport do
    @moduledoc false
    import PlaywrightEx.Runtime.Heap

    alias PlaywrightEx.Client.ChannelOwner
    alias PlaywrightEx.Client.EventEmitter
    alias PlaywrightEx.Client.TimeoutSettings

    defstruct [:guid, :conn, :table]

    # Elixir only: owned by `owner` (the local connection's LocalUtils).
    def new(owner) do
      this = new_object(__MODULE__, owner)
      put(this, :_owner, owner)
      this
    end

    def connect(this, params, timeout) do
      %{pipe: pipe, headers: connect_headers} =
        ChannelOwner.channel_call(get(this, :_owner), :connect, params, timeout)

      put(this, :_pipe, pipe)
      connect_headers
    end

    # send  -- ported as send_message/2 (Kernel.send/2)
    def send_message(this, message) do
      ChannelOwner.channel_call(get(this, :_pipe), :send, %{message: message}, TimeoutSettings.k_no_timeout())
    end

    # Elixir only: `on_sync`, the callback only forwards the message (in order).
    def on_message(this, callback) do
      EventEmitter.on_sync(ChannelOwner._channel(get(this, :_pipe)), "message", fn %{message: message} ->
        callback.(message)
      end)
    end

    def on_close(this, callback) do
      EventEmitter.on(ChannelOwner._channel(get(this, :_pipe)), "closed", fn params -> callback.(params[:reason]) end)
    end

    def close(this) do
      try do
        ChannelOwner.channel_call(get(this, :_pipe), :close, %{}, TimeoutSettings.k_no_timeout())
      rescue
        _ -> nil
      end
    end
  end
end
