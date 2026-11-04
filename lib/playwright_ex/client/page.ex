defmodule PlaywrightEx.Client.Page do
  @upstream "packages/playwright-core/src/client/page.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.ConsoleMessage
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.ElementHandle
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.FileChooser
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.Keyboard
  alias PlaywrightEx.Client.Mouse
  alias PlaywrightEx.Client.Network
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Client.Touchscreen
  alias PlaywrightEx.Client.Waiter
  alias PlaywrightEx.Client.Worker
  alias PlaywrightEx.Isomorphic.Headers
  alias PlaywrightEx.Isomorphic.LongStandingScope
  alias PlaywrightEx.Isomorphic.StringUtils
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.Protocol.Serializers

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

    put(this, :keyboard, Keyboard.new(this))
    put(this, :mouse, Mouse.new(this))
    put(this, :request, get(parent, :request))
    put(this, :touchscreen, Touchscreen.new(this))
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
    # this._channel.on('download', ...)  -- not ported: Download
    EventEmitter.on(_channel(this), "fileChooser", fn %{element: element, isMultiple: is_multiple} ->
      emit(this, Events.Page.file_chooser(), FileChooser.new(this, ElementHandle.from(element), is_multiple))
    end)

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

    # this._channel.on('webSocket', ...)  -- not ported: WebSocket
    EventEmitter.on(_channel(this), "worker", fn %{worker: worker} -> _on_worker(this, Worker.from(worker)) end)

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

  # readonly properties
  def keyboard(this), do: get(this, :keyboard)
  def mouse(this), do: get(this, :mouse)
  def touchscreen(this), do: get(this, :touchscreen)

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

  def _on_worker(this, worker) do
    set_add(this, :_workers, worker)
    put(worker, :_page, this)
    emit(this, Events.Page.worker(), worker)
  end

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

  def frame(this, frame_selector) do
    name = if is_binary(frame_selector), do: frame_selector, else: frame_selector[:name]
    url = if is_map(frame_selector), do: frame_selector[:url]
    if !(name || url), do: raise("Either name or url matcher should be specified")

    Enum.find(frames(this), fn f ->
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

  def wait_for_navigation(this, options \\ nil) do
    Frame.wait_for_navigation(get(this, :_mainFrame), options || %{})
  end

  def wait_for_url(this, url, options \\ nil) do
    Frame.wait_for_url(get(this, :_mainFrame), url, options)
  end

  def wait_for_request(this, url_or_predicate, options \\ %{}) do
    options = options || %{}

    predicate = fn request ->
      if is_binary(url_or_predicate) or is_struct(url_or_predicate, Regex),
        do: _url_matches(this, Request.url(request), url_or_predicate),
        else: url_or_predicate.(request)
    end

    trimmed_url = trim_url(url_or_predicate)
    log_line = if trimmed_url, do: "waiting for request #{trimmed_url}"
    # signal: options.signal  -- not ported: AbortSignal
    _wait_for_event(this, Events.Page.request(), %{predicate: predicate, timeout: options[:timeout]}, log_line)
  end

  def wait_for_response(this, url_or_predicate, options \\ %{}) do
    options = options || %{}

    predicate = fn response ->
      if is_binary(url_or_predicate) or is_struct(url_or_predicate, Regex),
        do: _url_matches(this, Response.url(response), url_or_predicate),
        else: url_or_predicate.(response)
    end

    trimmed_url = trim_url(url_or_predicate)
    log_line = if trimmed_url, do: "waiting for response #{trimmed_url}"
    # signal: options.signal  -- not ported: AbortSignal
    _wait_for_event(this, Events.Page.response(), %{predicate: predicate, timeout: options[:timeout]}, log_line)
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
    Errors.TargetClosedError.new(
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
      ElementHandle.mkdir_if_needed(options.path)
      File.write!(options.path, result.binary)
    end

    result.binary
  end

  # _expectScreenshot  -- not ported: matchers

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

  # pause, pdf, ariaSnapshot, ariaSnapshotJSON, _setDockTile  -- not ported

  # function trimUrl(param: any): string | undefined
  defp trim_url(param) do
    cond do
      is_struct(param, Regex) ->
        "/#{StringUtils.trim_string_with_ellipsis(Regex.source(param), 50)}/#{Serializers.regex_flags(param)}"

      is_binary(param) ->
        ~s("#{StringUtils.trim_string_with_ellipsis(param, 50)}")

      true ->
        nil
    end
  end
end

# BindingCall, addInitScriptWithExposedFunctions  -- not ported: BindingCall
