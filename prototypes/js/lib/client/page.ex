# upstream: packages/playwright-core/src/client/page.ts
defmodule PlaywrightJS.Client.Page do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.{Artifact, BrowserContext, Download, Errors, Frame, Waiter}

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

    # this._channel.on('bindingCall', ...)  -- not ported
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
    # locatorHandlerTriggered, route, webSocketRoute  -- not ported
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
end
