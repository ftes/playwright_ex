# upstream: packages/playwright-core/src/client/browserContext.ts
defmodule PlaywrightJS.Client.BrowserContext do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.{Connection.DummyChannelOwner, Errors, Page, Waiter}

  # upstream: browserContext.ts:90
  def from(context) do
    context
  end

  # upstream: browserContext.ts:94
  def from_nullable(context) do
    if context, do: from(context), else: nil
  end

  # upstream: browserContext.ts:98
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_pages, [])
    put(this, :_browser, nil)
    put(this, :_forReuse, false)
    put(this, :_closingStatus, "none")
    put(this, :_options, initializer.options)
    put(this, :_timeoutSettings, TimeoutSettings.new(this.conn))
    put(this, :debugger, DummyChannelOwner.from(initializer[:debugger]))
    put(this, :tracing, DummyChannelOwner.from(initializer.tracing))
    put(this, :request, DummyChannelOwner.from(initializer.requestContext))
    # this.request._timeoutSettings = this._timeoutSettings;  -- not ported: APIRequestContext
    # this.clock = new Clock(this); this.credentials = new Credentials(this);  -- not ported

    # this._channel.on('bindingCall', ...)  -- not ported
    EventEmitter.on(_channel(this), "close", fn _ -> _on_close(this) end)
    EventEmitter.on(_channel(this), "page", fn %{page: page} -> _on_page(this, Page.from(page)) end)
    # route, webSocketRoute, serviceWorker, console, pageError, dialog, dialogClosed,
    # request, requestFailed, requestFinished, response, recorderEvent  -- not ported
    put(this, :_closedPromise, Promise.new(this.conn, fn f, _ -> once(this, Events.BrowserContext.close(), f) end))

    _set_event_to_subscription_mapping(this, %{
      Events.BrowserContext.console() => "console",
      Events.BrowserContext.dialog() => "dialog",
      Events.BrowserContext.dialog_closed() => "dialogClosed",
      Events.BrowserContext.request() => "request",
      Events.BrowserContext.response() => "response",
      Events.BrowserContext.request_finished() => "requestFinished",
      Events.BrowserContext.request_failed() => "requestFailed"
    })

    this
  end

  # upstream: browserContext.ts:191
  def _initialize_har_from_options(_this, record_har) do
    if !record_har, do: nil, else: raise("recordHar: not ported")
  end

  # upstream: browserContext.ts:202
  defp _on_page(this, page) do
    set_add(this, :_pages, page)
    emit(this, Events.BrowserContext.page(), page)
    if get(page, :_opener) && !Page.is_closed(get(page, :_opener)), do: Page.emit(get(page, :_opener), Events.Page.popup(), page)
  end

  # upstream: browserContext.ts:294
  def set_default_navigation_timeout(this, timeout) do
    TimeoutSettings.set_default_navigation_timeout(get(this, :_timeoutSettings), timeout)
  end

  # upstream: browserContext.ts:298
  def set_default_timeout(this, timeout) do
    TimeoutSettings.set_default_timeout(get(this, :_timeoutSettings), timeout)
  end

  # upstream: browserContext.ts:302
  def browser(this) do
    get(this, :_browser)
  end

  # upstream: browserContext.ts:306
  def pages(this) do
    get(this, :_pages)
  end

  # upstream: browserContext.ts:310
  def is_closed(this) do
    get(this, :_closingStatus) != "none"
  end

  # upstream: browserContext.ts:314
  def new_page(this) do
    if get(this, :_ownerPage), do: raise("Please use browser.newContext()")
    Page.from(channel_call(this, :newPage, %{}, TimeoutSettings.k_no_timeout()).page)
  end

  # upstream: browserContext.ts:453
  def _effective_close_reason(this) do
    get(this, :_closeReason) || (get(this, :_browser) && get(get(this, :_browser), :_closeReason))
  end

  # upstream: browserContext.ts:457
  def wait_for_event(this, event, options_or_predicate \\ %{}) do
    _wrap_api_call(this, fn _ ->
      timeout_options =
        TimeoutSettings.timeout(get(this, :_timeoutSettings), if(is_function(options_or_predicate), do: %{}, else: options_or_predicate))

      predicate = if is_function(options_or_predicate), do: options_or_predicate, else: options_or_predicate[:predicate]
      waiter = Waiter.create_for_event(this, event)

      Waiter.reject_on_timeout(
        waiter,
        timeout_options,
        "Timeout #{timeout_options.timeout}ms exceeded while waiting for event \"#{event}\""
      )

      if event != Events.BrowserContext.close(),
        do:
          Waiter.reject_on_event(waiter, this, Events.BrowserContext.close(), fn ->
            Errors.TargetClosedError.new(_effective_close_reason(this))
          end)

      result = Waiter.wait_for_event(waiter, this, event, predicate)
      Waiter.dispose(waiter)
      result
    end)
  end

  # upstream: browserContext.ts:501
  def _on_close(this) do
    put(this, :_closingStatus, "closed")
    if get(this, :_browser), do: set_delete(get(this, :_browser), :_contexts, this)
    if get(this, :_browser), do: set_delete(get(get(this, :_browser), :_browserType), :_contexts, this)
    # this._browser?._browserType._playwright.selectors._contextsForSelectors.delete(this);  -- not ported: selectors
    # this._disposeHarRouters(); this.tracing._resetStackCounter(); this.request.tracing._resetStackCounter();  -- not ported
    emit(this, Events.BrowserContext.close(), this)
  end

  # upstream: browserContext.ts:516
  def close(this, options \\ %{}) do
    if is_closed(this) do
      nil
    else
      put(this, :_closeReason, options[:reason])
      put(this, :_closingStatus, "closing")
      # await this.request.dispose(options);  -- not ported: APIRequestContext
      # await this._instrumentation.runBeforeCloseBrowserContext(this);  -- not ported
      # const harError = await this.tracing._exportAllHars().catch(e => e);  -- not ported: HAR
      channel_call(this, :close, options, TimeoutSettings.k_no_timeout())
      Promise.await(get(this, :_closedPromise))
      nil
    end
  end

  # upstream: browserContext.ts:564
  def prepare_browser_context_params(options) do
    # if (options.extraHTTPHeaders) network.validateHeaders(options.extraHTTPHeaders);  -- not ported
    context_params =
      Map.merge(options, %{
        viewport: if(options[:viewport] == :null, do: nil, else: options[:viewport]),
        noDefaultViewport: options[:viewport] == :null,
        extraHTTPHeaders:
          if(options[:extraHTTPHeaders],
            do: Enum.map(options[:extraHTTPHeaders], fn {name, value} -> %{name: to_string(name), value: value} end)
          ),
        storageState: if(options[:storageState], do: raise("storageState: not ported")),
        serviceWorkers: options[:serviceWorkers],
        colorScheme: if(options[:colorScheme] == :null, do: "no-override", else: options[:colorScheme]),
        reducedMotion: if(options[:reducedMotion] == :null, do: "no-override", else: options[:reducedMotion]),
        forcedColors: if(options[:forcedColors] == :null, do: "no-override", else: options[:forcedColors]),
        contrast: if(options[:contrast] == :null, do: "no-override", else: options[:contrast]),
        acceptDownloads: to_accept_downloads_protocol(options[:acceptDownloads]),
        clientCertificates: if(options[:clientCertificates], do: raise("clientCertificates: not ported")),
        httpCredentials: to_http_credentials_protocol(options[:httpCredentials])
      })

    if context_params[:recordVideo] && context_params.recordVideo[:dir],
      do: put_in(context_params, [:recordVideo, :dir], Path.expand(context_params.recordVideo.dir)),
      else: context_params
  end

  # upstream: browserContext.ts:587
  def to_http_credentials_protocol(credentials) do
    cond do
      !credentials -> nil
      true -> List.wrap(credentials) |> then(fn list -> if list != [], do: list end)
    end
  end

  # upstream: browserContext.ts:594
  defp to_accept_downloads_protocol(accept_downloads) do
    cond do
      accept_downloads == nil -> nil
      accept_downloads -> "accept"
      true -> "deny"
    end
  end
end
