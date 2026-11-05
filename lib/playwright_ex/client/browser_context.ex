defmodule PlaywrightEx.Client.BrowserContext do
  @upstream "packages/playwright-core/src/client/browserContext.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.BrowserContext

  alias PlaywrightEx.Client.APIRequestContext
  alias PlaywrightEx.Client.BindingCall
  alias PlaywrightEx.Client.CDPSession
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.Clock
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.ConsoleMessage
  alias PlaywrightEx.Client.Credentials
  alias PlaywrightEx.Client.Debugger
  alias PlaywrightEx.Client.Dialog
  alias PlaywrightEx.Client.DisposableObject
  alias PlaywrightEx.Client.DisposableStub
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.FileUtils
  alias PlaywrightEx.Client.HarRouter
  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.Network
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Client.Route
  alias PlaywrightEx.Client.RouteHandler
  alias PlaywrightEx.Client.Tracing
  alias PlaywrightEx.Client.Waiter
  alias PlaywrightEx.Client.WebError
  alias PlaywrightEx.Client.WebSocketRoute
  alias PlaywrightEx.Client.WebSocketRouteHandler
  alias PlaywrightEx.Client.Worker
  alias PlaywrightEx.Isomorphic.Headers
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.TargetClosedError

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
    put(this, :debugger, Debugger.from(initializer.debugger))
    put(this, :tracing, Tracing.from(initializer.tracing))
    put(this, :request, APIRequestContext.from(initializer.requestContext))
    put(get(this, :request), :_timeoutSettings, get(this, :_timeoutSettings))
    put(this, :clock, Clock.new(this))
    put(this, :credentials, Credentials.new(this))

    EventEmitter.on(_channel(this), "bindingCall", fn %{binding: binding} ->
      _on_binding(this, BindingCall.from(binding))
    end)

    EventEmitter.on(_channel(this), "close", fn _ -> _on_close(this) end)
    EventEmitter.on(_channel(this), "page", fn %{page: page} -> _on_page(this, Page.from(page)) end)
    EventEmitter.on(_channel(this), "route", fn %{route: route} -> _on_route(this, Route.from(route)) end)

    EventEmitter.on(_channel(this), "webSocketRoute", fn %{webSocketRoute: web_socket_route} ->
      _on_web_socket_route(this, WebSocketRoute.from(web_socket_route))
    end)

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

  # readonly properties
  def debugger(this), do: get(this, :debugger)
  def request(this), do: get(this, :request)
  def tracing(this), do: get(this, :tracing)
  def clock(this), do: get(this, :clock)
  def credentials(this), do: get(this, :credentials)

  def _initialize_har_from_options(this, record_har) do
    if record_har do
      default_content = if String.ends_with?(record_har.path, ".zip"), do: "attach", else: "embed"

      Tracing._record_into_har(get(this, :tracing), record_har.path, nil, %{
        url: record_har[:urlFilter],
        updateContent:
          if(record_har[:content] == nil,
            do: if(record_har[:omitContent], do: "omit", else: default_content),
            else: record_har.content
          ),
        updateMode: if(record_har[:mode] == nil, do: "full", else: record_har.mode)
      })
    end

    nil
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

  def _on_route(this, route) do
    put(route, :_context, this)
    page = Request._safe_page(Route.request(route))
    route_handlers = get(this, :_routes)

    handled =
      Enum.reduce_while(route_handlers, false, fn route_handler, _ ->
        cond do
          # If the page or the context was closed we stall all requests right away.
          (page && get(page, :_closeWasCalled)) || is_closed(this) ->
            {:halt, true}

          !RouteHandler.matches(route_handler, Request.url(Route.request(route))) ->
            {:cont, false}

          route_handler not in get(this, :_routes) ->
            {:cont, false}

          true ->
            if RouteHandler.will_expire(route_handler), do: update(this, :_routes, &List.delete(&1, route_handler))
            handled = RouteHandler.handle(route_handler, route)

            if get(this, :_routes) == [],
              do:
                Promise.catch_(
                  Promise.async(fn -> _update_interception_patterns(this, %{internal: true}) end),
                  fn _ -> nil end
                )

            if handled, do: {:halt, true}, else: {:cont, false}
        end
      end)

    if !handled do
      # If the page is closed or unrouteAll() was called without waiting and interception disabled,
      # the method will throw an error - silence it.
      try do
        Route._inner_continue(route, true)
      rescue
        _ -> nil
      end
    end

    nil
  end

  def _on_web_socket_route(this, web_socket_route) do
    route_handler =
      Enum.find(get(this, :_webSocketRoutes), &WebSocketRouteHandler.matches(&1, WebSocketRoute.url(web_socket_route)))

    if route_handler,
      do: WebSocketRouteHandler.handle(route_handler, web_socket_route),
      else: WebSocketRoute.connect_to_server(web_socket_route)

    nil
  end

  def _on_binding(this, binding_call) do
    func = map_get(this, :_bindings, get(binding_call, :_initializer).name)
    if func, do: BindingCall.call(binding_call, func)
  end

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

  def add_init_script(this, script, arg \\ nil, options \\ nil) do
    JSHandle.assert_evaluate_options(options)

    if options[:exposeFunctions] do
      Page.add_init_script_with_exposed_functions(this, script, arg)
    else
      source = ClientHelper.evaluation_script(script, arg)

      DisposableObject.from(
        channel_call(this, :addInitScript, %{source: source}, TimeoutSettings.k_no_timeout()).disposable
      )
    end
  end

  # Bindings take the source and the list of arguments: `(source, ...args) => ...`.
  def expose_binding(this, name, callback) do
    result = channel_call(this, :exposeBinding, %{name: name}, TimeoutSettings.k_no_timeout())
    # this._bindings.set(name, callback): called with (source, ...args)
    map_set(this, :_bindings, name, fn source, args -> ClientHelper.call_function(callback, [source | args]) end)
    DisposableObject.from(result.disposable)
  end

  def _expose_callback_binding(this, name, callback) do
    map_set(this, :_bindings, name, fn _source, args -> ClientHelper.call_function(callback, args) end)
    result = channel_call(this, :exposeBinding, %{name: name, noGlobal: true}, TimeoutSettings.k_no_timeout())
    DisposableObject.from(result.disposable)
  end

  def expose_function(this, name, callback) do
    result = channel_call(this, :exposeBinding, %{name: name}, TimeoutSettings.k_no_timeout())
    binding = fn _source, args -> ClientHelper.call_function(callback, args) end
    map_set(this, :_bindings, name, binding)
    DisposableObject.from(result.disposable)
  end

  def route(this, url, handler, options \\ %{}) do
    options = options || %{}

    route_handler =
      RouteHandler.new(
        Connection.local_utils(get(this, :_connection)),
        get(this, :_options)[:baseURL],
        url,
        handler,
        options[:times]
      )

    update(this, :_routes, &[route_handler | &1])
    _update_interception_patterns(this, %{title: "Route requests"})
    DisposableStub.new(fn -> unroute(this, url, handler) end)
  end

  def route_web_socket(this, url, handler) do
    route_handler =
      WebSocketRouteHandler.new(
        Connection.local_utils(get(this, :_connection)),
        get(this, :_options)[:baseURL],
        url,
        handler
      )

    update(this, :_webSocketRoutes, &[route_handler | &1])
    _update_web_socket_interception_patterns(this, %{title: "Route WebSockets"})
  end

  def route_from_har(this, har, options \\ %{}) do
    options = options || %{}
    local_utils = Connection.local_utils(get(this, :_connection))
    if !local_utils, do: raise("Route from har is not supported in thin clients")

    if options[:update] do
      Tracing._record_into_har(get(this, :tracing), har, nil, options)
    else
      har_router = HarRouter.create(local_utils, har, options[:notFound] || "abort", %{urlMatch: options[:url]})
      update(this, :_harRouters, &(&1 ++ [har_router]))
      HarRouter.add_context_route(har_router, this)
    end

    nil
  end

  defp _dispose_har_routers(this) do
    for router <- get(this, :_harRouters), do: HarRouter.dispose(router)
    put(this, :_harRouters, [])
  end

  def unroute_all(this, options \\ nil) do
    _unroute_internal(this, get(this, :_routes), [], (options || %{})[:behavior])
    _dispose_har_routers(this)
    nil
  end

  def unroute(this, url, handler \\ nil) do
    {removed, remaining} =
      Enum.split_with(get(this, :_routes), fn route ->
        UrlMatch.url_matches_equal(get(route, :url), url) and (!handler or get(route, :handler) == handler)
      end)

    _unroute_internal(this, removed, remaining, "default")
  end

  defp _unroute_internal(this, removed, remaining, behavior) do
    put(this, :_routes, remaining)

    if behavior && behavior != "default" do
      promises =
        Enum.map(removed, fn route_handler -> Promise.async(fn -> RouteHandler.stop(route_handler, behavior) end) end)

      Promise.await(Promise.all(promises))
    end

    _update_interception_patterns(this, %{title: "Unroute requests"})
  end

  defp _update_interception_patterns(this, options) do
    patterns = RouteHandler.prepare_interception_patterns(get(this, :_routes))

    _wrap_api_call(
      this,
      fn _ ->
        channel_call(this, :setNetworkInterceptionPatterns, %{patterns: patterns}, TimeoutSettings.k_no_timeout())
      end,
      options
    )

    nil
  end

  defp _update_web_socket_interception_patterns(this, options) do
    patterns = WebSocketRouteHandler.prepare_interception_patterns(get(this, :_webSocketRoutes))

    _wrap_api_call(
      this,
      fn _ ->
        channel_call(this, :setWebSocketInterceptionPatterns, %{patterns: patterns}, TimeoutSettings.k_no_timeout())
      end,
      options
    )

    nil
  end

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
            TargetClosedError.new(_effective_close_reason(this))
          end)

      result = Waiter.wait_for_event(waiter, this, event, predicate)
      Waiter.dispose(waiter)
      result
    end)
  end

  def storage_state(this, options \\ %{}) do
    options = options || %{}

    state =
      channel_call(
        this,
        :storageState,
        %{indexedDB: options[:indexedDB], opfs: options[:opfs], credentials: options[:credentials]},
        TimeoutSettings.k_no_timeout()
      )

    if options[:path] do
      FileUtils.mkdir_if_needed(options.path)
      File.write!(options.path, ClientHelper.json_stringify_indented(state, 2))
    end

    state
  end

  def set_storage_state(this, storage_state) do
    state = prepare_storage_state(storage_state)
    channel_call(this, :setStorageState, %{storageState: state}, TimeoutSettings.k_no_timeout())
    nil
  end

  def background_pages(_this) do
    []
  end

  def service_workers(this) do
    get(this, :_serviceWorkers)
  end

  def new_cdp_session(this, page) do
    # channelOwner.ts's validation messages don't handle the pseudo-union type, so we're explicit here
    if !match?(%PlaywrightEx.Page{}, page) and !match?(%PlaywrightEx.Frame{}, page),
      do: raise("page: expected Page or Frame")

    result =
      channel_call(
        this,
        :newCDPSession,
        if(match?(%PlaywrightEx.Page{}, page), do: %{page: page}, else: %{frame: page}),
        TimeoutSettings.k_no_timeout()
      )

    CDPSession.from(result.session)
  end

  def _on_close(this) do
    put(this, :_closingStatus, "closed")

    if browser = get(this, :_browser) do
      set_delete(browser, :_contexts, this)
      set_delete(get(browser, :_browserType), :_contexts, this)
      set_delete(get(get(get(browser, :_browserType), :_playwright), :selectors), :_contextsForSelectors, this)
    end

    _dispose_har_routers(this)
    Tracing._reset_stack_counter(get(this, :tracing))
    Tracing._reset_stack_counter(get(get(this, :request), :tracing))
    emit(this, Events.BrowserContext.close(), this)
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def close(this, options \\ %{}) do
    if is_closed(this) do
      nil
    else
      put(this, :_closeReason, options[:reason])
      put(this, :_closingStatus, "closing")
      APIRequestContext.dispose(get(this, :request), options)
      # await this._instrumentation.runBeforeCloseBrowserContext(this);  -- not ported: instrumentation
      har_error =
        try do
          Tracing._export_all_hars(get(this, :tracing))
          nil
        rescue
          e -> e
        end

      channel_call(this, :close, options, TimeoutSettings.k_no_timeout())
      Promise.await(get(this, :_closedPromise))
      if har_error, do: raise(har_error)
      nil
    end
  end

  def _show_recorder(this, params) do
    channel_call(this, :showRecorder, params, TimeoutSettings.k_no_timeout())
    nil
  end

  # _startRecording, _stopRecording  -- not ported: recorder (its event sink)

  def _expose_console_api(this) do
    channel_call(this, :exposeConsoleApi, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  defp prepare_storage_state(storage_state) do
    if !is_binary(storage_state) do
      storage_state
    else
      try do
        JSON.decode!(File.read!(storage_state))
      rescue
        e ->
          message = "Error reading storage state from #{storage_state}:\n" <> Exception.message(e)
          # A File.Error has no message field to rewrite: a RuntimeError.
          e =
            if Map.has_key?(e, :message),
              do: Errors.rewrite_error_message(e, message),
              else: RuntimeError.exception(message)

          reraise e, __STACKTRACE__
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
