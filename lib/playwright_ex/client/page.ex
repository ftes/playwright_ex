defmodule PlaywrightEx.Client.Page do
  @upstream "packages/playwright-core/src/client/page.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.Page

  alias PlaywrightEx.AbortError
  alias PlaywrightEx.Client.Artifact
  alias PlaywrightEx.Client.BindingCall
  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.ConsoleMessage
  alias PlaywrightEx.Client.Coverage
  alias PlaywrightEx.Client.DisposableObject
  alias PlaywrightEx.Client.DisposableStub
  alias PlaywrightEx.Client.Download
  alias PlaywrightEx.Client.ElementHandle
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.FileChooser
  alias PlaywrightEx.Client.FileUtils
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.HarRouter
  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.Keyboard
  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Client.Mouse
  alias PlaywrightEx.Client.Network
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Client.Route
  alias PlaywrightEx.Client.RouteHandler
  alias PlaywrightEx.Client.Screencast
  alias PlaywrightEx.Client.Touchscreen
  alias PlaywrightEx.Client.Tracing
  alias PlaywrightEx.Client.Video
  alias PlaywrightEx.Client.Waiter
  alias PlaywrightEx.Client.WebSocket
  alias PlaywrightEx.Client.WebSocketRoute
  alias PlaywrightEx.Client.WebSocketRouteHandler
  alias PlaywrightEx.Client.WebStorage
  alias PlaywrightEx.Client.Worker
  alias PlaywrightEx.Isomorphic.AbortSignal
  alias PlaywrightEx.Isomorphic.Headers
  alias PlaywrightEx.Isomorphic.LongStandingScope
  alias PlaywrightEx.Isomorphic.StringUtils
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.Runtime.Node
  alias PlaywrightEx.TargetClosedError

  def from(page) do
    page
  end

  def from_nullable(page) do
    if page, do: from(page)
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_ownedContext, nil)
    put(this, :_apiName, "Page")
    put(this, :_frames, [])
    put(this, :_workers, [])
    put(this, :_closed, false)
    put(this, :_closedOrCrashedScope, LongStandingScope.new(this))
    put(this, :_routes, [])
    put(this, :_webSocketRoutes, [])
    put(this, :_closeWasCalled, false)
    put(this, :_harRouters, [])
    put(this, :_evaluateCallbacks, [])
    ClientInstrumentation.on_page(get(this, :_instrumentation), this)
    put(this, :_browserContext, parent)
    put(this, :_timeoutSettings, TimeoutSettings.new(get(parent, :_timeoutSettings), this))

    put(this, :keyboard, Keyboard.new(this))
    put(this, :mouse, Mouse.new(this))
    put(this, :request, get(parent, :request))
    put(this, :touchscreen, Touchscreen.new(this))
    put(this, :clock, get(get(this, :_browserContext), :clock))
    put(this, :localStorage, WebStorage.new(this, "local"))
    put(this, :sessionStorage, WebStorage.new(this, "session"))

    put(this, :_mainFrame, Frame.from(initializer.mainFrame))
    put(get(this, :_mainFrame), :_page, this)
    put(this, :webmcp, get(get(this, :_mainFrame), :webmcp))
    set_add(this, :_frames, get(this, :_mainFrame))
    put(this, :_viewportSize, initializer[:viewportSize])
    put(this, :_closed, initializer.isClosed)
    put(this, :_opener, from_nullable(initializer[:opener]))

    put(
      this,
      :_video,
      Video.new(get(this, :_connection), if(initializer[:video], do: Artifact.from(initializer.video)))
    )

    put(this, :screencast, Screencast.new(this))

    EventEmitter.on(_channel(this), "bindingCall", fn %{binding: binding} ->
      _on_binding(this, BindingCall.from(binding))
    end)

    EventEmitter.on(_channel(this), "close", fn _ -> _on_close(this) end)
    EventEmitter.on(_channel(this), "crash", fn _ -> _on_crash(this) end)

    EventEmitter.on(_channel(this), "download", fn %{
                                                     url: url,
                                                     suggestedFilename: suggested_filename,
                                                     artifact: artifact
                                                   } ->
      artifact_object = Artifact.from(artifact)
      download = Download.new(this, url, suggested_filename, artifact_object)
      emit(this, Events.Page.download(), download)
      emit(get(this, :_browserContext), Events.BrowserContext.download(), download)
    end)

    EventEmitter.on(_channel(this), "fileChooser", fn %{element: element, isMultiple: is_multiple} ->
      emit(this, Events.Page.file_chooser(), FileChooser.new(this, ElementHandle.from(element), is_multiple))
    end)

    # Elixir only: on_sync, a pure state update.
    EventEmitter.on_sync(_channel(this), "frameAttached", fn %{frame: frame} ->
      _on_frame_attached(this, Frame.from(frame))
    end)

    # Elixir only: on_sync, a pure state update.
    EventEmitter.on_sync(_channel(this), "frameDetached", fn %{frame: frame} ->
      _on_frame_detached(this, Frame.from(frame))
    end)

    EventEmitter.on(_channel(this), "locatorHandlerTriggered", fn %{uid: uid} ->
      _on_locator_handler_triggered(this, uid)
    end)

    EventEmitter.on(_channel(this), "route", fn %{route: route} -> _on_route(this, Route.from(route)) end)

    EventEmitter.on(_channel(this), "webSocketRoute", fn %{webSocketRoute: web_socket_route} ->
      _on_web_socket_route(this, WebSocketRoute.from(web_socket_route))
    end)

    # Elixir only: on_sync, a pure state update.
    EventEmitter.on_sync(_channel(this), "viewportSizeChanged", fn event ->
      put(this, :_viewportSize, event[:viewportSize])
    end)

    EventEmitter.on(_channel(this), "webSocket", fn %{webSocket: web_socket} ->
      emit(this, Events.Page.web_socket(), WebSocket.from(web_socket))
    end)

    EventEmitter.on(_channel(this), "worker", fn %{worker: worker} -> _on_worker(this, Worker.from(worker)) end)

    put(this, :coverage, Coverage.new(this))

    once(this, Events.Page.close(), fn _ ->
      LongStandingScope.close(get(this, :_closedOrCrashedScope), _close_error_with_reason(this))
    end)

    once(this, Events.Page.crash(), fn _ ->
      LongStandingScope.close(get(this, :_closedOrCrashedScope), TargetClosedError.new())
    end)

    _set_event_to_subscription_mapping(this, %{
      Events.Page.console() => "console",
      Events.Page.dialog() => "dialog",
      Events.Page.dialog_closed() => "dialogClosed",
      Events.Page.request() => "request",
      Events.Page.response() => "response",
      Events.Page.request_finished() => "requestFinished",
      Events.Page.request_failed() => "requestFailed",
      Events.Page.file_chooser() => "fileChooser"
    })

    this
  end

  # readonly properties
  def keyboard(this), do: get(this, :keyboard)
  def mouse(this), do: get(this, :mouse)
  def request(this), do: get(this, :request)
  def touchscreen(this), do: get(this, :touchscreen)
  def coverage(this), do: get(this, :coverage)
  def clock(this), do: get(this, :clock)
  def screencast(this), do: get(this, :screencast)
  def local_storage(this), do: get(this, :localStorage)
  def session_storage(this), do: get(this, :sessionStorage)
  def webmcp(this), do: get(this, :webmcp)

  defp _on_frame_attached(this, frame) do
    put(frame, :_page, this)
    set_add(this, :_frames, frame)
    if parent_frame = get(frame, :_parentFrame), do: set_add(parent_frame, :_childFrames, frame)
    emit(this, Events.Page.frame_attached(), frame)
    emit(get(this, :_browserContext), Events.BrowserContext.frame_attached(), frame)
  end

  defp _on_frame_detached(this, frame) do
    set_delete(this, :_frames, frame)
    put(frame, :_detached, true)
    if parent_frame = get(frame, :_parentFrame), do: set_delete(parent_frame, :_childFrames, frame)
    emit(this, Events.Page.frame_detached(), frame)
    emit(get(this, :_browserContext), Events.BrowserContext.frame_detached(), frame)
  end

  defp _on_route(this, route) do
    put(route, :_context, context(this))
    route_handlers = get(this, :_routes)

    handled =
      Enum.reduce_while(route_handlers, false, fn route_handler, _ ->
        cond do
          # If the page was closed we stall all requests right away.
          get(this, :_closeWasCalled) or BrowserContext.is_closed(get(this, :_browserContext)) ->
            {:halt, true}

          !RouteHandler.matches(route_handler, Request.url(Route.request(route))) ->
            {:cont, false}

          route_handler not in get(this, :_routes) ->
            {:cont, false}

          true ->
            if RouteHandler.will_expire(route_handler), do: update(this, :_routes, &List.delete(&1, route_handler))
            handled = RouteHandler.handle(route_handler, route)

            if get(this, :_routes) == [],
              do: Promise.void(fn -> _update_interception_patterns(this, %{internal: true}) end)

            if handled, do: {:halt, true}, else: {:cont, false}
        end
      end)

    if !handled, do: BrowserContext._on_route(get(this, :_browserContext), route)
  rescue
    # deviation: a callback rejected by its route's teardown is not logged (RouteHandler).
    e -> RouteHandler._reraise_unless_teardown(e, __STACKTRACE__)
  end

  defp _on_web_socket_route(this, web_socket_route) do
    route_handler =
      Enum.find(get(this, :_webSocketRoutes), &WebSocketRouteHandler.matches(&1, WebSocketRoute.url(web_socket_route)))

    if route_handler,
      do: WebSocketRouteHandler.handle(route_handler, web_socket_route),
      else: BrowserContext._on_web_socket_route(get(this, :_browserContext), web_socket_route)
  end

  def _on_binding(this, binding_call) do
    func = map_get(this, :_bindings, get(binding_call, :_initializer).name)

    if func do
      BindingCall.call(binding_call, func)
    else
      BrowserContext._on_binding(get(this, :_browserContext), binding_call)
    end
  end

  def _on_worker(this, worker) do
    set_add(this, :_workers, worker)
    put(worker, :_page, this)
    emit(this, Events.Page.worker(), worker)
  end

  def _on_close(this) do
    put(this, :_closed, true)
    set_delete(get(this, :_browserContext), :_pages, this)
    _dispose_har_routers(this)
    emit(this, Events.Page.close(), this)
    emit(get(this, :_browserContext), Events.BrowserContext.page_close(), this)
  end

  defp _on_crash(this) do
    emit(this, Events.Page.crash(), this)
  end

  def context(this) do
    get(this, :_browserContext)
  end

  def opener(this) do
    opener = get(this, :_opener)
    if !opener or is_closed(opener), do: nil, else: opener
  end

  def main_frame(this) do
    get(this, :_mainFrame)
  end

  def frame(this, frame_selector) do
    name = if is_binary(frame_selector), do: frame_selector, else: frame_selector[:name]
    url = if is_map(frame_selector), do: frame_selector[:url]
    if !(name || url), do: raise("Either name or url matcher should be specified")

    Enum.find(frames(this), fn f ->
      # The LocalUtils comes first: globs become regexes through the driver (UrlMatch).
      if name,
        do: Frame.name(f) == name,
        else:
          UrlMatch.url_matches(
            Connection.local_utils(get(this, :_connection)),
            get(get(this, :_browserContext), :_options)[:baseURL],
            Frame.url(f),
            url
          )
    end)
  end

  def frames(this) do
    get(this, :_frames)
  end

  def set_default_navigation_timeout(this, timeout) do
    TimeoutSettings.set_default_navigation_timeout(get(this, :_timeoutSettings), timeout)
  end

  def set_default_timeout(this, timeout) do
    TimeoutSettings.set_default_timeout(get(this, :_timeoutSettings), timeout)
  end

  def video(this) do
    # Note: we are creating Video object lazily, because we do not know
    # BrowserContextOptions when constructing the page - it is assigned
    # too late during launchPersistentContext.
    if !get(get(this, :_browserContext), :_options)[:recordVideo],
      do: nil,
      else: get(this, :_video)
  end

  def pick_locator(this) do
    %{selector: selector} = channel_call(this, :pickLocator, %{}, TimeoutSettings.k_no_timeout())
    locator(this, selector)
  end

  def cancel_pick_locator(this) do
    channel_call(this, :cancelPickLocator, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def hide_highlight(this) do
    channel_call(this, :hideHighlight, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  # $  -- ported as query_selector/3
  def query_selector(this, selector, options \\ nil) do
    Frame.query_selector(get(this, :_mainFrame), selector, options)
  end

  def wait_for_selector(this, selector, options \\ nil) do
    Frame.wait_for_selector(get(this, :_mainFrame), selector, options || %{})
  end

  def dispatch_event(this, selector, type, event_init \\ nil, options \\ %{}) do
    Frame.dispatch_event(get(this, :_mainFrame), selector, type, event_init, options || %{})
  end

  def evaluate_handle(this, page_function, arg \\ nil, options \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    Frame.evaluate_handle(get(this, :_mainFrame), page_function, arg, options)
  end

  # $eval  -- ported as eval_on_selector/4
  def eval_on_selector(this, selector, page_function, arg \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    Frame.eval_on_selector(get(this, :_mainFrame), selector, page_function, arg)
  end

  # $$eval  -- ported as eval_on_selector_all/4
  def eval_on_selector_all(this, selector, page_function, arg \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    Frame.eval_on_selector_all(get(this, :_mainFrame), selector, page_function, arg)
  end

  # $$  -- ported as query_selector_all/2
  def query_selector_all(this, selector) do
    Frame.query_selector_all(get(this, :_mainFrame), selector)
  end

  def add_script_tag(this, options \\ %{}) do
    Frame.add_script_tag(get(this, :_mainFrame), options || %{})
  end

  def add_style_tag(this, options \\ %{}) do
    Frame.add_style_tag(get(this, :_mainFrame), options || %{})
  end

  # Bindings take the source and the list of arguments: `(source, ...args) => ...`.
  # The statements after the await run on reply, before a bindingCall (`channel_call/5`).
  def expose_function(this, name, callback) do
    result =
      channel_call(this, :exposeBinding, %{name: name}, TimeoutSettings.k_no_timeout(), fn _ ->
        binding = fn _source, args -> ClientHelper.call_function(callback, args) end
        map_set(this, :_bindings, name, binding)
      end)

    DisposableObject.from(result.disposable)
  end

  def expose_binding(this, name, callback) do
    result =
      channel_call(this, :exposeBinding, %{name: name}, TimeoutSettings.k_no_timeout(), fn _ ->
        # this._bindings.set(name, callback): called with (source, ...args)
        map_set(this, :_bindings, name, fn source, args -> ClientHelper.call_function(callback, [source | args]) end)
      end)

    DisposableObject.from(result.disposable)
  end

  def _expose_callback_binding(this, name, callback) do
    map_set(this, :_bindings, name, fn _source, args -> ClientHelper.call_function(callback, args) end)
    result = channel_call(this, :exposeBinding, %{name: name, noGlobal: true}, TimeoutSettings.k_no_timeout())
    DisposableObject.from(result.disposable)
  end

  def _expose_evaluate_callback(this, name, callback) do
    disposable = _expose_callback_binding(this, name, callback)
    update(this, :_evaluateCallbacks, &(&1 ++ [%{name: name, disposable: disposable}]))
    nil
  end

  def _erase_evaluate_callbacks(this) do
    for %{name: name, disposable: disposable} <- get(this, :_evaluateCallbacks) do
      map_delete(this, :_bindings, name)
      Promise.void(fn -> DisposableObject.dispose(disposable) end)
    end

    put(this, :_evaluateCallbacks, [])
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

  def url(this) do
    Frame.url(get(this, :_mainFrame))
  end

  def content(this, options \\ nil) do
    Frame.content(get(this, :_mainFrame), options || %{})
  end

  def set_content(this, html, options \\ nil) do
    Frame.set_content(get(this, :_mainFrame), html, options || %{})
  end

  def goto(this, url, options \\ nil) do
    Frame.goto(get(this, :_mainFrame), url, options || %{})
  end

  def reload(this, options \\ %{}) do
    wait_until =
      Frame.verify_load_state("waitUntil", if(options[:waitUntil] == nil, do: "load", else: options.waitUntil))

    Response.from_nullable(
      channel_call(
        this,
        :reload,
        Map.put(options, :waitUntil, wait_until),
        TimeoutSettings.navigation_timeout(get(this, :_timeoutSettings), options)
      )[:response]
    )
  end

  def add_locator_handler(this, locator, handler, options \\ %{}) do
    options = options || %{}
    if locator._frame != get(this, :_mainFrame), do: raise("Locator must belong to the main frame of this page")

    if options[:times] == 0 do
      nil
    else
      # The statement after the await runs on reply, before a locatorHandlerTriggered (`channel_call/5`).
      channel_call(
        this,
        :registerLocatorHandler,
        %{selector: locator._selector, noWaitAfter: options[:noWaitAfter]},
        TimeoutSettings.k_no_timeout(),
        fn %{uid: uid} ->
          map_set(this, :_locatorHandlers, uid, %{locator: locator, handler: handler, times: options[:times]})
        end
      )

      nil
    end
  end

  defp _on_locator_handler_triggered(this, uid) do
    # `try {} finally {}` with `let remove` assigned in `try`: the `try` returns it (`false` when
    # the handler raises), the `finally` statements follow, then the error is raised again.
    {remove, error} =
      try do
        # handler.times--: the entry is a value, written back in one atomic step with the read.
        {handler, run} =
          atomic(this, fn ->
            handler = map_get(this, :_locatorHandlers, uid)

            cond do
              !handler or handler.times == 0 ->
                {handler, false}

              handler.times != nil ->
                {map_set(this, :_locatorHandlers, uid, %{handler | times: handler.times - 1}), true}

              true ->
                {handler, true}
            end
          end)

        if run do
          result = ClientHelper.call_function(handler.handler, [handler.locator])
          if is_struct(result, Promise), do: Promise.await(result)
        end

        {handler != nil and handler.times == 0, nil}
      rescue
        e -> {false, {e, __STACKTRACE__}}
      end

    if remove, do: map_delete(this, :_locatorHandlers, uid)

    Promise.void(fn ->
      channel_call(this, :resolveLocatorHandlerNoReply, %{uid: uid, remove: remove}, TimeoutSettings.k_no_timeout())
    end)

    with {e, stacktrace} <- error, do: reraise(e, stacktrace)
  end

  def remove_locator_handler(this, locator) do
    for {uid, data} <- map_entries(this, :_locatorHandlers) do
      if Locator._equals(data.locator, locator) do
        map_delete(this, :_locatorHandlers, uid)

        try do
          channel_call(this, :unregisterLocatorHandler, %{uid: uid}, TimeoutSettings.k_no_timeout())
        rescue
          _ -> nil
        end
      end
    end

    nil
  end

  def wait_for_load_state(this, state \\ nil, options \\ nil) do
    Frame.wait_for_load_state(get(this, :_mainFrame), state, options)
  end

  def wait_for_navigation(this, options \\ nil) do
    Frame.wait_for_navigation(get(this, :_mainFrame), options || %{})
  end

  def wait_for_url(this, url, options \\ nil) do
    Frame.wait_for_url(get(this, :_mainFrame), url, options)
  end

  def wait_for_request(this, url_or_predicate, options \\ %{}) do
    options = options || %{}

    predicate = fn request ->
      if is_binary(url_or_predicate) or PlaywrightEx.RegExp.reg_exp?(url_or_predicate) do
        _url_matches(this, Request.url(request), url_or_predicate)
      else
        # await urlOrPredicate(request): a returned promise is awaited
        result = url_or_predicate.(request)
        if is_struct(result, Promise), do: Promise.await(result), else: result
      end
    end

    trimmed_url = trim_url(url_or_predicate)
    log_line = if trimmed_url, do: "waiting for request #{trimmed_url}"

    _wait_for_event(
      this,
      Events.Page.request(),
      %{predicate: predicate, timeout: options[:timeout], signal: options[:signal]},
      log_line
    )
  end

  def wait_for_response(this, url_or_predicate, options \\ %{}) do
    options = options || %{}

    predicate = fn response ->
      if is_binary(url_or_predicate) or PlaywrightEx.RegExp.reg_exp?(url_or_predicate) do
        _url_matches(this, Response.url(response), url_or_predicate)
      else
        # await urlOrPredicate(response): a returned promise is awaited
        result = url_or_predicate.(response)
        if is_struct(result, Promise), do: Promise.await(result), else: result
      end
    end

    trimmed_url = trim_url(url_or_predicate)
    log_line = if trimmed_url, do: "waiting for response #{trimmed_url}"

    _wait_for_event(
      this,
      Events.Page.response(),
      %{predicate: predicate, timeout: options[:timeout], signal: options[:signal]},
      log_line
    )
  end

  # urlMatches(this._browserContext._options.baseURL, url, match), with the LocalUtils (UrlMatch).
  defp _url_matches(this, url, match) do
    UrlMatch.url_matches(
      Connection.local_utils(get(this, :_connection)),
      get(get(this, :_browserContext), :_options)[:baseURL],
      url,
      match
    )
  end

  def wait_for_event(this, event, options_or_predicate \\ %{}) do
    _wait_for_event(this, event, options_or_predicate || %{}, ~s(waiting for event "#{event}"))
  end

  def _close_error_with_reason(this) do
    TargetClosedError.new(
      get(this, :_closeReason) || BrowserContext._effective_close_reason(get(this, :_browserContext))
    )
  end

  defp _wait_for_event(this, event, options_or_predicate, log_line) do
    ChannelOwner._wrap_api_call(this, fn _ ->
      timeout_options =
        TimeoutSettings.timeout(
          get(this, :_timeoutSettings),
          if(is_function(options_or_predicate), do: %{}, else: options_or_predicate)
        )

      predicate = if is_function(options_or_predicate), do: options_or_predicate, else: options_or_predicate[:predicate]
      waiter = Waiter.create_for_event(this, event)
      if log_line, do: Waiter.log(waiter, log_line)

      Waiter.reject_on_timeout(
        waiter,
        timeout_options,
        ~s(Timeout #{timeout_options.timeout}ms exceeded while waiting for event "#{event}")
      )

      if event != Events.Page.crash(),
        do: Waiter.reject_on_event(waiter, this, Events.Page.crash(), %RuntimeError{message: "Page crashed"})

      if event != Events.Page.close(),
        do: Waiter.reject_on_event(waiter, this, Events.Page.close(), fn -> _close_error_with_reason(this) end)

      result = Waiter.wait_for_event(waiter, this, event, predicate)
      Waiter.dispose(waiter)
      result
    end)
  end

  def go_back(this, options \\ %{}) do
    wait_until =
      Frame.verify_load_state("waitUntil", if(options[:waitUntil] == nil, do: "load", else: options.waitUntil))

    Response.from_nullable(
      channel_call(
        this,
        :goBack,
        Map.put(options, :waitUntil, wait_until),
        TimeoutSettings.navigation_timeout(get(this, :_timeoutSettings), options)
      )[:response]
    )
  end

  def go_forward(this, options \\ %{}) do
    wait_until =
      Frame.verify_load_state("waitUntil", if(options[:waitUntil] == nil, do: "load", else: options.waitUntil))

    Response.from_nullable(
      channel_call(
        this,
        :goForward,
        Map.put(options, :waitUntil, wait_until),
        TimeoutSettings.navigation_timeout(get(this, :_timeoutSettings), options)
      )[:response]
    )
  end

  def request_gc(this) do
    channel_call(this, :requestGC, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def emulate_media(this, options \\ %{}) do
    options = options || %{}

    channel_call(
      this,
      :emulateMedia,
      %{
        media: if(options[:media] == :null, do: "no-override", else: options[:media]),
        colorScheme: if(options[:colorScheme] == :null, do: "no-override", else: options[:colorScheme]),
        reducedMotion: if(options[:reducedMotion] == :null, do: "no-override", else: options[:reducedMotion]),
        forcedColors: if(options[:forcedColors] == :null, do: "no-override", else: options[:forcedColors]),
        contrast: if(options[:contrast] == :null, do: "no-override", else: options[:contrast])
      },
      TimeoutSettings.k_no_timeout()
    )

    nil
  end

  def set_viewport_size(this, viewport_size) do
    put(this, :_viewportSize, viewport_size)
    channel_call(this, :setViewportSize, %{viewportSize: viewport_size}, TimeoutSettings.k_no_timeout())
  end

  def viewport_size(this) do
    get(this, :_viewportSize) || nil
  end

  def evaluate(this, page_function, arg \\ nil, options \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    Frame.evaluate(get(this, :_mainFrame), page_function, arg, options)
  end

  def add_init_script(this, script, arg \\ nil, options \\ nil) do
    JSHandle.assert_evaluate_options(options)

    if options[:exposeFunctions] do
      add_init_script_with_exposed_functions(this, script, arg)
    else
      source = ClientHelper.evaluation_script(script, arg)

      DisposableObject.from(
        channel_call(this, :addInitScript, %{source: source}, TimeoutSettings.k_no_timeout()).disposable
      )
    end
  end

  def route(this, url, handler, options \\ %{}) do
    options = options || %{}

    route_handler =
      RouteHandler.new(
        Connection.local_utils(get(this, :_connection)),
        get(get(this, :_browserContext), :_options)[:baseURL],
        url,
        handler,
        options[:times],
        this
      )

    update(this, :_routes, &[route_handler | &1])
    _update_interception_patterns(this, %{title: "Route requests"})
    DisposableStub.new(fn -> unroute(this, url, handler) end)
  end

  def route_from_har(this, har, options \\ %{}) do
    options = options || %{}
    local_utils = Connection.local_utils(get(this, :_connection))
    if !local_utils, do: raise("Route from har is not supported in thin clients")

    if options[:update] do
      Tracing._record_into_har(get(get(this, :_browserContext), :tracing), har, this, options)
    else
      har_router = HarRouter.create(local_utils, har, options[:notFound] || "abort", %{urlMatch: options[:url]})
      update(this, :_harRouters, &(&1 ++ [har_router]))
      HarRouter.add_page_route(har_router, this)
    end

    nil
  end

  def route_web_socket(this, url, handler) do
    route_handler =
      WebSocketRouteHandler.new(
        Connection.local_utils(get(this, :_connection)),
        get(get(this, :_browserContext), :_options)[:baseURL],
        url,
        handler
      )

    update(this, :_webSocketRoutes, &[route_handler | &1])
    _update_web_socket_interception_patterns(this, %{title: "Route WebSockets"})
  end

  defp _dispose_har_routers(this) do
    routers = get(this, :_harRouters)
    for router <- routers, do: HarRouter.dispose(router)
    # `this._harRouters = []` as `update/3`: keeps a router added meanwhile (`routeFromHAR`).
    update(this, :_harRouters, &(&1 -- routers))
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

  defp _unroute_internal(this, removed, _remaining, behavior) do
    # `this._routes = remaining` as `update/3`: an expiring route (`_on_route`) or a `route`
    # call in another process may have changed `_routes` since the caller read it.
    update(this, :_routes, &(&1 -- removed))

    if behavior && behavior != "default" do
      promises =
        Enum.map(removed, fn route_handler -> Promise.async(fn -> RouteHandler.stop(route_handler, behavior) end) end)

      Promise.await(Promise.all(promises))
    end

    _update_interception_patterns(this, %{title: "Unroute requests"})
  end

  defp _update_interception_patterns(this, options) do
    # deviation: computed when the message is written, in one step with it (`channel_call/5`), so
    # a concurrent `route()` cannot send stale patterns after fresh ones.
    patterns = fn -> RouteHandler.prepare_interception_patterns(get(this, :_routes)) end

    _wrap_api_call(
      this,
      fn _ ->
        channel_call(
          this,
          :setNetworkInterceptionPatterns,
          fn -> %{patterns: patterns.()} end,
          TimeoutSettings.k_no_timeout()
        )
      end,
      options
    )

    nil
  end

  defp _update_web_socket_interception_patterns(this, options) do
    # deviation: computed when the message is written (see `_update_interception_patterns`).
    patterns = fn -> WebSocketRouteHandler.prepare_interception_patterns(get(this, :_webSocketRoutes)) end

    _wrap_api_call(
      this,
      fn _ ->
        channel_call(
          this,
          :setWebSocketInterceptionPatterns,
          fn -> %{patterns: patterns.()} end,
          TimeoutSettings.k_no_timeout()
        )
      end,
      options
    )

    nil
  end

  def screenshot(this, options \\ %{}) do
    mask = options[:mask]
    copy = Map.put(options, :mask, nil)
    copy = if !copy[:type], do: Map.put(copy, :type, ElementHandle.determine_screenshot_type(options)), else: copy

    copy =
      if mask,
        do: Map.put(copy, :mask, Enum.map(mask, &%{frame: &1._frame, selector: &1._selector})),
        else: copy

    result = channel_call(this, :screenshot, copy, TimeoutSettings.timeout(get(this, :_timeoutSettings), options))

    if options[:path] do
      FileUtils.mkdir_if_needed(options.path)
      Node.fs!(File.write(options.path, result.binary), "open", options.path)
    end

    result.binary
  end

  def _expect_screenshot(this, options) do
    %{timeout: timeout} = options
    signal = options[:signal]
    title = options[:title]
    options_without_timeout = Map.drop(options, [:timeout, :signal, :title])

    _wrap_api_call(
      this,
      fn _ ->
        mask = if options[:mask], do: Enum.map(options.mask, &%{frame: &1._frame, selector: &1._selector})
        locator = if options[:locator], do: %{frame: options.locator._frame, selector: options.locator._selector}

        try do
          result =
            channel_call(
              this,
              :expectScreenshot,
              Map.merge(options_without_timeout, %{isNot: !!options[:isNot], locator: locator, mask: mask}),
              %{timeout: timeout, signal: signal}
            )

          %{actual: result[:actual]}
        rescue
          e ->
            cond do
              is_struct(e, AbortError) ->
                %{errorMessage: "Error: " <> AbortSignal.assertion_aborted_message(Map.get(e, :cause))}

              !Errors.is_playwright_error(e) ->
                reraise(e, __STACKTRACE__)

              true ->
                # deviation: a PlaywrightError without details (not from the call) reads as `{}`; JS
                # throws a TypeError reading its fields.
                details = Map.get(e, :details) || %{}
                Map.merge(details, %{errorMessage: details[:customErrorMessage]})
            end
        end
      end,
      %{title: title}
    )
  end

  def title(this) do
    Frame.title(get(this, :_mainFrame))
  end

  def bring_to_front(this) do
    channel_call(this, :bringToFront, %{}, TimeoutSettings.k_no_timeout())
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def close(this, options \\ %{}) do
    put(this, :_closeReason, options[:reason])
    if !options[:runBeforeUnload], do: put(this, :_closeWasCalled, true)

    try do
      cond do
        get(this, :_ownedContext) -> BrowserContext.close(get(this, :_ownedContext))
        options[:runBeforeUnload] -> channel_call(this, :runBeforeUnload, %{}, TimeoutSettings.k_no_timeout())
        true -> channel_call(this, :close, %{reason: options[:reason]}, TimeoutSettings.k_no_timeout())
      end
    rescue
      e ->
        if Errors.is_target_closed_error(e) and !options[:runBeforeUnload],
          do: nil,
          else: reraise(e, __STACKTRACE__)
    end

    nil
  end

  def is_closed(this) do
    get(this, :_closed)
  end

  def click(this, selector, options \\ %{}) do
    Frame.click(get(this, :_mainFrame), selector, options || %{})
  end

  def drag_and_drop(this, source, target, options \\ %{}) do
    Frame.drag_and_drop(get(this, :_mainFrame), source, target, options || %{})
  end

  def dblclick(this, selector, options \\ %{}) do
    Frame.dblclick(get(this, :_mainFrame), selector, options || %{})
  end

  def tap(this, selector, options \\ %{}) do
    Frame.tap(get(this, :_mainFrame), selector, options || %{})
  end

  def fill(this, selector, value, options \\ %{}) do
    Frame.fill(get(this, :_mainFrame), selector, value, options || %{})
  end

  def clear_console_messages(this) do
    channel_call(this, :clearConsoleMessages, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def console_messages(this, options \\ nil) do
    %{messages: messages} =
      channel_call(this, :consoleMessages, %{filter: options[:filter]}, TimeoutSettings.k_no_timeout())

    Enum.map(messages, &ConsoleMessage.new(&1, this, nil))
  end

  def clear_page_errors(this) do
    channel_call(this, :clearPageErrors, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def page_errors(this, options \\ nil) do
    %{errors: errors} = channel_call(this, :pageErrors, %{filter: options[:filter]}, TimeoutSettings.k_no_timeout())
    Enum.map(errors, &Errors.parse_error/1)
  end

  def locator(this, selector, options \\ nil) do
    Frame.locator(main_frame(this), selector, options)
  end

  def get_by_test_id(this, test_id) do
    Frame.get_by_test_id(main_frame(this), test_id)
  end

  def get_by_alt_text(this, text, options \\ nil) do
    Frame.get_by_alt_text(main_frame(this), text, options)
  end

  def get_by_label(this, text, options \\ nil) do
    Frame.get_by_label(main_frame(this), text, options)
  end

  def get_by_placeholder(this, text, options \\ nil) do
    Frame.get_by_placeholder(main_frame(this), text, options)
  end

  def get_by_ref(this, ref) do
    locator(this, "aria-ref=#{ref}")
  end

  def get_by_text(this, text, options \\ nil) do
    Frame.get_by_text(main_frame(this), text, options)
  end

  def get_by_title(this, text, options \\ nil) do
    Frame.get_by_title(main_frame(this), text, options)
  end

  def get_by_role(this, role, options \\ %{}) do
    Frame.get_by_role(main_frame(this), role, options)
  end

  def frame_locator(this, selector \\ nil) do
    Frame.frame_locator(main_frame(this), selector)
  end

  def focus(this, selector, options \\ %{}) do
    Frame.focus(get(this, :_mainFrame), selector, options || %{})
  end

  def text_content(this, selector, options \\ %{}) do
    Frame.text_content(get(this, :_mainFrame), selector, options || %{})
  end

  def inner_text(this, selector, options \\ %{}) do
    Frame.inner_text(get(this, :_mainFrame), selector, options || %{})
  end

  def inner_html(this, selector, options \\ %{}) do
    Frame.inner_html(get(this, :_mainFrame), selector, options || %{})
  end

  def get_attribute(this, selector, name, options \\ %{}) do
    Frame.get_attribute(get(this, :_mainFrame), selector, name, options || %{})
  end

  def input_value(this, selector, options \\ %{}) do
    Frame.input_value(get(this, :_mainFrame), selector, options || %{})
  end

  def is_checked(this, selector, options \\ %{}) do
    Frame.is_checked(get(this, :_mainFrame), selector, options || %{})
  end

  def is_disabled(this, selector, options \\ %{}) do
    Frame.is_disabled(get(this, :_mainFrame), selector, options || %{})
  end

  def is_editable(this, selector, options \\ %{}) do
    Frame.is_editable(get(this, :_mainFrame), selector, options || %{})
  end

  def is_enabled(this, selector, options \\ %{}) do
    Frame.is_enabled(get(this, :_mainFrame), selector, options || %{})
  end

  def is_hidden(this, selector, options \\ %{}) do
    Frame.is_hidden(get(this, :_mainFrame), selector, options || %{})
  end

  def is_visible(this, selector, options \\ %{}) do
    Frame.is_visible(get(this, :_mainFrame), selector, options || %{})
  end

  def hover(this, selector, options \\ %{}) do
    Frame.hover(get(this, :_mainFrame), selector, options || %{})
  end

  def select_option(this, selector, values, options \\ %{}) do
    Frame.select_option(get(this, :_mainFrame), selector, values, options || %{})
  end

  def set_input_files(this, selector, files, options \\ nil) do
    Frame.set_input_files(get(this, :_mainFrame), selector, files, options || %{})
  end

  def type(this, selector, text, options \\ %{}) do
    Frame.type(get(this, :_mainFrame), selector, text, options || %{})
  end

  def press(this, selector, key, options \\ %{}) do
    Frame.press(get(this, :_mainFrame), selector, key, options || %{})
  end

  def check(this, selector, options \\ %{}) do
    Frame.check(get(this, :_mainFrame), selector, options || %{})
  end

  def uncheck(this, selector, options \\ %{}) do
    Frame.uncheck(get(this, :_mainFrame), selector, options || %{})
  end

  def set_checked(this, selector, checked, options \\ %{}) do
    Frame.set_checked(get(this, :_mainFrame), selector, checked, options || %{})
  end

  def wait_for_timeout(this, timeout) do
    Frame.wait_for_timeout(get(this, :_mainFrame), timeout)
  end

  def wait_for_function(this, page_function, arg \\ nil, options \\ nil) do
    Frame.wait_for_function(get(this, :_mainFrame), page_function, arg, options)
  end

  def requests(this) do
    %{requests: requests} = channel_call(this, :requests, %{}, TimeoutSettings.k_no_timeout())
    Enum.map(requests, &Request.from/1)
  end

  def workers(this) do
    get(this, :_workers)
  end

  def pause(this, options \\ nil) do
    # const isJSDebuggerAttached = !!inspector.url(); if (isJSDebuggerAttached) return;  -- not ported: no JS debugger
    context = get(this, :_browserContext)
    default_navigation_timeout = TimeoutSettings.default_navigation_timeout(get(context, :_timeoutSettings))
    default_timeout = TimeoutSettings.default_timeout(get(context, :_timeoutSettings))
    BrowserContext.set_default_navigation_timeout(context, 0)
    BrowserContext.set_default_timeout(context, 0)

    ClientInstrumentation.on_will_pause(get(this, :_instrumentation), %{
      keepTestTimeout: !!(options || %{})[:__testHookKeepTestTimeout]
    })

    LongStandingScope.safe_race(
      get(this, :_closedOrCrashedScope),
      # A latch on the page: when the scope wins, the pause call's late result settles the latch
      # (a local promise would leave a stray message).
      Promise.async(fn -> channel_call(context(this), :pause, %{}, TimeoutSettings.k_no_timeout()) end, owner: this)
    )

    BrowserContext.set_default_navigation_timeout(context, default_navigation_timeout)
    BrowserContext.set_default_timeout(context, default_timeout)
    nil
  end

  def pdf(this, options \\ %{}) do
    options = options || %{}
    transport_options = options
    # if (transportOptions.margin) transportOptions.margin = { ...transportOptions.margin };  -- maps are immutable

    transport_options =
      if is_number(options[:width]),
        do: %{transport_options | width: ClientHelper.number_to_string(options.width) <> "px"},
        else: transport_options

    transport_options =
      if is_number(options[:height]),
        do: %{transport_options | height: ClientHelper.number_to_string(options.height) <> "px"},
        else: transport_options

    transport_options =
      Enum.reduce([:top, :right, :bottom, :left], transport_options, fn index, transport_options ->
        if options[:margin] && is_number(options.margin[index]),
          do:
            put_in(
              transport_options,
              [:margin, index],
              ClientHelper.number_to_string(transport_options.margin[index]) <> "px"
            ),
          else: transport_options
      end)

    result = channel_call(this, :pdf, transport_options, TimeoutSettings.k_no_timeout())

    if options[:path] do
      dir = Path.dirname(options.path)
      Node.fs!(File.mkdir_p(dir), "mkdir", dir)
      Node.fs!(File.write(options.path, result.pdf), "open", options.path)
    end

    result.pdf
  end

  def aria_snapshot(this, options \\ %{}) do
    options = options || %{}

    result =
      channel_call(
        main_frame(this),
        :ariaSnapshot,
        %{mode: options[:mode], depth: options[:depth], boxes: options[:boxes]},
        TimeoutSettings.timeout(get(this, :_timeoutSettings), options)
      )

    result.snapshot
  end

  def aria_snapshot_json(this, options \\ %{}) do
    options = options || %{}

    result =
      channel_call(
        main_frame(this),
        :ariaSnapshotJSON,
        %{mode: options[:mode], depth: options[:depth], boxes: options[:boxes]},
        TimeoutSettings.timeout(get(this, :_timeoutSettings), options)
      )

    result.snapshot
  end

  def _set_dock_tile(this, image) do
    channel_call(this, :setDockTile, %{image: image}, TimeoutSettings.k_no_timeout())
    nil
  end

  # function trimUrl(param: any): string | undefined
  defp trim_url(param) do
    cond do
      PlaywrightEx.RegExp.reg_exp?(param) ->
        re = PlaywrightEx.RegExp.from_regex(param)
        "/#{StringUtils.trim_string_with_ellipsis(re.source, 50)}/#{re.flags}"

      is_binary(param) ->
        ~s("#{StringUtils.trim_string_with_ellipsis(param, 50)}")

      true ->
        nil
    end
  end

  # `owner` is a Page or a BrowserContext.
  def add_init_script_with_exposed_functions(owner, script, arg) do
    # typeof script !== 'function': a function is JS source (a string).
    if !is_binary(script), do: raise("Passing functions requires the init script to be a function")
    # `callbacks.push(...)` runs in the async closure's own process: collect the promises here.
    callbacks = make_ref()
    Process.put(callbacks, [])

    source =
      ChannelOwner._wrap_api_call(
        owner,
        fn _ ->
          ClientHelper.init_script_source_with_exposed_functions(script, arg, fn name, callback ->
            # Awaited twice (`Promise.all` in the serializer, then below): a latch on the owner, as a
            # local promise is awaited once.
            promise = Promise.async(fn -> impl(owner)._expose_callback_binding(owner, name, callback) end, owner: owner)
            Process.put(callbacks, Process.get(callbacks) ++ [{name, promise}])
            promise
          end)
        end,
        %{internal: true}
      )

    callbacks = for {name, promise} <- Process.delete(callbacks), do: %{name: name, disposable: Promise.await(promise)}

    init_script_disposable =
      DisposableObject.from(
        channel_call(owner, :addInitScript, %{source: source}, TimeoutSettings.k_no_timeout()).disposable
      )

    DisposableStub.new(fn ->
      for %{name: name, disposable: disposable} <- callbacks do
        map_delete(owner, :_bindings, name)
        Promise.void(fn -> DisposableObject.dispose(disposable) end)
      end

      DisposableObject.dispose(init_script_disposable)
    end)
  end
end

defmodule PlaywrightEx.Client.BindingCall do
  @upstream "packages/playwright-core/src/client/page.ts"
  @moduledoc "Port of `#{@upstream}` (`class BindingCall`)."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.AbortError
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.TargetClosedError

  def from(channel) do
    channel
  end

  def new(parent, type, guid, initializer), do: ChannelOwner.new(__MODULE__, parent, type, guid, initializer)

  # `func` takes the source and the list of arguments: `(source, ...args)`.
  def call(this, func) do
    try do
      initializer = get(this, :_initializer)
      frame = Frame.from(initializer.frame)

      source = %{
        context: Page.context(get(frame, :_page)),
        page: get(frame, :_page),
        frame: frame
      }

      result = func.(source, Enum.map(initializer.args, &JSHandle.parse_result/1))
      # await: a returned promise is awaited
      result = if is_struct(result, Promise), do: Promise.await(result), else: result
      params = %{result: JSHandle.serialize_argument(result)}

      Promise.void(fn -> channel_call(this, :resolve, params, TimeoutSettings.k_no_timeout()) end)
    rescue
      e -> _reject(this, e)
    catch
      # JS can throw any value (`throw null`): an Elixir `throw`.
      :throw, value -> _reject(this, value)
    end

    nil
  end

  defp _reject(this, e) do
    params = %{error: Errors.serialize_error(e)}

    Promise.void(fn -> channel_call(this, :reject, params, TimeoutSettings.k_no_timeout()) end)
  end
end
