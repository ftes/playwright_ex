# upstream: packages/playwright-core/src/client/connect.ts
defmodule PlaywrightJS.Client.Connect do
  import PlaywrightJS.Runtime.Heap
  alias PlaywrightJS.Runtime.{Baton, Promise}
  alias PlaywrightJS.Client.{Browser, BrowserContext, Connection, Events, Page}

  # `let x` assigned later and read by closures -> a heap cell.
  defmodule Cell do
    defstruct [:guid, :conn]
  end

  # upstream: connect.ts:30
  def connect_to_browser(playwright, params) do
    # const deadline = ...  -- not ported: raceAgainstDeadline (params.timeout)
    name_param = if params[:browserName], do: %{"x-playwright-browser" => params.browserName}, else: %{}
    headers = Map.merge(name_param, params[:headers] || %{})

    connect_params = %{
      endpoint: params.endpoint,
      headers: headers,
      exposeNetwork: params[:exposeNetwork],
      slowMo: params[:slowMo]
    }

    connection = connect_to_endpoint(get(playwright, :_connection), connect_params, %{signal: nil, timeout: params[:timeout] || 0})
    browser_cell = new_object(connection.conn, Cell)

    Connection.on(connection, "close", fn _ ->
      browser = get(browser_cell, :browser)
      # Emulate all pages, contexts and the browser closing upon disconnect.
      for context <- (browser && Browser.contexts(browser)) || [] do
        for page <- BrowserContext.pages(context), do: Page._on_close(page)
        BrowserContext._on_close(context)
      end

      Baton.set_timeout(connection.conn, fn -> browser && Browser._did_close(browser) end, 0)
    end)

    # const result = await raceAgainstDeadline(async () => { ... }, deadline);  -- deadline not ported
    playwright = Connection.initialize_playwright(connection)

    if !get(playwright, :_initializer)[:preLaunchedBrowser] do
      Connection.close(connection)
      raise "Malformed endpoint. Did you use BrowserType.launchServer method?"
    end

    # playwright.selectors = playwright.selectors;  -- not ported: selectors
    browser = Browser.from(get(playwright, :_initializer).preLaunchedBrowser)
    put(browser_cell, :browser, browser)
    put(browser, :_shouldCloseConnectionOnClose, true)
    Browser.on(browser, Events.Browser.disconnected(), fn _ -> Connection.close(connection) end)
    browser
  end

  # upstream: connect.ts:76
  def connect_to_endpoint(parent_connection, params, timeout) do
    local_utils = Connection.local_utils(parent_connection)
    # const transport = localUtils ? new JsonPipeTransport(localUtils) : new WebSocketTransport();  -- WebSocketTransport not ported
    transport = __MODULE__.JsonPipeTransport.new(local_utils)
    connect_headers = __MODULE__.JsonPipeTransport.connect(transport, params, timeout)
    connection = Connection.new(parent_connection.conn, local_utils, nil, connect_headers)
    Connection.mark_as_remote(connection)
    Connection.on(connection, "close", fn _ -> __MODULE__.JsonPipeTransport.close(transport) end)

    close_error = new_object(connection.conn, Cell)
    on_transport_closed = fn reason -> Connection.close(connection, reason || get(close_error, :value)) end
    __MODULE__.JsonPipeTransport.on_close(transport, fn reason -> on_transport_closed.(reason) end)

    put(connection, :onmessage, fn message ->
      Promise.catch_(Promise.async(connection.conn, fn -> __MODULE__.JsonPipeTransport.send(transport, message) end), fn _ ->
        on_transport_closed.(nil)
      end)
    end)

    __MODULE__.JsonPipeTransport.on_message(transport, fn message ->
      try do
        Connection.dispatch(connection, message)
      rescue
        e ->
          put(close_error, :value, Exception.message(e))
          Promise.catch_(Promise.async(connection.conn, fn -> __MODULE__.JsonPipeTransport.close(transport) end), fn _ -> nil end)
      end
    end)

    connection
  end

  # upstream: connect.ts:115
  defmodule JsonPipeTransport do
    import PlaywrightJS.Runtime.Heap
    alias PlaywrightJS.Client.{ChannelOwner, EventEmitter, TimeoutSettings}

    defstruct [:guid, :conn]

    # upstream: connect.ts:119
    def new(owner) do
      this = new_object(owner.conn, __MODULE__)
      put(this, :_owner, owner)
      this
    end

    # upstream: connect.ts:123
    def connect(this, params, timeout) do
      %{pipe: pipe, headers: connect_headers} = ChannelOwner.channel_call(get(this, :_owner), :connect, params, timeout)
      put(this, :_pipe, pipe)
      connect_headers
    end

    # upstream: connect.ts:129
    def send(this, message) do
      ChannelOwner.channel_call(get(this, :_pipe), :send, %{message: message}, TimeoutSettings.k_no_timeout())
      nil
    end

    # upstream: connect.ts:133
    def on_message(this, callback) do
      EventEmitter.on(ChannelOwner._channel(get(this, :_pipe)), "message", fn %{message: message} -> callback.(message) end)
    end

    # upstream: connect.ts:137
    def on_close(this, callback) do
      EventEmitter.on(ChannelOwner._channel(get(this, :_pipe)), "closed", fn params -> callback.(params[:reason]) end)
    end

    # upstream: connect.ts:141
    def close(this) do
      try do
        ChannelOwner.channel_call(get(this, :_pipe), :close, %{}, TimeoutSettings.k_no_timeout())
      rescue
        _ -> nil
      end

      nil
    end
  end
end
