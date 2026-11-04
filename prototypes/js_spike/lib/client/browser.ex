# upstream: packages/playwright-core/src/client/browser.ts
defmodule PlaywrightJS.Client.Browser do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.{BrowserContext, Errors}

  # upstream: browser.ts:46
  def from(browser) do
    browser
  end

  # upstream: browser.ts:50
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_contexts, [])
    put(this, :_isConnected, true)
    put(this, :_shouldCloseConnectionOnClose, false)
    put(this, :_options, %{})
    put(this, :_name, initializer.name)
    put(this, :_browserName, initializer.browserName)
    EventEmitter.on(_channel(this), "context", fn %{context: context} -> _did_create_context(this, BrowserContext.from(context)) end)
    EventEmitter.on(_channel(this), "close", fn _ -> _did_close(this) end)
    put(this, :_closedPromise, Promise.new(this.conn, fn f, _ -> once(this, Events.Browser.disconnected(), f) end))
    this
  end

  # upstream: browser.ts:59
  def browser_type(this) do
    get(this, :_browserType)
  end

  # upstream: browser.ts:63
  def new_context(this, options \\ %{}) do
    _inner_new_context(this, options, false)
  end

  # upstream: browser.ts:82
  def _inner_new_context(this, user_options \\ %{}, for_reuse) do
    options = user_options
    # this._browserType._playwright.selectors._withSelectorOptions(userOptions)  -- not ported: selectors
    # await this._instrumentation.runBeforeCreateBrowserContext(options);  -- not ported
    context_options = BrowserContext.prepare_browser_context_params(options)

    response =
      if for_reuse,
        do: channel_call(this, :newContextForReuse, context_options, TimeoutSettings.k_no_timeout()),
        else: channel_call(this, :newContext, context_options, TimeoutSettings.k_no_timeout())

    context = BrowserContext.from(response.context)
    if for_reuse, do: put(context, :_forReuse, true)
    if options[:logger], do: put(context, :_logger, options[:logger])
    BrowserContext._initialize_har_from_options(context, options[:recordHar])
    # await this._instrumentation.runAfterCreateBrowserContext(context);  -- not ported
    context
  end

  # upstream: browser.ts:97
  def _connect_to_browser_type(this, browser_type, browser_options, logger) do
    # Note: when using connect(), `browserType` is different from `this._parent`.
    # This is why browser type is not wired up in the constructor,
    # and instead this separate method is called later on.
    put(this, :_browserType, browser_type)
    put(this, :_options, browser_options)
    put(this, :_logger, logger)
    for context <- get(this, :_contexts), do: _setup_browser_context(this, context)
  end

  # upstream: browser.ts:108
  defp _did_create_context(this, context) do
    put(context, :_browser, this)
    set_add(this, :_contexts, context)
    # Note: when connecting to a browser, initial contexts arrive before `browserType` is set,
    # and will be configured later in `_connectToBrowserType`.
    if get(this, :_browserType), do: _setup_browser_context(this, context)
    emit(this, Events.Browser.context(), context)
  end

  # upstream: browser.ts:118
  defp _setup_browser_context(this, context) do
    put(context, :_logger, get(this, :_logger))
    # context.tracing._tracesDir = this._options.tracesDir;  -- not ported: tracing
    # context.request.tracing._tracesDir = this._options.tracesDir;  -- not ported: tracing
    set_add(get(this, :_browserType), :_contexts, context)
    # this._browserType._playwright.selectors._contextsForSelectors.add(context);  -- not ported: selectors
    BrowserContext.set_default_timeout(context, get(get(get(this, :_browserType), :_playwright), :_defaultContextTimeout))

    BrowserContext.set_default_navigation_timeout(
      context,
      get(get(get(this, :_browserType), :_playwright), :_defaultContextNavigationTimeout)
    )
  end

  # upstream: browser.ts:128
  def contexts(this) do
    get(this, :_contexts)
  end

  # upstream: browser.ts:132
  def version(this) do
    get(this, :_initializer).version
  end

  # upstream: browser.ts:155
  def is_connected(this) do
    get(this, :_isConnected)
  end

  # upstream: browser.ts:184
  def close(this, options \\ %{}) do
    put(this, :_closeReason, options[:reason])

    try do
      if get(this, :_shouldCloseConnectionOnClose),
        do: PlaywrightJS.Client.Connection.close(get(this, :_connection)),
        else: channel_call(this, :close, options, TimeoutSettings.k_no_timeout())

      Promise.await(get(this, :_closedPromise))
    rescue
      e ->
        if Errors.is_target_closed_error(e), do: nil, else: reraise(e, __STACKTRACE__)
    end

    nil
  end

  # upstream: browser.ts:199
  def _did_close(this) do
    put(this, :_isConnected, false)
    emit(this, Events.Browser.disconnected(), this)
  end
end
