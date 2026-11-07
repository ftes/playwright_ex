defmodule PlaywrightEx.Client.Browser do
  @upstream "packages/playwright-core/src/client/browser.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.Browser

  alias PlaywrightEx.Client.Artifact
  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.CDPSession
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.FileUtils
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Selectors

  def from(browser) do
    browser
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_contexts, [])
    put(this, :_isConnected, true)
    put(this, :_shouldCloseConnectionOnClose, false)
    put(this, :_options, %{})
    put(this, :_name, initializer.name)
    put(this, :_browserName, initializer.browserName)

    # Elixir only: on_sync, a pure state update.
    EventEmitter.on_sync(_channel(this), "context", fn %{context: context} ->
      _did_create_context(this, BrowserContext.from(context))
    end)

    # Elixir only: on_sync, a pure state update.
    EventEmitter.on_sync(_channel(this), "close", fn _ -> _did_close(this) end)
    # A latch on the browser.
    put(this, :_closedPromise, Promise.new(this, fn f, _ -> once(this, Events.Browser.disconnected(), f) end))
    this
  end

  def browser_type(this) do
    get(this, :_browserType)
  end

  def new_context(this, options \\ %{}) do
    _inner_new_context(this, options, false)
  end

  def _new_context_for_reuse(this, options \\ %{}) do
    _inner_new_context(this, options, true)
  end

  def _disconnect_from_reused_context(this, reason) do
    context = Enum.find(get(this, :_contexts), fn context -> get(context, :_forReuse) end)

    if context do
      ClientInstrumentation.run_before_close_browser_context(get(this, :_instrumentation), context)
      for page <- BrowserContext.pages(context), do: Page._on_close(page)
      BrowserContext._on_close(context)
      channel_call(this, :disconnectFromReusedContext, %{reason: reason}, TimeoutSettings.k_no_timeout())
    end
  end

  def _inner_new_context(this, user_options, for_reuse) do
    options =
      Selectors._with_selector_options(get(get(get(this, :_browserType), :_playwright), :selectors), user_options)

    options = ClientInstrumentation.run_before_create_browser_context(get(this, :_instrumentation), options)
    context_options = BrowserContext.prepare_browser_context_params(options)

    response =
      if for_reuse,
        do: channel_call(this, :newContextForReuse, context_options, TimeoutSettings.k_no_timeout()),
        else: channel_call(this, :newContext, context_options, TimeoutSettings.k_no_timeout())

    # Elixir only: the calling process anchors the context (`_set_creator/1`).
    context = ChannelOwner._set_creator(BrowserContext.from(response.context))
    if for_reuse, do: put(context, :_forReuse, true)
    if options[:logger], do: put(context, :_logger, options.logger)
    BrowserContext._initialize_har_from_options(context, options[:recordHar])
    ClientInstrumentation.run_after_create_browser_context(get(this, :_instrumentation), context)
    context
  end

  def _connect_to_browser_type(this, browser_type, browser_options, logger) do
    # Note: when using connect(), `browserType` is different from `this._parent`.
    # This is why browser type is not wired up in the constructor,
    # and instead this separate method is called later on.
    put(this, :_browserType, browser_type)
    put(this, :_options, browser_options)
    put(this, :_logger, logger)
    for context <- get(this, :_contexts), do: _setup_browser_context(this, context)
  end

  defp _did_create_context(this, context) do
    put(context, :_browser, this)
    set_add(this, :_contexts, context)
    # Note: when connecting to a browser, initial contexts arrive before `browserType` is set,
    # and will be configured later in `_connectToBrowserType`.
    if get(this, :_browserType), do: _setup_browser_context(this, context)
    emit(this, Events.Browser.context(), context)
  end

  defp _setup_browser_context(this, context) do
    put(context, :_logger, get(this, :_logger))
    put(get(context, :tracing), :_tracesDir, get(this, :_options)[:tracesDir])
    put(get(get(context, :request), :tracing), :_tracesDir, get(this, :_options)[:tracesDir])
    set_add(get(this, :_browserType), :_contexts, context)
    set_add(get(get(get(this, :_browserType), :_playwright), :selectors), :_contextsForSelectors, context)
    playwright = get(get(this, :_browserType), :_playwright)
    BrowserContext.set_default_timeout(context, get(playwright, :_defaultContextTimeout))
    BrowserContext.set_default_navigation_timeout(context, get(playwright, :_defaultContextNavigationTimeout))
  end

  def contexts(this) do
    get(this, :_contexts)
  end

  def version(this) do
    get(this, :_initializer).version
  end

  def bind(this, title, options \\ %{}) do
    %{endpoint: endpoint} =
      channel_call(this, :startServer, Map.merge(%{title: title}, options), TimeoutSettings.k_no_timeout())

    %{endpoint: endpoint}
  end

  def unbind(this) do
    channel_call(this, :stopServer, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  # @apiCall({ title: 'Create page' })
  def new_page(this, options \\ %{}) do
    api_call(%{title: "Create page"}).(this, fn ->
      context = new_context(this, options)
      page = BrowserContext.new_page(context)
      put(page, :_ownedContext, context)
      put(context, :_ownerPage, page)
      page
    end)
  end

  def is_connected(this) do
    get(this, :_isConnected)
  end

  def new_browser_cdp_session(this) do
    CDPSession.from(channel_call(this, :newBrowserCDPSession, %{}, TimeoutSettings.k_no_timeout()).session)
  end

  def start_tracing(this, page \\ nil, options \\ %{}) do
    options = options || %{}
    put(this, :_path, options[:path])
    channel_call(this, :startTracing, Map.merge(options, %{page: page}), TimeoutSettings.k_no_timeout())
    nil
  end

  def stop_tracing(this) do
    artifact = Artifact.from(channel_call(this, :stopTracing, %{}, TimeoutSettings.k_no_timeout()).artifact)
    buffer = Artifact.read_into_buffer(artifact)
    Artifact.delete(artifact)

    if path = get(this, :_path) do
      FileUtils.mkdir_if_needed(path)
      File.write!(path, buffer)
      put(this, :_path, nil)
    end

    buffer
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def close(this, options \\ %{}) do
    try do
      # deviation: the writes are inside the try. They raise TargetClosedError once the
      # connection process is gone (a lost driver), where JS's succeed and its call then raises:
      # the browser is closed already, so close returns.
      put(this, :_closeReason, options[:reason])
      # Elixir only: the closing process anchors the closed browser (it reads it next).
      ChannelOwner._set_creator(this)

      # Elixir only: `Connection.close` in one step (its check-then-set races the transport's close).
      if get(this, :_shouldCloseConnectionOnClose),
        do: atomic(this, fn -> PlaywrightEx.Client.Connection.close(get(this, :_connection)) end),
        else: channel_call(this, :close, options, TimeoutSettings.k_no_timeout())

      Promise.await(get(this, :_closedPromise))
    rescue
      e ->
        if Errors.is_target_closed_error(e), do: nil, else: reraise(e, __STACKTRACE__)
    end

    nil
  end

  def _did_close(this) do
    put(this, :_isConnected, false)
    emit(this, Events.Browser.disconnected(), this)
  end
end
