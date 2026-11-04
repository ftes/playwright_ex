# upstream: packages/playwright-core/src/client/browserContext.ts
defmodule PlaywrightJS.Client.BrowserContext do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.{ConsoleMessage, Connection.DummyChannelOwner, Dialog, Errors, Page, Waiter}
  alias PlaywrightJS.Client.Network.{Route, RouteHandler}
  alias PlaywrightJS.Isomorphic.UrlMatch

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
    put(this, :_routes, [])
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

    EventEmitter.on(_channel(this), "bindingCall", fn %{binding: binding} -> _on_binding(this, Page.BindingCall.from(binding)) end)
    EventEmitter.on(_channel(this), "close", fn _ -> _on_close(this) end)
    EventEmitter.on(_channel(this), "page", fn %{page: page} -> _on_page(this, Page.from(page)) end)
    EventEmitter.on(_channel(this), "route", fn %{route: route} -> _on_route(this, Route.from(route)) end)
    # webSocketRoute, serviceWorker  -- not ported

    EventEmitter.on(_channel(this), "console", fn event ->
      # const worker = Worker.fromNullable(event.worker);  -- not ported: Worker
      page = Page.from_nullable(event[:page])
      console_message = ConsoleMessage.new(event, page, nil)
      # worker?.emit(Events.Worker.Console, consoleMessage);  -- not ported: Worker
      if page, do: Page.emit(page, Events.Page.console(), console_message)
      # if (worker && this._serviceWorkers.has(worker)) ...  -- not ported: Worker
      emit(this, Events.BrowserContext.console(), console_message)
    end)

    # pageError  -- not ported

    EventEmitter.on(_channel(this), "dialog", fn %{dialog: dialog} ->
      dialog_object = Dialog.from(dialog)
      has_listeners = emit(this, Events.BrowserContext.dialog(), dialog_object)
      page = Dialog.page(dialog_object)
      has_listeners = if page, do: Page.emit(page, Events.Page.dialog(), dialog_object) || has_listeners, else: has_listeners

      if !has_listeners do
        # Although we do similar handling on the server side, we still need this logic
        # on the client side due to a possible race condition between two async calls:
        # a) removing "dialog" listener subscription (client->server)
        # b) actual "dialog" event (server->client)
        if Dialog.type(dialog_object) == "beforeunload",
          do: Promise.catch_(Promise.async(this.conn, fn -> channel_call(dialog, :accept, %{}, TimeoutSettings.k_no_timeout()) end), fn _ -> nil end),
          else: Promise.catch_(Promise.async(this.conn, fn -> channel_call(dialog, :dismiss, %{}, TimeoutSettings.k_no_timeout()) end), fn _ -> nil end)
      end
    end)

    EventEmitter.on(_channel(this), "dialogClosed", fn %{dialog: dialog} ->
      dialog_object = Dialog.from(dialog)
      emit(this, Events.BrowserContext.dialog_closed(), dialog_object)
      page = Dialog.page(dialog_object)
      if page, do: Page.emit(page, Events.Page.dialog_closed(), dialog_object)
    end)

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

  # upstream: browserContext.ts:242
  def _on_route(this, route) do
    put(route, :_context, this)
    page = PlaywrightJS.Client.Network.Request._safe_page(Route.request(route))
    route_handlers = get(this, :_routes)

    result =
      Enum.reduce_while(route_handlers, :continue, fn route_handler, _ ->
        cond do
          # If the page or the context was closed we stall all requests right away.
          (page && get(page, :_closeWasCalled)) || is_closed(this) ->
            {:halt, :return}

          !RouteHandler.matches(route_handler, PlaywrightJS.Client.Network.Request.url(Route.request(route))) ->
            {:cont, :continue}

          route_handler not in get(this, :_routes) ->
            {:cont, :continue}

          true ->
            if RouteHandler.will_expire(route_handler), do: update(this, :_routes, &List.delete(&1, route_handler))
            handled = RouteHandler.handle(route_handler, route)

            if get(this, :_routes) == [],
              do: Promise.catch_(Promise.async(this.conn, fn -> _update_interception_patterns(this, %{internal: true}) end), fn _ -> nil end)

            if handled, do: {:halt, :return}, else: {:cont, :continue}
        end
      end)

    if result == :continue do
      # If the page is closed or unrouteAll() was called without waiting and interception disabled,
      # the method will throw an error - silence it.
      try do
        Route._inner_continue(route, true)
      rescue
        _ -> nil
      end
    end
  end

  # upstream: browserContext.ts:276
  def _on_binding(this, binding_call) do
    func = map_get(this, :_bindings, get(binding_call, :_initializer).name)
    if !func, do: nil, else: Page.BindingCall.call(binding_call, func)
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

  # upstream: browserContext.ts:369
  # `(source, ...args)` callbacks receive the rest arguments as a list.
  def expose_binding(this, name, callback) do
    result = channel_call(this, :exposeBinding, %{name: name}, TimeoutSettings.k_no_timeout())
    map_set(this, :_bindings, name, fn source, args -> apply(callback, [source | args]) end)
    # return DisposableObject.from(result.disposable);  -- not ported: Disposable
    result[:disposable]
  end

  # upstream: browserContext.ts:381
  def expose_function(this, name, callback) do
    result = channel_call(this, :exposeBinding, %{name: name}, TimeoutSettings.k_no_timeout())
    binding = fn _source, args -> apply(callback, args) end
    map_set(this, :_bindings, name, binding)
    # return DisposableObject.from(result.disposable);  -- not ported: Disposable
    result[:disposable]
  end

  # upstream: browserContext.ts:388
  def route(this, url, handler, options \\ %{}) do
    route_handler = RouteHandler.new(get(this, :_options)[:baseURL], url, handler, options[:times], get(this, :_connection))
    update(this, :_routes, &[route_handler | &1])
    _update_interception_patterns(this, %{title: "Route requests"})
    # return new DisposableStub(() => this.unroute(url, handler));  -- not ported: Disposable
    nil
  end

  # upstream: browserContext.ts:417
  def unroute_all(this, options \\ nil) do
    _unroute_internal(this, get(this, :_routes), [], (options || %{})[:behavior])
    # this._disposeHarRouters();  -- not ported: HAR
  end

  # upstream: browserContext.ts:422
  def unroute(this, url, handler \\ nil) do
    {removed, remaining} =
      Enum.split_with(get(this, :_routes), fn route ->
        UrlMatch.url_matches_equal(get(route, :url), url) and (!handler or get(route, :handler) == handler)
      end)

    _unroute_internal(this, removed, remaining, "default")
  end

  # upstream: browserContext.ts:434
  defp _unroute_internal(this, removed, remaining, behavior) do
    put(this, :_routes, remaining)

    if behavior && behavior != "default" do
      promises = Enum.map(removed, fn route_handler -> Promise.async(this.conn, fn -> RouteHandler.stop(route_handler, behavior) end) end)
      Promise.await(Promise.all(this.conn, promises))
    end

    _update_interception_patterns(this, %{title: "Unroute requests"})
    nil
  end

  # upstream: browserContext.ts:443
  defp _update_interception_patterns(this, options) do
    patterns = RouteHandler.prepare_interception_patterns(get(this, :_routes))

    _wrap_api_call(
      this,
      fn _ -> channel_call(this, :setNetworkInterceptionPatterns, %{patterns: patterns}, TimeoutSettings.k_no_timeout()) end,
      options
    )
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
