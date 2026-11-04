defmodule PlaywrightEx.Client.Browser do
  @upstream "packages/playwright-core/src/client/browser.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Page

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

    EventEmitter.on(_channel(this), "context", fn %{context: context} ->
      _did_create_context(this, BrowserContext.from(context))
    end)

    EventEmitter.on(_channel(this), "close", fn _ -> _did_close(this) end)
    put(this, :_closedPromise, Promise.new(fn f, _ -> once(this, Events.Browser.disconnected(), f) end))
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
      # await this._instrumentation.runBeforeCloseBrowserContext(context);  -- not ported: instrumentation
      for page <- BrowserContext.pages(context), do: Page._on_close(page)
      BrowserContext._on_close(context)
      channel_call(this, :disconnectFromReusedContext, %{reason: reason}, TimeoutSettings.k_no_timeout())
    end
  end

  def _inner_new_context(this, user_options, for_reuse) do
    # const options = this._browserType._playwright.selectors._withSelectorOptions(userOptions);  -- not ported: selectors
    options = user_options
    # await this._instrumentation.runBeforeCreateBrowserContext(options);  -- not ported: instrumentation
    context_options = BrowserContext.prepare_browser_context_params(options)

    response =
      if for_reuse,
        do: channel_call(this, :newContextForReuse, context_options, TimeoutSettings.k_no_timeout()),
        else: channel_call(this, :newContext, context_options, TimeoutSettings.k_no_timeout())

    context = BrowserContext.from(response.context)
    if for_reuse, do: put(context, :_forReuse, true)
    if options[:logger], do: put(context, :_logger, options.logger)
    BrowserContext._initialize_har_from_options(context, options[:recordHar])
    # await this._instrumentation.runAfterCreateBrowserContext(context);  -- not ported: instrumentation
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
    # context.tracing._tracesDir = this._options.tracesDir;  -- not ported: Tracing
    # context.request.tracing._tracesDir = this._options.tracesDir;  -- not ported: Tracing
    set_add(get(this, :_browserType), :_contexts, context)
    # this._browserType._playwright.selectors._contextsForSelectors.add(context);  -- not ported: selectors
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

  # bind, unbind  -- not ported
  def new_page(this, options \\ %{}) do
    _wrap_api_call(
      this,
      fn _ ->
        context = new_context(this, options)
        page = BrowserContext.new_page(context)
        put(page, :_ownedContext, context)
        put(context, :_ownerPage, page)
        page
      end,
      %{title: "Create page"}
    )
  end

  def is_connected(this) do
    get(this, :_isConnected)
  end

  # newBrowserCDPSession, startTracing, stopTracing  -- not ported

  def close(this, options \\ %{}) do
    put(this, :_closeReason, options[:reason])

    try do
      if get(this, :_shouldCloseConnectionOnClose),
        do: PlaywrightEx.Client.Connection.close(get(this, :_connection)),
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
