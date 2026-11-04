defmodule PlaywrightEx.Client.Page do
  @upstream "packages/playwright-core/src/client/page.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.Network
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Isomorphic.Headers
  alias PlaywrightEx.Isomorphic.LongStandingScope

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
    put(this, :_closedOrCrashedScope, LongStandingScope.new())
    put(this, :_routes, [])
    put(this, :_webSocketRoutes, [])
    put(this, :_closeWasCalled, false)
    put(this, :_harRouters, [])
    # this._instrumentation.onPage(this);  -- not ported: instrumentation
    put(this, :_browserContext, parent)
    put(this, :_timeoutSettings, TimeoutSettings.new(get(parent, :_timeoutSettings)))

    # this.keyboard / mouse / touchscreen = new ...(this);  -- not ported: input
    put(this, :request, get(parent, :request))
    # this.clock = this._browserContext.clock;  -- not ported: Clock
    # this.localStorage / sessionStorage = new WebStorage(...);  -- not ported: WebStorage

    put(this, :_mainFrame, Frame.from(initializer.mainFrame))
    put(get(this, :_mainFrame), :_page, this)
    # this.webmcp = this._mainFrame.webmcp;  -- not ported: WebMCP
    set_add(this, :_frames, get(this, :_mainFrame))
    put(this, :_viewportSize, initializer[:viewportSize])
    put(this, :_closed, initializer.isClosed)
    put(this, :_opener, from_nullable(initializer[:opener]))
    # this._video = new Video(...); this.screencast = new Screencast(this);  -- not ported: Video, Screencast

    # this._channel.on('bindingCall', ...)  -- not ported: BindingCall
    EventEmitter.on(_channel(this), "close", fn _ -> _on_close(this) end)
    EventEmitter.on(_channel(this), "crash", fn _ -> _on_crash(this) end)
    # this._channel.on('download' | 'fileChooser', ...)  -- not ported: Download, FileChooser
    EventEmitter.on(_channel(this), "frameAttached", fn %{frame: frame} ->
      _on_frame_attached(this, Frame.from(frame))
    end)

    EventEmitter.on(_channel(this), "frameDetached", fn %{frame: frame} ->
      _on_frame_detached(this, Frame.from(frame))
    end)

    # this._channel.on('locatorHandlerTriggered', ...)  -- not ported: Locator
    # this._channel.on('route' | 'webSocketRoute', ...)  -- not ported: routing

    EventEmitter.on(_channel(this), "viewportSizeChanged", fn event ->
      put(this, :_viewportSize, event[:viewportSize])
    end)

    # this._channel.on('webSocket' | 'worker', ...)  -- not ported: WebSocket, Worker

    # this.coverage = new Coverage(this._channel);  -- not ported: Coverage

    once(this, Events.Page.close(), fn _ ->
      LongStandingScope.close(get(this, :_closedOrCrashedScope), _close_error_with_reason(this))
    end)

    once(this, Events.Page.crash(), fn _ ->
      LongStandingScope.close(get(this, :_closedOrCrashedScope), Errors.TargetClosedError.new())
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

  # _onRoute, _onWebSocketRoute  -- not ported: routing
  # _onBinding  -- not ported: BindingCall
  # _onWorker  -- not ported: Worker

  def _on_close(this) do
    put(this, :_closed, true)
    set_delete(get(this, :_browserContext), :_pages, this)
    # this._disposeHarRouters();  -- not ported: routing
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

  # frame  -- not ported: urlMatch

  def frames(this) do
    get(this, :_frames)
  end

  def set_default_navigation_timeout(this, timeout) do
    TimeoutSettings.set_default_navigation_timeout(get(this, :_timeoutSettings), timeout)
  end

  def set_default_timeout(this, timeout) do
    TimeoutSettings.set_default_timeout(get(this, :_timeoutSettings), timeout)
  end

  # video  -- not ported: Video
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

  # $, waitForSelector  -- not ported: ElementHandle

  def dispatch_event(this, selector, type, event_init \\ nil, options \\ %{}) do
    Frame.dispatch_event(get(this, :_mainFrame), selector, type, event_init, options || %{})
  end

  # evaluateHandle  -- not ported: JSHandle

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

  # $$  -- not ported: ElementHandle
  # addScriptTag, addStyleTag  -- not ported: ElementHandle
  # exposeFunction, exposeBinding, _exposeCallbackBinding, _exposeEvaluateCallback, _eraseEvaluateCallbacks  -- not ported: BindingCall

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

  # addLocatorHandler, _onLocatorHandlerTriggered, removeLocatorHandler  -- not ported: Locator

  def wait_for_load_state(this, state \\ nil, options \\ nil) do
    Frame.wait_for_load_state(get(this, :_mainFrame), state, options)
  end

  # waitForNavigation, waitForURL, waitForRequest, waitForResponse  -- not ported: urlMatch
  # waitForEvent  -- not ported: waits for the promise handle (PLAN, Public API)

  def _close_error_with_reason(this) do
    Errors.TargetClosedError.new(
      get(this, :_closeReason) || BrowserContext._effective_close_reason(get(this, :_browserContext))
    )
  end

  # _waitForEvent  -- not ported: waits for the promise handle (PLAN, Public API)

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

  # requestGC, emulateMedia  -- not ported

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

  # addInitScript  -- not ported: Disposable
  # route, routeFromHAR, routeWebSocket, _disposeHarRouters, unrouteAll, unroute  -- not ported: routing
  # _unrouteInternal, _updateInterceptionPatterns, _updateWebSocketInterceptionPatterns  -- not ported: routing
  # screenshot, _expectScreenshot  -- not ported

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

  # clearConsoleMessages, consoleMessages, clearPageErrors, pageErrors  -- not ported: ConsoleMessage

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

  # setInputFiles  -- not ported: convertInputFiles

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

  # waitForFunction  -- not ported: JSHandle

  def requests(this) do
    %{requests: requests} = channel_call(this, :requests, %{}, TimeoutSettings.k_no_timeout())
    Enum.map(requests, &Request.from/1)
  end

  # workers  -- not ported: Worker
  # pause, pdf, ariaSnapshot, ariaSnapshotJSON, _setDockTile  -- not ported
end

# BindingCall, trimUrl, addInitScriptWithExposedFunctions  -- not ported: BindingCall
