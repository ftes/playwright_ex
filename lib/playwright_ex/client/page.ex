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
  # pickLocator, cancelPickLocator, hideHighlight  -- not ported: Locator
  # $, waitForSelector, dispatchEvent, evaluateHandle, $eval, $$eval, $$  -- not ported: ElementHandle, JSHandle
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
  # waitForEvent, _waitForEvent  -- not ported: waits for the promise handle (PLAN, Public API)

  def _close_error_with_reason(this) do
    Errors.TargetClosedError.new(
      get(this, :_closeReason) || BrowserContext._effective_close_reason(get(this, :_browserContext))
    )
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

  # click, dragAndDrop, dblclick, tap, fill  -- not ported: selectors
  # clearConsoleMessages, consoleMessages, clearPageErrors, pageErrors  -- not ported: ConsoleMessage
  # locator, getByTestId, getByAltText, getByLabel, getByPlaceholder, getByRef, getByText, getByTitle, getByRole, frameLocator  -- not ported: Locator
  # focus, textContent, innerText, innerHTML, getAttribute, inputValue  -- not ported: selectors
  # isChecked, isDisabled, isEditable, isEnabled, isHidden, isVisible, hover  -- not ported: selectors
  # selectOption, setInputFiles, type, press, check, uncheck, setChecked  -- not ported: selectors

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
