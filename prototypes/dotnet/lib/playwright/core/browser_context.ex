defmodule Playwright.Core.BrowserContext do
  @moduledoc "upstream: Core/BrowserContext.cs"
  use Playwright.Transport.ChannelOwner, [:initializer, :base_url, :timeout_settings]

  alias Playwright.Core.BrowserContextEvent
  alias Playwright.Core.Page
  alias Playwright.Core.TimeoutSettings
  alias Playwright.Core.Waiter
  alias Playwright.Helpers.TaskCompletionSource
  alias Playwright.PlaywrightException
  alias Playwright.TargetClosedException
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Converters
  import ChannelOwner, only: [get: 2, set: 3, update: 3, emit: 3]

  # upstream: Core/BrowserContext.cs:44
  defp close_tcs(this), do: TaskCompletionSource.new(this, :close_tcs)

  # upstream: Core/BrowserContext.cs:62
  def new(parent, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, guid,
      initializer: initializer,
      base_url: initializer.options["baseURL"],
      timeout_settings: nil)
    this = %{this | timeout_settings: TimeoutSettings.new(this)}
    Playwright.Transport.Connection.put_object(this.connection, guid, this)
    set(this, :pages, [])
    # skipped: _tracing = initializer.Tracing; _clock = new Clock(this); Credentials = new Credentials(this);
    # skipped: _request = initializer.RequestContext; _request._timeoutSettings = this._timeoutSettings;
    this
  end

  # upstream: Core/BrowserContext.cs:160
  def browser(this), do: get(this, :browser)

  # upstream: Core/BrowserContext.cs:162
  def pages(this), do: get(this, :pages)

  # upstream: Core/BrowserContext.cs:164
  def owner_page(this), do: get(this, :owner_page)

  # upstream: Core/BrowserContext.cs:166
  def base_url(this), do: this.base_url

  # upstream: Core/BrowserContext.cs:168
  def closing_or_closed(this), do: get(this, :closing_or_closed) == true

  # upstream: Core/BrowserContext.cs:170
  def is_closed(this), do: closing_or_closed(this)

  # upstream: Core/BrowserContext.cs:180
  @impl true
  def on_message(this, method, server_params) do
    case method do
      "close" ->
        on_close(this)
      "page" ->
        channel_on_page(
          this,
          Converters.to_channel_owner(server_params["page"], this.connection))
      # skipped: bindingCall, dialog, dialogClosed, console, route, webSocketRoute, pageError,
      #          serviceWorker, request, requestFinished, requestFailed, response
      _ ->
        :ok
    end
  end

  # upstream: Core/BrowserContext.cs:313
  def initialize_har_from_options_async(_this, options) do
    if options[:record_har_path] in [nil, ""] do
      :ok
    else
      raise PlaywrightException.new("RecordHar not ported")
    end
  end

  # upstream: Core/BrowserContext.cs:402
  def close(this, options \\ nil) do
    if !closing_or_closed(this) do
      set(this, :close_reason, options[:reason])
      set(this, :closing_or_closed, true)
      # skipped: await _request.DisposeAsync(options?.Reason);
      # skipped: harError / _tracing.ExportAllHarsAsync()
      ChannelOwner.send_message_to_server(this, "close", %{
        "reason" => options[:reason],
      })
      TaskCompletionSource.await(close_tcs(this))
    end
    :ok
  end

  # upstream: Core/BrowserContext.cs:534
  def new_page(this) do
    if owner_page(this) != nil do
      raise PlaywrightException.new("Please use Browser.NewContextAsync()")
    end

    ChannelOwner.send_message_to_server(this, "newPage", nil, as: Page)
  end

  # upstream: Core/BrowserContext.cs:663
  def effective_close_reason(this) do
    get(this, :close_reason) || (browser(this) && get(browser(this), :close_reason))
  end

  # upstream: Core/BrowserContext.cs:668
  def inner_wait_for_event_async(this, playwright_event, action \\ nil, predicate \\ nil, timeout \\ nil) do
    if playwright_event == nil do
      raise ArgumentError, "Page event is required"
    end

    timeout = TimeoutSettings.timeout(this.timeout_settings, timeout)
    waiter = Waiter.new(this, "context.WaitForEventAsync(\"#{playwright_event.name}\")")
    try do
      Waiter.reject_on_timeout(waiter, trunc(timeout), "Timeout #{timeout}ms exceeded while waiting for event \"#{playwright_event.name}\"")

      if playwright_event.name != BrowserContextEvent.close().name do
        Waiter.reject_on_event(waiter, this, BrowserContextEvent.close().name, fn -> TargetClosedException.new(effective_close_reason(this)) end)
      end

      result = Waiter.wait_for_event_async(waiter, this, playwright_event.name, predicate)
      if action != nil do
        Waiter.cancel_wait_on_exception_async(waiter, result, action)
      end

      result.()
    after
      Waiter.dispose(waiter)
    end
  end

  # upstream: Core/BrowserContext.cs:694
  def wait_for_page_async(this, options \\ nil),
    do: inner_wait_for_event_async(this, BrowserContextEvent.page(), nil, options[:predicate], options[:timeout])

  # upstream: Core/BrowserContext.cs:698
  def run_and_wait_for_page_async(this, action, options \\ nil),
    do: inner_wait_for_event_async(this, BrowserContextEvent.page(), action, options[:predicate], options[:timeout])

  # upstream: Core/BrowserContext.cs:713
  def set_default_navigation_timeout(this, timeout), do: set_default_navigation_timeout_impl(this, timeout)

  # upstream: Core/BrowserContext.cs:715
  def set_default_navigation_timeout_impl(this, timeout) do
    TimeoutSettings.set_default_navigation_timeout(this.timeout_settings, timeout)
  end

  # upstream: Core/BrowserContext.cs:721
  def set_default_timeout(this, timeout), do: set_default_timeout_impl(this, timeout)

  # upstream: Core/BrowserContext.cs:723
  def set_default_timeout_impl(this, timeout) do
    TimeoutSettings.set_default_timeout(this.timeout_settings, timeout)
  end

  # upstream: Core/BrowserContext.cs:856
  def on_close(this) do
    set(this, :closing_or_closed, true)
    if browser(this) != nil do
      update(browser(this), :contexts, &List.delete(&1, this))
      # skipped: _browserType.Playwright._selectors._contextsForSelectors.Remove(this);
    end

    # skipped: DisposeHarRouters(); _tracing.ResetStackCounter(); _request._tracing.ResetStackCounter();
    emit(this, "Close", this)
    TaskCompletionSource.try_set_result(close_tcs(this), true)
  end

  # upstream: Core/BrowserContext.cs:872
  def fire_page_close(this, page), do: emit(this, "PageClose", page)

  # upstream: Core/BrowserContext.cs:874
  def fire_page_load(this, page), do: emit(this, "PageLoad", page)

  # upstream: Core/BrowserContext.cs:876
  def fire_frame_attached(this, frame), do: emit(this, "FrameAttached", frame)

  # upstream: Core/BrowserContext.cs:878
  def fire_frame_detached(this, frame), do: emit(this, "FrameDetached", frame)

  # upstream: Core/BrowserContext.cs:880
  def fire_frame_navigated(this, frame), do: emit(this, "FrameNavigated", frame)

  # upstream: Core/BrowserContext.cs:882
  def fire_download(this, download), do: emit(this, "Download", download)

  # upstream: Core/BrowserContext.cs:884
  defp channel_on_page(this, page) do
    set(page, :context, this)
    update(this, :pages, &(&1 ++ [page]))
    emit(this, "Page", page)

    if Page.opener(page) != nil and Page.is_closed(Page.opener(page)) == false do
      Page.notify_popup(Page.opener(page), page)
    end
  end
end
