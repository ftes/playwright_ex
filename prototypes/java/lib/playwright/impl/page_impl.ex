defmodule Playwright.Impl.PageImpl do
  # upstream: PageImpl.java:44
  use Playwright.Impl.ChannelOwner
  alias Playwright.{Frame, Page}

  alias Playwright.Impl.{
    DownloadImpl,
    FrameImpl,
    ListenerCollection,
    TargetClosedError,
    TimeoutSettings,
    UrlMatcher,
    Utils,
    WaitableEvent,
    WaitableRace,
    WaitableTimeout
  }

  alias Playwright.PlaywrightException

  # upstream: PageImpl.java:87
  defp event_subscriptions do
    %{
      console: "console",
      dialog: "dialog",
      dialogclosed: "dialogClosed",
      request: "request",
      response: "response",
      requestfinished: "requestFinished",
      requestfailed: "requestFailed",
      filechooser: "fileChooser"
    }
  end

  # upstream: PageImpl.java:132
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.init(__MODULE__, parent, type, guid, initializer)
    put(this, :frames, [])
    put(this, :listeners, ListenerCollection.new(event_subscriptions(), this))
    put(this, :browser_context, parent)
    main_frame = Connection.get_existing_object(this.connection, initializer["mainFrame"]["guid"])
    put(this, :main_frame, main_frame)
    put(main_frame, :page, this)
    put(this, :is_closed, initializer["isClosed"])
    if Map.has_key?(initializer, "viewportSize"), do: put(this, :viewport, initializer["viewportSize"])
    # keyboard, mouse, touchscreen, screencast, localStorage, sessionStorage: not ported
    update(this, :frames, [], &(&1 ++ [main_frame]))
    put(this, :timeout_settings, TimeoutSettings.new(get(parent, :timeout_settings)))
    put(this, :waitable_closed_or_crashed, create_wait_for_close_helper(this))

    if Map.has_key?(initializer, "opener") do
      put(this, :opener, Connection.get_existing_object(this.connection, initializer["opener"]["guid"]))
    else
      put(this, :opener, nil)
    end

    # video: not ported
    this
  end

  # upstream: PageImpl.java:165
  # Ported branches: download, frameAttached, frameDetached, crash, close.
  @impl true
  def handle_event(this, event, params) do
    cond do
      "download" == event ->
        artifact_guid = params["artifact"]["guid"]
        artifact = Connection.get_existing_object(this.connection, artifact_guid)
        download = DownloadImpl.new(this, artifact, params)
        ListenerCollection.notify(get(this, :listeners), :download, download)
        Playwright.Impl.BrowserContextImpl.notify_download(get(this, :browser_context), download)

      "frameAttached" == event ->
        guid = params["frame"]["guid"]
        frame = Connection.get_existing_object(this.connection, guid)
        update(this, :frames, [], &(&1 ++ [frame]))
        put(frame, :page, this)
        parent_frame = get(frame, :parent_frame)
        if parent_frame != nil, do: update(parent_frame, :child_frames, [], &(&1 ++ [frame]))
        ListenerCollection.notify(get(this, :listeners), :frameattached, frame)
        Playwright.Impl.BrowserContextImpl.notify_frame_attached(get(this, :browser_context), frame)

      "frameDetached" == event ->
        guid = params["frame"]["guid"]
        frame = Connection.get_existing_object(this.connection, guid)
        update(this, :frames, [], &List.delete(&1, frame))
        put(frame, :is_detached, true)
        parent_frame = get(frame, :parent_frame)
        if parent_frame != nil, do: update(parent_frame, :child_frames, [], &List.delete(&1, frame))
        ListenerCollection.notify(get(this, :listeners), :framedetached, frame)
        Playwright.Impl.BrowserContextImpl.notify_frame_detached(get(this, :browser_context), frame)

      "crash" == event ->
        ListenerCollection.notify(get(this, :listeners), :crash, this)

      "close" == event ->
        did_close(this)

      true ->
        nil
    end
  end

  # upstream: PageImpl.java:250
  def notify_popup(this, popup), do: ListenerCollection.notify(get(this, :listeners), :popup, popup)

  # upstream: PageImpl.java:254
  def did_close(this) do
    put(this, :is_closed, true)
    update(get(this, :browser_context), :pages, [], &List.delete(&1, this))
    ListenerCollection.notify(get(this, :listeners), :close, this)
    Playwright.Impl.BrowserContextImpl.notify_page_close(get(this, :browser_context), this)
  end

  # upstream: PageImpl.java:261
  def effective_close_reason(this) do
    if get(this, :close_reason) != nil,
      do: get(this, :close_reason),
      else: Playwright.Impl.BrowserContextImpl.effective_close_reason(get(this, :browser_context))
  end

  # upstream: PageImpl.java:269
  def on_close(this, handler), do: ListenerCollection.add(get(this, :listeners), :close, handler)

  # upstream: PageImpl.java:274
  def off_close(this, handler), do: ListenerCollection.remove(get(this, :listeners), :close, handler)

  # upstream: PageImpl.java:329
  def on_download(this, handler), do: ListenerCollection.add(get(this, :listeners), :download, handler)

  # upstream: PageImpl.java:399
  def on_popup(this, handler), do: ListenerCollection.add(get(this, :listeners), :popup, handler)

  # upstream: PageImpl.java:498
  def wait_for_download(this, options, code) do
    with_wait_logging(this, "Page.waitForDownload", fn _logger -> wait_for_download_impl(this, options, code) end)
  end

  # upstream: PageImpl.java:502
  defp wait_for_download_impl(this, options, code) do
    options = options || %Page.WaitForDownloadOptions{}
    wait_for_event_with_timeout(this, :download, code, options.predicate, options.timeout)
  end

  # upstream: PageImpl.java:523
  def wait_for_popup(this, options, code) do
    with_wait_logging(this, "Page.waitForPopup", fn _logger -> wait_for_popup_impl(this, options, code) end)
  end

  # upstream: PageImpl.java:527
  defp wait_for_popup_impl(this, options, code) do
    options = options || %Page.WaitForPopupOptions{}
    wait_for_event_with_timeout(this, :popup, code, options.predicate, options.timeout)
  end

  # upstream: PageImpl.java:558
  defp wait_for_event_with_timeout(this, event_type, code, predicate, timeout) do
    waitables = []
    waitables = waitables ++ [WaitableEvent.new(get(this, :listeners), event_type, predicate)]
    waitables = waitables ++ [create_wait_for_close_helper(this)]
    waitables = waitables ++ [create_waitable_timeout(this, timeout)]
    run_until(this, code, WaitableRace.new(waitables))
  end

  # upstream: PageImpl.java:567
  def close(this, options) do
    options = options || %Page.CloseOptions{}
    put(this, :close_reason, options.reason)

    try do
      cond do
        get(this, :owned_context) != nil ->
          raise PlaywrightException, message: "not ported: BrowserContextImpl.close"

        options.run_before_unload != nil and options.run_before_unload ->
          send_message(this, "runBeforeUnload", %{}, @no_timeout)

        true ->
          params = %{}
          params = if options.reason != nil, do: Map.put(params, "reason", options.reason), else: params
          send_message(this, "close", params, @no_timeout)
      end
    rescue
      exception in @playwright_exception ->
        if Utils.is_safe_close_error(exception) and (options.run_before_unload == nil or !options.run_before_unload),
          do: nil,
          else: reraise(exception, __STACKTRACE__)
    end
  end

  # upstream: PageImpl.java:744
  def context(this), do: get(this, :browser_context)

  # upstream: PageImpl.java:876
  def get_by_label(this, text, options) when is_binary(text) do
    FrameImpl.get_by_label(get(this, :main_frame), text, Utils.convert_type(options, Frame.GetByLabelOptions))
  end

  # upstream: PageImpl.java:881
  def get_by_label(this, %Regex{} = text, options) do
    FrameImpl.get_by_label(get(this, :main_frame), text, Utils.convert_type(options, Frame.GetByLabelOptions))
  end

  # upstream: PageImpl.java:901
  def get_by_role(this, role, options) do
    FrameImpl.get_by_role(get(this, :main_frame), role, Utils.convert_type(options, Frame.GetByRoleOptions))
  end

  # upstream: PageImpl.java:906
  def get_by_test_id(this, test_id) when is_binary(test_id) do
    FrameImpl.get_by_test_id(get(this, :main_frame), test_id)
  end

  # upstream: PageImpl.java:911
  def get_by_test_id(this, %Regex{} = test_id) do
    FrameImpl.get_by_test_id(get(this, :main_frame), test_id)
  end

  # upstream: PageImpl.java:975
  def navigate(this, url, options) do
    FrameImpl.navigate_impl(get(this, :main_frame), url, Utils.convert_type(options, Frame.NavigateOptions))
  end

  # upstream: PageImpl.java:1013
  def is_closed(this), do: get(this, :is_closed)

  # upstream: PageImpl.java:1082
  def locator(this, selector, options) do
    FrameImpl.locator(get(this, :main_frame), selector, Utils.convert_type(options, Frame.LocatorOptions))
  end

  # upstream: PageImpl.java:1087
  def main_frame(this), do: get(this, :main_frame)

  # upstream: PageImpl.java:1107
  def opener(this) do
    opener = get(this, :opener)
    if opener == nil or is_closed(opener), do: nil, else: opener
  end

  # upstream: PageImpl.java:1323
  def set_default_navigation_timeout(this, timeout),
    do: TimeoutSettings.set_default_navigation_timeout(get(this, :timeout_settings), timeout)

  # upstream: PageImpl.java:1328
  def set_default_timeout(this, timeout), do: TimeoutSettings.set_default_timeout(get(this, :timeout_settings), timeout)

  # upstream: PageImpl.java:1385
  def title(this), do: FrameImpl.title(get(this, :main_frame))

  # upstream: PageImpl.java:1454
  def url(this), do: FrameImpl.url(get(this, :main_frame))

  # upstream: PageImpl.java:1469
  def create_waitable_navigation_timeout(this, timeout) do
    WaitableTimeout.new(TimeoutSettings.navigation_timeout(get(this, :timeout_settings), timeout))
  end

  # upstream: PageImpl.java:1473
  def create_waitable_timeout(this, timeout), do: TimeoutSettings.create_waitable(get(this, :timeout_settings), timeout)

  # upstream: PageImpl.java:1483
  def wait_for_load_state(this, state, options) do
    load_state = if state == nil, do: :load, else: state

    with_title(this, "Wait for load state \"" <> String.downcase(to_string(load_state)) <> "\"", fn ->
      with_wait_logging(this, "Page.waitForLoadState", fn logger ->
        FrameImpl.wait_for_load_state_impl(
          get(this, :main_frame),
          load_state,
          Utils.convert_type(options, Frame.WaitForLoadStateOptions),
          logger
        )

        nil
      end)
    end)
  end

  # upstream: PageImpl.java:1508
  def frame_navigated(this, frame) do
    ListenerCollection.notify(get(this, :listeners), :framenavigated, frame)
    Playwright.Impl.BrowserContextImpl.notify_frame_navigated(get(this, :browser_context), frame)
  end

  defmodule WaitableFrameDetach do
    # upstream: PageImpl.java:1513
    use Playwright.Impl.WaitableEvent

    # upstream: PageImpl.java:1514
    def new(outer, frame_arg) do
      listeners = Playwright.Impl.Heap.get(outer, :listeners)
      Playwright.Impl.WaitableEvent.init(__MODULE__, listeners, :framedetached, &(frame_arg == &1), outer)
    end

    # upstream: PageImpl.java:1519
    def get(_this), do: raise(PlaywrightException, message: "Navigating frame was detached")
  end

  # upstream: PageImpl.java:1525
  def create_waitable_frame_detach(this, frame), do: WaitableFrameDetach.new(this, frame)

  # upstream: PageImpl.java:1530
  def create_wait_for_close_helper(this),
    do: WaitableRace.new([__MODULE__.WaitablePageClose.new(this), __MODULE__.WaitablePageCrash.new(this)])

  defmodule WaitablePageClose do
    # upstream: PageImpl.java:1534
    use Playwright.Impl.WaitableEvent

    # upstream: PageImpl.java:1535
    def new(outer) do
      Playwright.Impl.WaitableEvent.init(__MODULE__, Playwright.Impl.Heap.get(outer, :listeners), :close, nil, outer)
    end

    # upstream: PageImpl.java:1540
    def get(this), do: raise(TargetClosedError, Playwright.Impl.PageImpl.effective_close_reason(this.outer))
  end

  defmodule WaitablePageCrash do
    # upstream: PageImpl.java:1545
    use Playwright.Impl.WaitableEvent

    # upstream: PageImpl.java:1546
    def new(outer) do
      Playwright.Impl.WaitableEvent.init(__MODULE__, Playwright.Impl.Heap.get(outer, :listeners), :crash, nil, outer)
    end

    # upstream: PageImpl.java:1551
    def get(_this), do: raise(TargetClosedError, "Page crashed")
  end

  # upstream: PageImpl.java:1654
  def wait_for_url(this, url, options) when is_binary(url) do
    context = get(this, :browser_context)
    local_utils = Connection.local_utils(this.connection)

    wait_for_url(
      this,
      UrlMatcher.for_glob(Playwright.Impl.BrowserContextImpl.base_url(context), url, local_utils, false),
      options
    )
  end

  # upstream: PageImpl.java:1659
  def wait_for_url(this, %Regex{} = url, options), do: wait_for_url(this, UrlMatcher.new(url), options)

  # upstream: PageImpl.java:1664
  def wait_for_url(this, url, options) when is_function(url, 1), do: wait_for_url(this, UrlMatcher.new(url), options)

  # upstream: PageImpl.java:1668
  def wait_for_url(this, %UrlMatcher{} = matcher, options) do
    with_wait_logging(this, "Page.waitForURL", fn logger ->
      FrameImpl.wait_for_url_impl(
        get(this, :main_frame),
        logger,
        matcher,
        Utils.convert_type(options, Frame.WaitForURLOptions)
      )

      nil
    end)
  end
end
