defmodule Playwright.Core.Page do
  @moduledoc "upstream: Core/Page.cs"
  use Playwright.Transport.ChannelOwner, [:initializer, :main_frame, :timeout_settings]

  alias Playwright.Core.BrowserContext
  alias Playwright.Core.Download
  alias Playwright.Core.DriverMessages
  alias Playwright.Core.Frame
  alias Playwright.Core.Locator
  alias Playwright.Core.PageEvent
  alias Playwright.Core.TimeoutSettings
  alias Playwright.Core.Waiter
  alias Playwright.Helpers.TaskCompletionSource
  alias Playwright.PlaywrightException
  alias Playwright.TargetClosedException
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Connection
  alias Playwright.Transport.Converters
  import ChannelOwner, only: [get: 2, set: 3, update: 3, emit: 3]

  # upstream: Core/Page.cs:56
  def new(parent, guid, initializer) do
    context = parent
    this = ChannelOwner.new(__MODULE__, parent, guid,
      initializer: initializer,
      main_frame: initializer.main_frame,
      timeout_settings: nil)
    this = %{this | timeout_settings: TimeoutSettings.new(this, context.timeout_settings)}
    Connection.put_object(this.connection, guid, this)
    set(this, :context, context)

    set(initializer.main_frame, :page, this)
    set(this, :frames, [initializer.main_frame])
    if initializer.viewport_size != nil do
      set(this, :viewport_size, %{width: initializer.viewport_size["width"], height: initializer.viewport_size["height"]})
    end

    set(this, :is_closed, initializer.is_closed)
    # skipped: Keyboard, Touchscreen, Mouse, APIRequest, _video, _screencast, LocalStorage, SessionStorage

    ChannelOwner.add_handler(this, "Close", fn _ -> TaskCompletionSource.try_set_result(closed_or_crashed_tcs(this), true) end)
    ChannelOwner.add_handler(this, "Crash", fn _ -> TaskCompletionSource.try_set_result(closed_or_crashed_tcs(this), true) end)
    this
  end

  # upstream: Core/Page.cs:173
  def is_closed(this), do: get(this, :is_closed)

  # upstream: Core/Page.cs:175
  def close_was_called(this), do: get(this, :close_was_called) == true

  # upstream: Core/Page.cs:179
  def main_frame(this), do: this.main_frame

  # upstream: Core/Page.cs:185
  def context(this), do: get(this, :context)

  # upstream: Core/Page.cs:196
  def url(this), do: Frame.url(main_frame(this))

  # upstream: Core/Page.cs:198
  def frames(this), do: get(this, :frames)

  # upstream: Core/Page.cs:225
  def owned_context(this), do: get(this, :owned_context)

  # upstream: Core/Page.cs:229
  def opener(this), do: this.initializer.opener

  # upstream: Core/Page.cs:231
  def closed_or_crashed_tcs(this), do: TaskCompletionSource.new(this, :closed_or_crashed_tcs)

  # upstream: Core/Page.cs:235
  @impl true
  def on_message(this, method, server_params) do
    case method do
      "close" ->
        on_close(this)
      "crash" ->
        channel_crashed(this)
      "popup" ->
        emit(this, "Popup", Converters.to_channel_owner(server_params["page"], this.connection))
      "frameAttached" ->
        channel_frame_attached(this, Converters.to_channel_owner(server_params["frame"], this.connection))
      "frameDetached" ->
        channel_frame_detached(this, Converters.to_channel_owner(server_params["frame"], this.connection))
      "download" ->
        download = Download.new(this, server_params["url"], server_params["suggestedFilename"], Converters.to_channel_owner(server_params["artifact"], this.connection))
        emit(this, "Download", download)
        if context(this), do: BrowserContext.fire_download(context(this), download)
      "viewportSizeChanged" ->
        size = server_params["viewportSize"]
        set(this, :viewport_size, %{width: size["width"], height: size["height"]})
      # skipped: bindingCall, route, webSocketRoute, fileChooser, locatorHandlerTriggered, webSocket,
      #          screencastFrame, worker
      _ ->
        :ok
    end
  end

  # upstream: Core/Page.cs:313
  def title_async(this), do: Frame.title_async(main_frame(this))

  # upstream: Core/Page.cs:339
  def goto_async(this, url, options \\ nil),
    do: Frame.goto_async(main_frame(this), url, wait_until: options[:wait_until], timeout: options[:timeout], referer: options[:referer])

  # upstream: Core/Page.cs:343 + :347 + :351 (string | Regex | fun overloads)
  def wait_for_url_async(this, url, options \\ nil),
    do: Frame.wait_for_url_async(main_frame(this), url, wait_until: options[:wait_until], timeout: options[:timeout])

  # upstream: Core/Page.cs:363
  def wait_for_popup_async(this, options \\ nil),
    do: inner_wait_for_event_async(this, PageEvent.popup(), nil, options[:predicate], options[:timeout])

  # upstream: Core/Page.cs:431
  def wait_for_download_async(this, options \\ nil),
    do: inner_wait_for_event_async(this, PageEvent.download(), nil, options[:predicate], options[:timeout])

  # upstream: Core/Page.cs:435
  def run_and_wait_for_download_async(this, action, options \\ nil),
    do: inner_wait_for_event_async(this, PageEvent.download(), action, options[:predicate], options[:timeout])

  # upstream: Core/Page.cs:443
  def run_and_wait_for_popup_async(this, action, options \\ nil),
    do: inner_wait_for_event_async(this, PageEvent.popup(), action, options[:predicate], options[:timeout])

  # upstream: Core/Page.cs:486
  def close_error_with_reason(this) do
    TargetClosedException.new(get(this, :close_reason) || BrowserContext.effective_close_reason(context(this)))
  end

  # upstream: Core/Page.cs:491
  def inner_wait_for_event_async(this, page_event, action \\ nil, predicate \\ nil, timeout \\ nil) do
    if page_event == nil do
      raise ArgumentError, "Page event is required"
    end

    timeout = TimeoutSettings.timeout(this.timeout_settings, timeout)
    waiter = Waiter.new(this, "page.WaitForEventAsync(\"#{page_event.name}\")")
    try do
      Waiter.reject_on_timeout(waiter, trunc(timeout), "Timeout #{timeout}ms exceeded while waiting for event \"#{page_event.name}\"")

      if page_event.name != PageEvent.crash().name do
        Waiter.reject_on_event(waiter, this, PageEvent.crash().name, PlaywrightException.new("Page crashed"))
      end

      if page_event.name != PageEvent.close().name do
        Waiter.reject_on_event(waiter, this, PageEvent.close().name, fn -> close_error_with_reason(this) end)
      end

      wait_for_event_task = Waiter.wait_for_event_async(waiter, this, page_event.name, predicate)
      if action != nil do
        Waiter.cancel_wait_on_exception_async(waiter, wait_for_event_task, action)
      end

      wait_for_event_task.()
    after
      Waiter.dispose(waiter)
    end
  end

  # upstream: Core/Page.cs:522
  def dispose_async(this), do: close_async(this)

  # upstream: Core/Page.cs:525
  def close_async(this, options \\ nil) do
    set(this, :close_reason, options[:reason])
    set(this, :close_was_called, true)
    try do
      cond do
        owned_context(this) != nil ->
          BrowserContext.close(owned_context(this))
        options[:run_before_unload] == true ->
          ChannelOwner.send_message_to_server(this, "runBeforeUnload")
        true ->
          ChannelOwner.send_message_to_server(
          this,
          "close",
          %{
            "reason" => options[:reason],
          })
      end
    rescue
      e ->
        if DriverMessages.is_target_closed_error(e) and options[:run_before_unload] != true, do: :ok, else: reraise(e, __STACKTRACE__)
    end
    :ok
  end

  # upstream: Core/Page.cs:566
  def locator(this, selector, options \\ nil),
    do: Frame.locator(main_frame(this), selector,
      has: options[:has],
      has_text: options[:has_text])

  # upstream: Core/Page.cs:1027
  def wait_for_load_state_async(this, state \\ nil, options \\ nil),
    do: Frame.wait_for_load_state_async(main_frame(this), state, timeout: options[:timeout])

  # upstream: Core/Page.cs:1210
  def set_default_navigation_timeout(this, timeout) do
    TimeoutSettings.set_default_navigation_timeout(this.timeout_settings, timeout)
  end

  # upstream: Core/Page.cs:1216
  def set_default_timeout(this, timeout) do
    TimeoutSettings.set_default_timeout(this.timeout_settings, timeout)
  end

  # upstream: Core/Page.cs:1243
  def notify_popup(this, page), do: emit(this, "Popup", page)

  # upstream: Core/Page.cs:1245
  def on_frame_navigated(this, frame) do
    emit(this, "FrameNavigated", frame)
    if context(this), do: BrowserContext.fire_frame_navigated(context(this), frame)
  end

  # upstream: Core/Page.cs:1267
  def fire_load(this) do
    emit(this, "Load", this)
    if context(this), do: BrowserContext.fire_page_load(context(this), this)
  end

  # upstream: Core/Page.cs:1273
  def fire_dom_content_loaded(this), do: emit(this, "DOMContentLoaded", this)

  # upstream: Core/Page.cs:1338
  def on_close(this) do
    set(this, :is_closed, true)
    update(context(this), :pages, &List.delete(&1, this))
    # skipped: DisposeHarRouters();
    emit(this, "Close", this)
    if context(this), do: BrowserContext.fire_page_close(context(this), this)
  end

  # upstream: Core/Page.cs:1347
  defp channel_crashed(this) do
    emit(this, "Crash", this)
  end

  # upstream: Core/Page.cs:1411
  defp channel_frame_detached(this, args) do
    frame = args
    update(this, :frames, &List.delete(&1, frame))
    set(frame, :is_detached, true)
    if Frame.parent_frame(frame), do: update(Frame.parent_frame(frame), :child_frames, &List.delete(&1, frame))
    emit(this, "FrameDetached", args)
    if context(this), do: BrowserContext.fire_frame_detached(context(this), args)
  end

  # upstream: Core/Page.cs:1421
  defp channel_frame_attached(this, args) do
    frame = args
    set(frame, :page, this)
    update(this, :frames, &(&1 ++ [frame]))
    if Frame.parent_frame(frame), do: update(Frame.parent_frame(frame), :child_frames, &(&1 ++ [frame]))
    emit(this, "FrameAttached", args)
    if context(this), do: BrowserContext.fire_frame_attached(context(this), args)
  end

  # upstream: Core/Page.cs:1513 + :1517
  def get_by_label(this, text, options \\ nil),
    do: Frame.get_by_label(main_frame(this), text, exact: options[:exact])

  # upstream: Core/Page.cs:1532
  def get_by_role(this, role, options \\ nil),
    do: locator(this, Locator.get_by_role_selector(role, options || []))

  # upstream: Core/Page.cs:1536 + :1540
  def get_by_test_id(this, test_id),
    do: Frame.get_by_test_id(main_frame(this), test_id)
end
