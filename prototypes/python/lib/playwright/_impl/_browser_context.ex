# upstream: playwright/_impl/_browser_context.py (subset)
defmodule Playwright.Impl.BrowserContext do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.{Channel, ChannelOwner}
  alias Playwright.Impl.{Browser, EventContextManagerImpl, Page, Waiter}
  alias Playwright.Impl.Errors.{Error, TargetClosedError}
  alias Playwright.Impl.Helper.TimeoutSettings
  import Playwright.Impl.Connection, only: [from_channel: 1]

  # Events = SimpleNamespace(...)
  def events, do: %{close: "close", page: "page", download: "download"}

  # upstream: _browser_context.py:115
  def init(parent, type, guid, initializer) do
    self = ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)

    # Browser is null for browser contexts created outside of normal browser, e.g. android or electron.
    Py.set(self, :_browser, nil)
    if is_struct(parent, Browser), do: Py.set(self, :_browser, parent)
    Py.set(self, :_pages, [])
    Py.set(self, :_routes, [])
    Py.set(self, :_web_socket_routes, [])
    Py.set(self, :_bindings, %{})
    Py.set(self, :_timeout_settings, TimeoutSettings.init(nil))
    Py.set(self, :_owner_page, nil)
    Py.set(self, :_options, initializer["options"])
    Py.set(self, :_service_workers, MapSet.new())
    Py.set(self, :_base_url, self[:_options]["baseURL"])
    Py.set(self, :_videos_dir, self[:_options]["recordVideo"])
    Py.set(self, :_tracing, from_channel(initializer["tracing"]))
    Py.set(self, :_debugger, from_channel(initializer["debugger"]))
    Py.set(self, :_request, from_channel(initializer["requestContext"]))
    Py.set(self[:_request], :_timeout_settings, self[:_timeout_settings])
    # self._clock = Clock(self); self._credentials = Credentials(self)  (omitted)
    # bindingCall (omitted)
    Channel.on(self[:_channel], "close", fn _ -> _on_close(self) end)

    Channel.on(self[:_channel], "page", fn params ->
      _on_page(self, from_channel(params["page"]))
    end)

    # route, webSocketRoute, serviceWorker, console, dialog, dialogClosed, pageError,
    # request, response, requestFailed, requestFinished (omitted)
    Py.set(self, :_closed_future, Asyncio.Future.new())

    once(self, events().close, fn _context ->
      Asyncio.Future.set_result(self[:_closed_future], true)
    end)

    Py.set(self, :_close_reason, nil)
    Py.set(self, :_har_routers, [])
    _set_event_to_subscription_mapping(self, %{})
    Py.set(self, :_closing_or_closed, false)
    self
  end

  # upstream: _browser_context.py:246
  def _on_page(self, page) do
    Py.append(self, :_pages, page)
    emit(self, events().page, page)

    if page[:_opener] && not Page.is_closed(page[:_opener]),
      do: Page.emit(page[:_opener], Page.events().popup, page)
  end

  # upstream: _browser_context.py:305
  def set_default_navigation_timeout(self, timeout),
    do: _set_default_navigation_timeout_impl(self, timeout)

  # upstream: _browser_context.py:308
  def _set_default_navigation_timeout_impl(self, timeout),
    do: TimeoutSettings.set_default_navigation_timeout(self[:_timeout_settings], timeout)

  # upstream: _browser_context.py:311
  def set_default_timeout(self, timeout), do: _set_default_timeout_impl(self, timeout)

  # upstream: _browser_context.py:314
  def _set_default_timeout_impl(self, timeout),
    do: TimeoutSettings.set_default_timeout(self[:_timeout_settings], timeout)

  # upstream: _browser_context.py:318
  def pages(self), do: self[:_pages]

  # upstream: _browser_context.py:322
  def browser(self), do: self[:_browser]

  # upstream: _browser_context.py:350
  def new_page(self) do
    if self[:_owner_page], do: raise(Error.new("Please use browser.new_context()"))
    from_channel(Channel.send(self[:_channel], "newPage", nil))
  end

  # upstream: _browser_context.py:521
  def expect_event(self, event, predicate \\ nil, timeout \\ nil) do
    timeout =
      if timeout == nil, do: TimeoutSettings.timeout(self[:_timeout_settings]), else: timeout

    waiter = Waiter.init(self, "browser_context.expect_event(#{event})")

    Waiter.reject_on_timeout(
      waiter,
      timeout,
      ~s(Timeout #{timeout}ms exceeded while waiting for event "#{event}")
    )

    if event != events().close,
      do: Waiter.reject_on_event(waiter, self, events().close, fn -> TargetClosedError.new() end)

    Waiter.wait_for_event(waiter, self, event, predicate)
    EventContextManagerImpl.init(Waiter.result(waiter))
  end

  # upstream: _browser_context.py:540
  def _on_close(self) do
    Py.set(self, :_closing_or_closed, true)

    if self[:_browser] do
      if self in self[:_browser][:_contexts],
        do: Py.set(self[:_browser], :_contexts, MapSet.delete(self[:_browser][:_contexts], self))

      true = self[:_browser][:_browser_type] != nil
      selectors = self[:_browser][:_browser_type][:_playwright][:selectors]

      if self in selectors[:_contexts_for_selectors],
        do:
          Py.set(
            selectors,
            :_contexts_for_selectors,
            MapSet.delete(selectors[:_contexts_for_selectors], self)
          )
    end

    # _dispose_har_routers / tracing._reset_stack_counter (omitted)
    emit(self, events().close, self)
  end

  # upstream: _browser_context.py:559
  def is_closed(self), do: self[:_closing_or_closed]

  # upstream: _browser_context.py:562
  def close(self, opts \\ []) do
    if not self[:_closing_or_closed] do
      Py.set(self, :_close_reason, opts[:reason])
      Py.set(self, :_closing_or_closed, true)
      # await self.request.dispose(reason=reason); tracing._export_all_hars() (omitted)
      Channel.send(self[:_channel], "close", nil, %{"reason" => opts[:reason]})
      Asyncio.Future.await(self[:_closed_future])
    end

    nil
  end

  # upstream: _browser_context.py:602
  def _effective_close_reason(self) do
    cond do
      self[:_close_reason] -> self[:_close_reason]
      self[:_browser] -> self[:_browser][:_close_reason]
      true -> nil
    end
  end

  # upstream: _browser_context.py:609
  def wait_for_event(self, event, predicate \\ nil, timeout \\ nil) do
    cm = expect_event(self, event, predicate, timeout)
    event_info = EventContextManagerImpl.aenter(cm)
    EventContextManagerImpl.aexit(cm)
    Asyncio.Future.await(event_info)
  end

  # upstream: _browser_context.py:623
  def expect_page(self, predicate \\ nil, timeout \\ nil),
    do: expect_event(self, events().page, predicate, timeout)
end
