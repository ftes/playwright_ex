# upstream: packages/playwright-core/src/client/page.ts
defmodule PlaywrightJS.Client.Page do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.{Artifact, BrowserContext, Download, Errors, Frame, Network, Waiter}
  alias PlaywrightJS.Client.Network.{Route, RouteHandler}
  alias PlaywrightJS.Isomorphic.UrlMatch

  # upstream: page.ts:126
  def from(page) do
    page
  end

  # upstream: page.ts:130
  def from_nullable(page) do
    if page, do: from(page), else: nil
  end

  # upstream: page.ts:134
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_apiName, "Page")
    put(this, :_frames, [])
    put(this, :_routes, [])
    put(this, :_closed, false)
    put(this, :_closeWasCalled, false)
    # this._instrumentation.onPage(this);  -- not ported
    put(this, :_browserContext, parent)
    put(this, :_timeoutSettings, TimeoutSettings.new(this.conn, get(get(this, :_browserContext), :_timeoutSettings)))

    # keyboard, mouse, request, touchscreen, clock, localStorage, sessionStorage  -- not ported

    put(this, :_mainFrame, Frame.from(initializer.mainFrame))
    put(get(this, :_mainFrame), :_page, this)
    # this.webmcp = this._mainFrame.webmcp;  -- not ported
    set_add(this, :_frames, get(this, :_mainFrame))
    put(this, :_viewportSize, initializer[:viewportSize])
    put(this, :_closed, initializer.isClosed)
    put(this, :_opener, from_nullable(initializer[:opener]))
    # this._video = new Video(...); this.screencast = new Screencast(this);  -- not ported

    EventEmitter.on(_channel(this), "bindingCall", fn %{binding: binding} -> _on_binding(this, __MODULE__.BindingCall.from(binding)) end)
    EventEmitter.on(_channel(this), "close", fn _ -> _on_close(this) end)
    EventEmitter.on(_channel(this), "crash", fn _ -> _on_crash(this) end)

    EventEmitter.on(_channel(this), "download", fn %{url: url, suggestedFilename: suggested_filename, artifact: artifact} ->
      artifact_object = Artifact.from(artifact)
      download = Download.new(this, url, suggested_filename, artifact_object)
      emit(this, Events.Page.download(), download)
      BrowserContext.emit(get(this, :_browserContext), Events.BrowserContext.download(), download)
    end)

    # this._channel.on('fileChooser', ...)  -- not ported
    EventEmitter.on(_channel(this), "frameAttached", fn %{frame: frame} -> _on_frame_attached(this, Frame.from(frame)) end)
    EventEmitter.on(_channel(this), "frameDetached", fn %{frame: frame} -> _on_frame_detached(this, Frame.from(frame)) end)
    # locatorHandlerTriggered  -- not ported
    EventEmitter.on(_channel(this), "route", fn %{route: route} -> _on_route(this, Route.from(route)) end)
    # webSocketRoute  -- not ported
    EventEmitter.on(_channel(this), "viewportSizeChanged", fn %{viewportSize: viewport_size} -> put(this, :_viewportSize, viewport_size) end)

    # webSocket, worker  -- not ported

    # this.coverage = new Coverage(this._channel);  -- not ported
    # this.once(Events.Page.Close/Crash, () => this._closedOrCrashedScope.close(...));  -- not ported: LongStandingScope

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

  # upstream: page.ts:194
  defp _on_frame_attached(this, frame) do
    put(frame, :_page, this)
    set_add(this, :_frames, frame)
    if get(frame, :_parentFrame), do: set_add(get(frame, :_parentFrame), :_childFrames, frame)
    emit(this, Events.Page.frame_attached(), frame)
    BrowserContext.emit(get(this, :_browserContext), Events.BrowserContext.frame_attached(), frame)
  end

  # upstream: page.ts:203
  defp _on_frame_detached(this, frame) do
    set_delete(this, :_frames, frame)
    put(frame, :_detached, true)
    if get(frame, :_parentFrame), do: set_delete(get(frame, :_parentFrame), :_childFrames, frame)
    emit(this, Events.Page.frame_detached(), frame)
    BrowserContext.emit(get(this, :_browserContext), Events.BrowserContext.frame_detached(), frame)
  end

  # upstream: page.ts:212
  defp _on_route(this, route) do
    put(route, :_context, context(this))
    route_handlers = get(this, :_routes)

    result =
      Enum.reduce_while(route_handlers, :continue, fn route_handler, _ ->
        cond do
          # If the page was closed we stall all requests right away.
          get(this, :_closeWasCalled) or BrowserContext.is_closed(get(this, :_browserContext)) ->
            {:halt, :return}

          !RouteHandler.matches(route_handler, Network.Request.url(Route.request(route))) ->
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

    if result == :continue, do: BrowserContext._on_route(get(this, :_browserContext), route)
  end

  # upstream: page.ts:244
  def _on_binding(this, binding_call) do
    func = map_get(this, :_bindings, get(binding_call, :_initializer).name)

    if func do
      __MODULE__.BindingCall.call(binding_call, func)
    else
      BrowserContext._on_binding(get(this, :_browserContext), binding_call)
    end
  end

  # upstream: page.ts:259
  def _on_close(this) do
    put(this, :_closed, true)
    set_delete(get(this, :_browserContext), :_pages, this)
    # this._disposeHarRouters();  -- not ported: HAR
    emit(this, Events.Page.close(), this)
    BrowserContext.emit(get(this, :_browserContext), Events.BrowserContext.page_close(), this)
  end

  # upstream: page.ts:267
  defp _on_crash(this) do
    emit(this, Events.Page.crash(), this)
  end

  # upstream: page.ts:271
  def context(this) do
    get(this, :_browserContext)
  end

  # upstream: page.ts:275
  def opener(this) do
    if !get(this, :_opener) || is_closed(get(this, :_opener)), do: nil, else: get(this, :_opener)
  end

  # upstream: page.ts:281
  def main_frame(this) do
    get(this, :_mainFrame)
  end

  # upstream: page.ts:296
  def frames(this) do
    get(this, :_frames)
  end

  # upstream: page.ts:300
  def set_default_navigation_timeout(this, timeout) do
    TimeoutSettings.set_default_navigation_timeout(get(this, :_timeoutSettings), timeout)
  end

  # upstream: page.ts:304
  def set_default_timeout(this, timeout) do
    TimeoutSettings.set_default_timeout(get(this, :_timeoutSettings), timeout)
  end

  # upstream: page.ts:371
  # `(source, ...args)` callbacks receive the rest arguments as a list.
  def expose_function(this, name, callback) do
    result = channel_call(this, :exposeBinding, %{name: name}, TimeoutSettings.k_no_timeout())
    binding = fn _source, args -> apply(callback, args) end
    map_set(this, :_bindings, name, binding)
    # return DisposableObject.from(result.disposable);  -- not ported: Disposable
    result[:disposable]
  end

  # upstream: page.ts:378
  def expose_binding(this, name, callback) do
    result = channel_call(this, :exposeBinding, %{name: name}, TimeoutSettings.k_no_timeout())
    map_set(this, :_bindings, name, fn source, args -> apply(callback, [source | args]) end)
    # return DisposableObject.from(result.disposable);  -- not ported: Disposable
    result[:disposable]
  end

  # upstream: page.ts:408
  def url(this) do
    Frame.url(get(this, :_mainFrame))
  end

  # upstream: page.ts:420
  def goto(this, url, options \\ %{}) do
    Frame.goto(get(this, :_mainFrame), url, options)
  end

  # upstream: page.ts:464
  def wait_for_load_state(this, state \\ nil, options \\ nil) do
    Frame.wait_for_load_state(get(this, :_mainFrame), state, options)
  end

  # upstream: page.ts:468
  def wait_for_navigation(this, options \\ %{}) do
    Frame.wait_for_navigation(get(this, :_mainFrame), options)
  end

  # upstream: page.ts:472
  def wait_for_url(this, url, options \\ nil) do
    Frame.wait_for_url(get(this, :_mainFrame), url, options)
  end

  # upstream: page.ts:498
  def wait_for_event(this, event, options_or_predicate \\ %{}) do
    _wait_for_event(this, event, options_or_predicate, "waiting for event \"#{event}\"")
  end

  # upstream: page.ts:502
  def _close_error_with_reason(this) do
    Errors.TargetClosedError.new(get(this, :_closeReason) || BrowserContext._effective_close_reason(get(this, :_browserContext)))
  end

  # upstream: page.ts:506
  defp _wait_for_event(this, event, options_or_predicate, log_line) do
    _wrap_api_call(this, fn _ ->
      timeout_options =
        TimeoutSettings.timeout(get(this, :_timeoutSettings), if(is_function(options_or_predicate), do: %{}, else: options_or_predicate))

      predicate = if is_function(options_or_predicate), do: options_or_predicate, else: options_or_predicate[:predicate]
      waiter = Waiter.create_for_event(this, event)
      if log_line, do: Waiter.log(waiter, log_line)

      Waiter.reject_on_timeout(
        waiter,
        timeout_options,
        "Timeout #{timeout_options.timeout}ms exceeded while waiting for event \"#{event}\""
      )

      if event != Events.Page.crash(), do: Waiter.reject_on_event(waiter, this, Events.Page.crash(), RuntimeError.exception("Page crashed"))

      if event != Events.Page.close(),
        do: Waiter.reject_on_event(waiter, this, Events.Page.close(), fn -> _close_error_with_reason(this) end)

      result = Waiter.wait_for_event(waiter, this, event, predicate)
      Waiter.dispose(waiter)
      result
    end)
  end

  # upstream: page.ts:557
  def evaluate(this, page_function, arg \\ nil, options \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- n/a
    Frame.evaluate(get(this, :_mainFrame), page_function, arg, options)
  end

  # upstream: page.ts:570
  def route(this, url, handler, options \\ %{}) do
    route_handler =
      RouteHandler.new(get(get(this, :_browserContext), :_options)[:baseURL], url, handler, options[:times], get(this, :_connection))

    update(this, :_routes, &[route_handler | &1])
    _update_interception_patterns(this, %{title: "Route requests"})
    # return new DisposableStub(() => this.unroute(url, handler));  -- not ported: Disposable
    nil
  end

  # upstream: page.ts:599
  def unroute_all(this, options \\ nil) do
    _unroute_internal(this, get(this, :_routes), [], (options || %{})[:behavior])
    # this._disposeHarRouters();  -- not ported: HAR
  end

  # upstream: page.ts:604
  def unroute(this, url, handler \\ nil) do
    {removed, remaining} =
      Enum.split_with(get(this, :_routes), fn route ->
        UrlMatch.url_matches_equal(get(route, :url), url) and (!handler or get(route, :handler) == handler)
      end)

    _unroute_internal(this, removed, remaining, "default")
  end

  # upstream: page.ts:616
  defp _unroute_internal(this, removed, remaining, behavior) do
    put(this, :_routes, remaining)

    if behavior && behavior != "default" do
      promises = Enum.map(removed, fn route_handler -> Promise.async(this.conn, fn -> RouteHandler.stop(route_handler, behavior) end) end)
      Promise.await(Promise.all(this.conn, promises))
    end

    _update_interception_patterns(this, %{title: "Unroute requests"})
    nil
  end

  # upstream: page.ts:625
  defp _update_interception_patterns(this, options) do
    patterns = RouteHandler.prepare_interception_patterns(get(this, :_routes))

    _wrap_api_call(
      this,
      fn _ -> channel_call(this, :setNetworkInterceptionPatterns, %{patterns: patterns}, TimeoutSettings.k_no_timeout()) end,
      options
    )
  end

  # upstream: page.ts:684
  def title(this) do
    Frame.title(get(this, :_mainFrame))
  end

  # upstream: page.ts:696
  def close(this, options \\ %{}) do
    put(this, :_closeReason, options[:reason])
    if !options[:runBeforeUnload], do: put(this, :_closeWasCalled, true)

    try do
      cond do
        get(this, :_ownedContext) -> BrowserContext.close(get(this, :_ownedContext))
        options[:runBeforeUnload] -> channel_call(this, :runBeforeUnload, %{}, TimeoutSettings.k_no_timeout())
        true -> channel_call(this, :close, %{reason: options[:reason]}, TimeoutSettings.k_no_timeout())
      end

      nil
    rescue
      e ->
        if Errors.is_target_closed_error(e) and !options[:runBeforeUnload], do: nil, else: reraise(e, __STACKTRACE__)
    end
  end

  # upstream: page.ts:714
  def is_closed(this) do
    get(this, :_closed)
  end

  # upstream: page.ts:718
  def click(this, selector, options \\ %{}) do
    Frame.click(get(this, :_mainFrame), selector, options)
  end

  # upstream: page.ts:734
  def fill(this, selector, value, options \\ %{}) do
    Frame.fill(get(this, :_mainFrame), selector, value, options)
  end

  # upstream: page.ts:756
  def locator(this, selector, options \\ nil) do
    Frame.locator(main_frame(this), selector, options)
  end

  # upstream: page.ts:760
  def get_by_test_id(this, test_id) do
    Frame.get_by_test_id(main_frame(this), test_id)
  end

  # upstream: page.ts:768
  def get_by_label(this, text, options \\ nil) do
    Frame.get_by_label(main_frame(this), text, options)
  end

  # upstream: page.ts:788
  def get_by_role(this, role, options \\ %{}) do
    Frame.get_by_role(main_frame(this), role, options)
  end

  # upstream: page.ts:943
  defmodule BindingCall do
    use PlaywrightJS.Client.ChannelOwner
    alias PlaywrightJS.Client.{Errors, Frame, JSHandle, Page}

    # upstream: page.ts:944
    def from(channel) do
      channel
    end

    # upstream: page.ts:948
    def new(parent, type, guid, initializer) do
      ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    end

    # upstream: page.ts:952
    def call(this, func) do
      try do
        frame = Frame.from(get(this, :_initializer).frame)
        source = %{context: Page.context(get(frame, :_page)), page: get(frame, :_page), frame: frame}
        result = func.(source, Enum.map(get(this, :_initializer)[:args] || [], &JSHandle.parse_result/1))

        Promise.catch_(
          Promise.async(this.conn, fn ->
            channel_call(this, :resolve, %{result: JSHandle.serialize_argument(result)}, TimeoutSettings.k_no_timeout())
          end),
          fn _ -> nil end
        )
      rescue
        e ->
          Promise.catch_(
            Promise.async(this.conn, fn -> channel_call(this, :reject, %{error: Errors.serialize_error(e)}, TimeoutSettings.k_no_timeout()) end),
            fn _ -> nil end
          )
      end

      nil
    end
  end
end
