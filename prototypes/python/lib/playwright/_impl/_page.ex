# upstream: playwright/_impl/_page.py (subset)
defmodule Playwright.Impl.Page do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.{Channel, ChannelOwner}
  alias Playwright.Impl.{BrowserContext, Download, EventContextManagerImpl, Frame, Waiter}
  alias Playwright.Impl.Errors
  alias Playwright.Impl.Errors.{Error, TargetClosedError}
  alias Playwright.Impl.Helper.TimeoutSettings
  import Playwright.Impl.Connection, only: [from_channel: 1, from_nullable_channel: 1]
  import Playwright.Impl.Helper, only: [locals_to_params: 1, url_matches: 3]

  # Events = SimpleNamespace(...)
  def events do
    %{
      close: "close",
      crash: "crash",
      console: "console",
      dialog: "dialog",
      dialog_closed: "dialogclosed",
      download: "download",
      file_chooser: "filechooser",
      dom_content_loaded: "domcontentloaded",
      page_error: "pageerror",
      request: "request",
      response: "response",
      request_failed: "requestfailed",
      request_finished: "requestfinished",
      frame_attached: "frameattached",
      frame_detached: "framedetached",
      frame_navigated: "framenavigated",
      load: "load",
      popup: "popup",
      web_socket: "websocket",
      worker: "worker"
    }
  end

  # upstream: _page.py:163
  def init(parent, type, guid, initializer) do
    self = ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)
    Py.set(self, :_browser_context, parent)
    # keyboard / mouse / touchscreen (omitted)

    Py.set(self, :_main_frame, from_channel(initializer["mainFrame"]))
    Py.set(self[:_main_frame], :_page, self)
    Py.set(self, :_frames, [self[:_main_frame]])
    Py.set(self, :_viewport_size, initializer["viewportSize"])
    Py.set(self, :_is_closed, false)
    Py.set(self, :_workers, [])
    Py.set(self, :_bindings, %{})
    Py.set(self, :_routes, [])
    Py.set(self, :_web_socket_routes, [])
    Py.set(self, :_owned_context, nil)

    Py.set(
      self,
      :_timeout_settings,
      TimeoutSettings.init(self[:_browser_context][:_timeout_settings])
    )

    # _video / _screencast / _local_storage / _session_storage (omitted)
    Py.set(self, :_opener, from_nullable_channel(initializer["opener"]))
    Py.set(self, :_close_reason, nil)
    Py.set(self, :_close_was_called, false)
    Py.set(self, :_har_routers, [])
    Py.set(self, :_locator_handlers, %{})

    # bindingCall (omitted)
    Channel.on(self[:_channel], "close", fn _ -> _on_close(self) end)
    Channel.on(self[:_channel], "crash", fn _ -> _on_crash(self) end)
    Channel.on(self[:_channel], "download", fn params -> _on_download(self, params) end)
    # fileChooser (omitted)
    Channel.on(self[:_channel], "frameAttached", fn params ->
      _on_frame_attached(self, from_channel(params["frame"]))
    end)

    Channel.on(self[:_channel], "frameDetached", fn params ->
      _on_frame_detached(self, from_channel(params["frame"]))
    end)

    # locatorHandlerTriggered, route, webSocketRoute (omitted)
    Channel.on(self[:_channel], "viewportSizeChanged", fn params ->
      _on_viewport_size_changed(self, params)
    end)

    # webSocket, worker (omitted)
    Py.set(self, :_closed_or_crashed_future, Asyncio.Future.new())

    on(self, events().close, fn _ ->
      if not Asyncio.Future.done(self[:_closed_or_crashed_future]),
        do:
          Asyncio.Future.set_result(
            self[:_closed_or_crashed_future],
            _close_error_with_reason(self)
          )
    end)

    on(self, events().crash, fn _ ->
      if not Asyncio.Future.done(self[:_closed_or_crashed_future]),
        do: Asyncio.Future.set_result(self[:_closed_or_crashed_future], TargetClosedError.new())
    end)

    _set_event_to_subscription_mapping(self, %{
      events().console => "console",
      events().dialog => "dialog",
      events().dialog_closed => "dialogClosed",
      events().request => "request",
      events().response => "response",
      events().request_finished => "requestFinished",
      events().request_failed => "requestFailed",
      events().file_chooser => "fileChooser"
    })

    self
  end

  # upstream: _page.py:286
  def _on_frame_attached(self, frame) do
    Py.set(frame, :_page, self)
    Py.append(self, :_frames, frame)
    emit(self, events().frame_attached, frame)
    BrowserContext.emit(self[:_browser_context], "frameattached", frame)
  end

  # upstream: _page.py:292
  def _on_frame_detached(self, frame) do
    Py.remove(self, :_frames, frame)
    Py.set(frame, :_detached, true)
    emit(self, events().frame_detached, frame)
    BrowserContext.emit(self[:_browser_context], "framedetached", frame)
  end

  # upstream: _page.py:356
  def _on_close(self) do
    Py.set(self, :_is_closed, true)

    if self in self[:_browser_context][:_pages],
      do: Py.remove(self[:_browser_context], :_pages, self)

    # self._dispose_har_routers() (omitted)
    emit(self, events().close, self)
    BrowserContext.emit(self[:_browser_context], "pageclose", self)
  end

  # upstream: _page.py:364
  def _on_crash(self), do: emit(self, events().crash, self)

  # upstream: _page.py:367
  def _on_download(self, params) do
    url = params["url"]
    suggested_filename = params["suggestedFilename"]
    artifact = from_channel(params["artifact"])
    download = Download.init(self, url, suggested_filename, artifact)
    emit(self, events().download, download)
    BrowserContext.emit(self[:_browser_context], "download", download)
  end

  # upstream: _page.py:375
  def _on_viewport_size_changed(self, params),
    do: Py.set(self, :_viewport_size, params["viewportSize"])

  # upstream: _page.py:379
  def context(self), do: self[:_browser_context]

  # upstream: _page.py:386
  def opener(self) do
    if self[:_opener] && is_closed(self[:_opener]), do: nil, else: self[:_opener]
  end

  # upstream: _page.py:392
  def main_frame(self), do: self[:_main_frame]

  # upstream: _page.py:395
  def frame(self, opts \\ []) do
    Enum.find(self[:_frames], fn frame ->
      (opts[:name] && Frame.name(frame) == opts[:name]) ||
        (opts[:url] &&
           url_matches(self[:_browser_context][:_base_url], Frame.url(frame), opts[:url]))
    end)
  end

  # upstream: _page.py:405
  def frames(self), do: self[:_frames]

  # upstream: _page.py:408
  def set_default_navigation_timeout(self, timeout),
    do: TimeoutSettings.set_default_navigation_timeout(self[:_timeout_settings], timeout)

  # upstream: _page.py:411
  def set_default_timeout(self, timeout),
    do: TimeoutSettings.set_default_timeout(self[:_timeout_settings], timeout)

  # upstream: _page.py:543
  def url(self), do: Frame.url(self[:_main_frame])

  # upstream: _page.py:557
  def goto(self, url, opts \\ []), do: Frame.goto(self[:_main_frame], url, locals_to_params(opts))

  # upstream: _page.py:579
  def wait_for_load_state(self, state \\ nil, opts \\ []),
    do: Frame.wait_for_load_state(self[:_main_frame], state, locals_to_params(opts))

  # upstream: _page.py:586
  def wait_for_url(self, url, opts \\ []),
    do: Frame.wait_for_url(self[:_main_frame], url, locals_to_params(opts))

  # upstream: _page.py:594
  def wait_for_event(self, event, predicate \\ nil, timeout \\ nil) do
    cm = expect_event(self, event, predicate, timeout)
    event_info = EventContextManagerImpl.aenter(cm)
    EventContextManagerImpl.aexit(cm)
    Asyncio.Future.await(event_info)
  end

  # upstream: _page.py:841
  def title(self), do: Frame.title(self[:_main_frame])

  # upstream: _page.py:857
  def close(self, opts \\ []) do
    Py.set(self, :_close_reason, opts[:reason])
    if !opts[:runBeforeUnload], do: Py.set(self, :_close_was_called, true)

    try do
      cond do
        self[:_owned_context] -> BrowserContext.close(self[:_owned_context])
        opts[:runBeforeUnload] -> Channel.send(self[:_channel], "runBeforeUnload", nil)
        true -> Channel.send(self[:_channel], "close", nil, %{"reason" => opts[:reason]})
      end
    rescue
      e ->
        if !(Errors.is_target_closed_error(e) && !opts[:runBeforeUnload]),
          do: reraise(e, __STACKTRACE__)
    end

    nil
  end

  # upstream: _page.py:873
  def is_closed(self), do: self[:_is_closed]

  # upstream: _page.py:876
  def click(self, selector, opts \\ []),
    do: Frame._click(self[:_main_frame], selector, locals_to_params(opts))

  # upstream: _page.py:923
  def fill(self, selector, value, opts \\ []),
    do: Frame.fill(self[:_main_frame], selector, value, locals_to_params(opts))

  # upstream: _page.py:934
  def locator(self, selector, opts \\ []) do
    Frame.locator(self[:_main_frame], selector,
      hasText: opts[:hasText],
      hasNotText: opts[:hasNotText],
      has: opts[:has],
      hasNot: opts[:hasNot]
    )
  end

  # upstream: _page.py:950
  def get_by_alt_text(self, text, opts \\ []),
    do: Frame.get_by_alt_text(self[:_main_frame], text, exact: opts[:exact])

  # upstream: _page.py:955
  def get_by_label(self, text, opts \\ []),
    do: Frame.get_by_label(self[:_main_frame], text, exact: opts[:exact])

  # upstream: _page.py:960
  def get_by_placeholder(self, text, opts \\ []),
    do: Frame.get_by_placeholder(self[:_main_frame], text, exact: opts[:exact])

  # upstream: _page.py:965
  def get_by_ref(self, ref), do: locator(self, "aria-ref=#{ref}")

  # upstream: _page.py:968
  def get_by_role(self, role, opts \\ []) do
    Frame.get_by_role(self[:_main_frame], role,
      checked: opts[:checked],
      disabled: opts[:disabled],
      expanded: opts[:expanded],
      includeHidden: opts[:includeHidden],
      level: opts[:level],
      name: opts[:name],
      pressed: opts[:pressed],
      selected: opts[:selected],
      exact: opts[:exact],
      description: opts[:description]
    )
  end

  # upstream: _page.py:996
  def get_by_test_id(self, testId), do: Frame.get_by_test_id(self[:_main_frame], testId)

  # upstream: _page.py:999
  def get_by_text(self, text, opts \\ []),
    do: Frame.get_by_text(self[:_main_frame], text, exact: opts[:exact])

  # upstream: _page.py:1004
  def get_by_title(self, text, opts \\ []),
    do: Frame.get_by_title(self[:_main_frame], text, exact: opts[:exact])

  # upstream: _page.py:1067
  def select_option(self, selector, opts \\ []) do
    params = locals_to_params(opts)
    Frame.select_option(self[:_main_frame], selector, params)
  end

  # upstream: _page.py:1088
  def set_input_files(self, selector, files, opts \\ []),
    do: Frame.set_input_files(self[:_main_frame], selector, files, locals_to_params(opts))

  # upstream: _page.py:1122
  def check(self, selector, opts \\ []),
    do: Frame.check(self[:_main_frame], selector, locals_to_params(opts))

  # upstream: _page.py:1249
  def _close_error_with_reason(self) do
    TargetClosedError.new(
      self[:_close_reason] || BrowserContext._effective_close_reason(self[:_browser_context])
    )
  end

  # upstream: _page.py:1254
  def expect_event(self, event, predicate \\ nil, timeout \\ nil),
    do: _expect_event(self, event, predicate, timeout, ~s(waiting for event "#{event}"))

  # upstream: _page.py:1264
  def _expect_event(self, event, predicate \\ nil, timeout \\ nil, log_line \\ nil) do
    timeout =
      if timeout == nil, do: TimeoutSettings.timeout(self[:_timeout_settings]), else: timeout

    waiter = Waiter.init(self, "page.expect_event(#{event})")

    Waiter.reject_on_timeout(
      waiter,
      timeout,
      ~s(Timeout #{timeout}ms exceeded while waiting for event "#{event}")
    )

    if log_line, do: Waiter.log(waiter, log_line)

    if event != events().crash,
      do: Waiter.reject_on_event(waiter, self, events().crash, Error.new("Page crashed"))

    if event != events().close,
      do:
        Waiter.reject_on_event(waiter, self, events().close, fn ->
          _close_error_with_reason(self)
        end)

    Waiter.wait_for_event(waiter, self, event, predicate)
    EventContextManagerImpl.init(Waiter.result(waiter))
  end

  # upstream: _page.py:1295
  def expect_download(self, predicate \\ nil, timeout \\ nil),
    do: expect_event(self, events().download, predicate, timeout)

  # upstream: _page.py:1309
  def expect_navigation(self, opts \\ []),
    do: Frame.expect_navigation(main_frame(self), opts[:url], opts[:waitUntil], opts[:timeout])

  # upstream: _page.py:1317
  def expect_popup(self, predicate \\ nil, timeout \\ nil),
    do: expect_event(self, events().popup, predicate, timeout)
end
