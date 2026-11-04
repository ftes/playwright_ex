defmodule PlaywrightEx.Client.Connect do
  @upstream "packages/playwright-core/src/client/connect.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  The remote connection goes through the local driver's `LocalUtils.connect` (the driver opens
  the WebSocket, `JsonPipeTransport`). It gets its own heap on the driver's baton.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.Events
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.TimeoutRunner
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise

  # Elixir only: a `let` assigned later and read by closures.
  defmodule Cell do
    @moduledoc false
    defstruct [:guid, :loop, :heap]
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
    browser_cell = new_object(Cell)

    Connection.on(connection, "close", fn _ ->
      browser = get(browser_cell, :browser)
      # Emulate all pages, contexts and the browser closing upon disconnect.
      for context <- (browser && Browser.contexts(browser)) || [] do
        for page <- BrowserContext.pages(context), do: Page._on_close(page)
        BrowserContext._on_close(context)
      end

      EventLoop.set_timeout(fn -> browser && Browser._did_close(browser) end, 0)
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
          Browser.on(browser, Events.Browser.disconnected(), fn _ -> Connection.close(connection) end)
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
    connection = Connection.new(parent_connection.loop, local_utils, nil, connect_headers)
    Connection.mark_as_remote(connection)
    Connection.on(connection, "close", fn _ -> __MODULE__.JsonPipeTransport.close(transport) end)

    # let closeError: string | undefined;
    close_error = new_object(Cell)
    # `reason || closeError`, JS truthiness: the pipe reports an empty reason.
    on_transport_closed = fn reason ->
      Connection.close(connection, Enum.find([reason, get(close_error, :value)], &(&1 not in [nil, ""])))
    end

    __MODULE__.JsonPipeTransport.on_close(transport, fn reason -> on_transport_closed.(reason) end)

    put(connection, :onmessage, fn message ->
      Promise.catch_(Promise.async(fn -> __MODULE__.JsonPipeTransport.send_message(transport, message) end), fn _ ->
        on_transport_closed.(nil)
      end)
    end)

    __MODULE__.JsonPipeTransport.on_message(transport, fn message ->
      try do
        Connection.dispatch(connection, message)
      rescue
        e ->
          put(close_error, :value, Exception.message(e))
          Promise.catch_(Promise.async(fn -> __MODULE__.JsonPipeTransport.close(transport) end), fn _ -> nil end)
      end
    end)

    connection
  end

  # interface Transport  -- the JsonPipeTransport functions
  # class WebSocketTransport  -- not ported: browser builds only (window.WebSocket)

  defmodule JsonPipeTransport do
    @moduledoc false
    import PlaywrightEx.Runtime.Heap

    alias PlaywrightEx.Client.ChannelOwner
    alias PlaywrightEx.Client.EventEmitter
    alias PlaywrightEx.Client.TimeoutSettings

    defstruct [:guid, :loop, :heap]

    def new(owner) do
      this = new_object(__MODULE__)
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

    def on_message(this, callback) do
      EventEmitter.on(ChannelOwner._channel(get(this, :_pipe)), "message", fn %{message: message} ->
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
