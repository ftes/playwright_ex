defmodule PlaywrightEx.Client.Browser do
  @upstream "packages/playwright-core/src/client/browser.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Errors

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
    # this._channel.on('context', ...)  -- not ported: BrowserContext
    EventEmitter.on(_channel(this), "close", fn _ -> _did_close(this) end)
    put(this, :_closedPromise, Promise.new(this.baton, fn f, _ -> once(this, Events.Browser.disconnected(), f) end))
    this
  end

  def browser_type(this) do
    get(this, :_browserType)
  end

  # newContext, newContextForReuse, newPage, _innerNewContext  -- not ported: BrowserContext

  def _connect_to_browser_type(this, browser_type, browser_options, logger) do
    # Note: when using connect(), `browserType` is different from `this._parent`.
    # This is why browser type is not wired up in the constructor,
    # and instead this separate method is called later on.
    put(this, :_browserType, browser_type)
    put(this, :_options, browser_options)
    put(this, :_logger, logger)
    # for (const context of this._contexts) this._setupBrowserContext(context);  -- not ported: BrowserContext
  end

  # _didCreateContext, _setupBrowserContext  -- not ported: BrowserContext

  def contexts(this) do
    get(this, :_contexts)
  end

  def version(this) do
    get(this, :_initializer).version
  end

  def is_connected(this) do
    get(this, :_isConnected)
  end

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
