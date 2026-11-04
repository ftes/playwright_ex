defmodule PlaywrightEx.Client.BrowserContext do
  @upstream "packages/playwright-core/src/client/browserContext.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.ConsoleMessage
  alias PlaywrightEx.Client.Dialog
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Network
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Client.Waiter
  alias PlaywrightEx.Client.WebError
  alias PlaywrightEx.Client.Worker
  alias PlaywrightEx.Isomorphic.Headers

  def from(context) do
    context
  end

  def from_nullable(context) do
    if context, do: from(context)
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_pages, [])
    put(this, :_routes, [])
    put(this, :_webSocketRoutes, [])
    # Browser is null for browser contexts created outside of normal browser, e.g. android or electron.
    put(this, :_browser, nil)
    put(this, :_ownerPage, nil)
    put(this, :_forReuse, false)
    put(this, :_serviceWorkers, [])
    put(this, :_closingStatus, "none")
    put(this, :_harRouters, [])
    put(this, :_options, initializer.options)
    put(this, :_timeoutSettings, TimeoutSettings.new())
    # Debugger.from / Tracing.from / APIRequestContext.from  -- not ported: DummyChannelOwners
    put(this, :debugger, initializer.debugger)
    put(this, :tracing, initializer.tracing)
    put(this, :request, initializer.requestContext)
    put(get(this, :request), :_timeoutSettings, get(this, :_timeoutSettings))
    # this.clock = new Clock(this); this.credentials = new Credentials(this);  -- not ported

    # this._channel.on('bindingCall', ...)  -- not ported: BindingCall
    EventEmitter.on(_channel(this), "close", fn _ -> _on_close(this) end)
    EventEmitter.on(_channel(this), "page", fn %{page: page} -> _on_page(this, Page.from(page)) end)
    # this._channel.on('route' | 'webSocketRoute', ...)  -- not ported: routing
    EventEmitter.on(_channel(this), "serviceWorker", fn %{worker: worker} ->
      service_worker = Worker.from(worker)
      put(service_worker, :_context, this)
      set_add(this, :_serviceWorkers, service_worker)
      emit(this, Events.BrowserContext.service_worker(), service_worker)
    end)

    EventEmitter.on(_channel(this), "console", fn event ->
      worker = Worker.from_nullable(event[:worker])
      page = Page.from_nullable(event[:page])
      console_message = ConsoleMessage.new(event, page, worker)
      if worker, do: emit(worker, Events.Worker.console(), console_message)
      if page, do: emit(page, Events.Page.console(), console_message)

      if worker && set_has(this, :_serviceWorkers, worker) do
        scope = _service_worker_scope(this, worker)

        for page <- get(this, :_pages) do
          if scope && String.starts_with?(Page.url(page), scope), do: emit(page, Events.Page.console(), console_message)
        end
      end

      emit(this, Events.BrowserContext.console(), console_message)
    end)

    EventEmitter.on(_channel(this), "pageError", fn %{error: error, page: page, location: location} ->
      page_object = Page.from(page)
      parsed_error = Errors.parse_error(error)
      emit(this, Events.BrowserContext.web_error(), WebError.new(page_object, parsed_error, location))
      if page_object, do: emit(page_object, Events.Page.page_error(), parsed_error)
    end)

    EventEmitter.on(_channel(this), "dialog", fn %{dialog: dialog} ->
      dialog_object = Dialog.from(dialog)
      has_listeners = emit(this, Events.BrowserContext.dialog(), dialog_object)
      page = Dialog.page(dialog_object)

      has_listeners =
        if page, do: emit(page, Events.Page.dialog(), dialog_object) || has_listeners, else: has_listeners

      if !has_listeners do
        # Although we do similar handling on the server side, we still need this logic
        # on the client side due to a possible race condition between two async calls:
        # a) removing "dialog" listener subscription (client->server)
        # b) actual "dialog" event (server->client)
        if Dialog.type(dialog_object) == "beforeunload",
          do:
            Promise.catch_(
              Promise.async(fn -> channel_call(dialog, :accept, %{}, TimeoutSettings.k_no_timeout()) end),
              fn _ -> nil end
            ),
          else:
            Promise.catch_(
              Promise.async(fn -> channel_call(dialog, :dismiss, %{}, TimeoutSettings.k_no_timeout()) end),
              fn _ -> nil end
            )
      end
    end)

    EventEmitter.on(_channel(this), "dialogClosed", fn %{dialog: dialog} ->
      dialog_object = Dialog.from(dialog)
      emit(this, Events.BrowserContext.dialog_closed(), dialog_object)
      page = Dialog.page(dialog_object)
      if page, do: emit(page, Events.Page.dialog_closed(), dialog_object)
    end)

    EventEmitter.on(_channel(this), "request", fn %{request: request} = event ->
      _on_request(this, Request.from(request), event[:page])
    end)

    EventEmitter.on(_channel(this), "requestFailed", fn %{request: request} = event ->
      _on_request_failed(this, Request.from(request), event.responseEndTiming, event[:failureText], event[:page])
    end)

    EventEmitter.on(_channel(this), "requestFinished", fn params -> _on_request_finished(this, params) end)

    EventEmitter.on(_channel(this), "response", fn %{response: response} = event ->
      _on_response(this, Response.from(response), event[:page])
    end)

    # this._channel.on('recorderEvent', ...)  -- not ported: recorder
    put(
      this,
      :_closedPromise,
      Promise.new(fn f, _ -> once(this, Events.BrowserContext.close(), f) end)
    )

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

  def _initialize_har_from_options(_this, record_har) do
    if record_har do
      # await this.tracing._recordIntoHAR(...)  -- not ported: Tracing
      raise "recordHar is not supported yet"
    end
  end

  defp _on_page(this, page) do
    set_add(this, :_pages, page)
    emit(this, Events.BrowserContext.page(), page)
    opener = get(page, :_opener)
    if opener && !Page.is_closed(opener), do: emit(opener, Events.Page.popup(), page)
  end

  defp _on_request(this, request, page) do
    emit(this, Events.BrowserContext.request(), request)
    if page = Page.from_nullable(page), do: emit(page, Events.Page.request(), request)
  end

  defp _on_response(this, response, page) do
    emit(this, Events.BrowserContext.response(), response)
    if page = Page.from_nullable(page), do: emit(page, Events.Page.response(), response)
  end

  defp _on_request_failed(this, request, response_end_timing, failure_text, page) do
    put(request, :_failureText, failure_text || nil)
    Request._set_response_end_timing(request, response_end_timing)
    emit(this, Events.BrowserContext.request_failed(), request)
    if page = Page.from_nullable(page), do: emit(page, Events.Page.request_failed(), request)
  end

  defp _on_request_finished(this, params) do
    %{responseEndTiming: response_end_timing} = params
    request = Request.from(params.request)
    response = Response.from_nullable(params[:response])
    page = Page.from_nullable(params[:page])
    Request._set_response_end_timing(request, response_end_timing)
    emit(this, Events.BrowserContext.request_finished(), request)
    if page, do: emit(page, Events.Page.request_finished(), request)
    if response, do: Promise.resolve(get(response, :_finishedPromise), nil)
  end

  # _onRoute, _onWebSocketRoute  -- not ported: routing
  # _onBinding  -- not ported: BindingCall

  defp _service_worker_scope(_this, service_worker) do
    try do
      # new URL('.', serviceWorker.url()).href
      url = URI.to_string(URI.merge(URI.new!(Worker.url(service_worker)), "."))
      if !String.ends_with?(url, "/"), do: url <> "/", else: url
    rescue
      _ -> nil
    end
  end

  def set_default_navigation_timeout(this, timeout) do
    TimeoutSettings.set_default_navigation_timeout(get(this, :_timeoutSettings), timeout)
  end

  def set_default_timeout(this, timeout) do
    TimeoutSettings.set_default_timeout(get(this, :_timeoutSettings), timeout)
  end

  def browser(this) do
    get(this, :_browser)
  end

  def pages(this) do
    get(this, :_pages)
  end

  def is_closed(this) do
    get(this, :_closingStatus) != "none"
  end

  def new_page(this) do
    if get(this, :_ownerPage), do: raise("Please use browser.newContext()")
    Page.from(channel_call(this, :newPage, %{}, TimeoutSettings.k_no_timeout()).page)
  end

  def cookies(this, urls \\ nil) do
    urls = if !urls, do: [], else: urls
    urls = if is_binary(urls), do: [urls], else: urls
    channel_call(this, :cookies, %{urls: urls}, TimeoutSettings.k_no_timeout()).cookies
  end

  def add_cookies(this, cookies) do
    channel_call(this, :addCookies, %{cookies: cookies}, TimeoutSettings.k_no_timeout())
  end

  def clear_cookies(this, options \\ %{}) do
    channel_call(this, :clearCookies, Network.to_clear_cookies_params(options), TimeoutSettings.k_no_timeout())
  end

  def grant_permissions(this, permissions, options \\ nil) do
    channel_call(
      this,
      :grantPermissions,
      Map.merge(%{permissions: permissions}, options || %{}),
      TimeoutSettings.k_no_timeout()
    )
  end

  def clear_permissions(this) do
    channel_call(this, :clearPermissions, %{}, TimeoutSettings.k_no_timeout())
  end

  def set_geolocation(this, geolocation) do
    geolocation = if geolocation == :null, do: nil, else: geolocation
    channel_call(this, :setGeolocation, %{geolocation: geolocation || nil}, TimeoutSettings.k_no_timeout())
  end

  def set_extra_http_headers(this, headers) do
    Network.validate_headers(headers)

    channel_call(
      this,
      :setExtraHTTPHeaders,
      %{headers: Headers.headers_object_to_array(headers)},
      TimeoutSettings.k_no_timeout()
    )
  end

  def set_offline(this, offline) do
    channel_call(this, :setOffline, %{offline: offline}, TimeoutSettings.k_no_timeout())
  end

  def set_http_credentials(this, http_credentials) do
    http_credentials = if http_credentials == :null, do: nil, else: http_credentials

    channel_call(
      this,
      :setHTTPCredentials,
      %{httpCredentials: to_http_credentials_protocol(http_credentials || nil)},
      TimeoutSettings.k_no_timeout()
    )
  end

  # addInitScript, exposeBinding, _exposeCallbackBinding, exposeFunction  -- not ported: BindingCall, Disposable
  # route, routeWebSocket, routeFromHAR, _disposeHarRouters, unrouteAll, unroute  -- not ported: routing
  # _unrouteInternal, _updateInterceptionPatterns, _updateWebSocketInterceptionPatterns  -- not ported: routing

  def _effective_close_reason(this) do
    get(this, :_closeReason) || (get(this, :_browser) && get(get(this, :_browser), :_closeReason))
  end

  def wait_for_event(this, event, options_or_predicate \\ %{}) do
    options_or_predicate = options_or_predicate || %{}

    ChannelOwner._wrap_api_call(this, fn _ ->
      timeout_options =
        TimeoutSettings.timeout(
          get(this, :_timeoutSettings),
          if(is_function(options_or_predicate), do: %{}, else: options_or_predicate)
        )

      predicate = if is_function(options_or_predicate), do: options_or_predicate, else: options_or_predicate[:predicate]
      waiter = Waiter.create_for_event(this, event)

      Waiter.reject_on_timeout(
        waiter,
        timeout_options,
        ~s(Timeout #{timeout_options.timeout}ms exceeded while waiting for event "#{event}")
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

  # storageState, setStorageState  -- not ported

  def background_pages(_this) do
    []
  end

  def service_workers(this) do
    get(this, :_serviceWorkers)
  end

  # newCDPSession  -- not ported: CDPSession

  def _on_close(this) do
    put(this, :_closingStatus, "closed")

    if browser = get(this, :_browser) do
      set_delete(browser, :_contexts, this)
      set_delete(get(browser, :_browserType), :_contexts, this)
    end

    # this._browser?._browserType._playwright.selectors._contextsForSelectors.delete(this);  -- not ported: selectors
    # this._disposeHarRouters();  -- not ported: routing
    # this.tracing._resetStackCounter(); this.request.tracing._resetStackCounter();  -- not ported: Tracing
    emit(this, Events.BrowserContext.close(), this)
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def close(this, options \\ %{}) do
    if is_closed(this) do
      nil
    else
      put(this, :_closeReason, options[:reason])
      put(this, :_closingStatus, "closing")
      # await this.request.dispose(options);  -- not ported: APIRequestContext
      # await this._instrumentation.runBeforeCloseBrowserContext(this);  -- not ported: instrumentation
      # const harError = await this.tracing._exportAllHars().catch(e => e);  -- not ported: Tracing
      channel_call(this, :close, options, TimeoutSettings.k_no_timeout())
      Promise.await(get(this, :_closedPromise))
      nil
    end
  end

  # _showRecorder, _startRecording, _stopRecording, _exposeConsoleApi  -- not ported: recorder

  defp prepare_storage_state(storage_state) do
    if !is_binary(storage_state) do
      storage_state
    else
      try do
        JSON.decode!(File.read!(storage_state))
      rescue
        # rewriteErrorMessage(e, ...); throw e;  -- File and JSON errors have no message field: a RuntimeError
        e -> reraise "Error reading storage state from #{storage_state}:\n" <> Exception.message(e), __STACKTRACE__
      end
    end
  end

  def prepare_browser_context_params(options) do
    if options[:extraHTTPHeaders], do: Network.validate_headers(options.extraHTTPHeaders)

    context_params =
      Map.merge(options, %{
        viewport: if(options[:viewport] == :null, do: nil, else: options[:viewport]),
        noDefaultViewport: options[:viewport] == :null,
        extraHTTPHeaders: if(options[:extraHTTPHeaders], do: Headers.headers_object_to_array(options.extraHTTPHeaders)),
        storageState: if(options[:storageState], do: prepare_storage_state(options.storageState)),
        serviceWorkers: options[:serviceWorkers],
        colorScheme: if(options[:colorScheme] == :null, do: "no-override", else: options[:colorScheme]),
        reducedMotion: if(options[:reducedMotion] == :null, do: "no-override", else: options[:reducedMotion]),
        forcedColors: if(options[:forcedColors] == :null, do: "no-override", else: options[:forcedColors]),
        contrast: if(options[:contrast] == :null, do: "no-override", else: options[:contrast]),
        acceptDownloads: to_accept_downloads_protocol(options[:acceptDownloads]),
        clientCertificates: to_client_certificates_protocol(options[:clientCertificates]),
        httpCredentials: to_http_credentials_protocol(options[:httpCredentials])
      })

    if context_params[:recordVideo] && context_params.recordVideo[:dir],
      do: put_in(context_params, [:recordVideo, :dir], Path.expand(context_params.recordVideo.dir)),
      else: context_params
  end

  def to_http_credentials_protocol(credentials) do
    if !credentials do
      nil
    else
      list = if is_list(credentials), do: credentials, else: [credentials]
      if list != [], do: list
    end
  end

  defp to_accept_downloads_protocol(accept_downloads) do
    cond do
      accept_downloads == nil -> nil
      accept_downloads -> "accept"
      true -> "deny"
    end
  end

  def to_client_certificates_protocol(certs) do
    if !certs do
      nil
    else
      bufferize_content = fn value, file_path ->
        cond do
          value -> value
          file_path -> File.read!(file_path)
          true -> nil
        end
      end

      Enum.map(certs, fn cert ->
        %{
          origin: cert[:origin],
          cert: bufferize_content.(cert[:cert], cert[:certPath]),
          key: bufferize_content.(cert[:key], cert[:keyPath]),
          pfx: bufferize_content.(cert[:pfx], cert[:pfxPath]),
          passphrase: cert[:passphrase]
        }
      end)
    end
  end
end
