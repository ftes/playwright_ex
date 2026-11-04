defmodule Playwright.Impl.BrowserContextImpl do
  # upstream: BrowserContextImpl.java:43
  use Playwright.Impl.ChannelOwner
  alias Playwright.BrowserContext.WaitForPageOptions
  alias Playwright.Impl.{ListenerCollection, TargetClosedError, TimeoutSettings, WaitableEvent, WaitableRace}
  alias Playwright.PlaywrightException

  # upstream: BrowserContextImpl.java:60
  defp event_subscriptions do
    %{
      console: "console",
      dialog: "dialog",
      dialogclosed: "dialogClosed",
      request: "request",
      response: "response",
      requestfinished: "requestFinished",
      requestfailed: "requestFailed"
    }
  end

  # upstream: BrowserContextImpl.java:93
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.init(__MODULE__, parent, type, guid, initializer)
    put(this, :pages, [])
    put(this, :listeners, ListenerCollection.new(event_subscriptions(), this))
    put(this, :timeout_settings, TimeoutSettings.new())
    put(this, :tracing, Connection.get_existing_object(this.connection, initializer["tracing"]["guid"]))
    put(this, :debugger, Connection.get_existing_object(this.connection, initializer["debugger"]["guid"]))
    put(this, :request, Connection.get_existing_object(this.connection, initializer["requestContext"]["guid"]))
    put(get(this, :request), :timeout_settings, get(this, :timeout_settings))
    # clock = new ClockImpl(this); credentials = new CredentialsImpl(this): not ported
    put(this, :close_promise, WaitableEvent.new(get(this, :listeners), :close))
    this
  end

  # upstream: BrowserContextImpl.java:112
  def base_url(this) do
    url = this.initializer["options"]["baseURL"]
    if url != nil, do: URI.parse(url), else: nil
  end

  # upstream: BrowserContextImpl.java:123
  def effective_close_reason(this) do
    cond do
      get(this, :close_reason) != nil -> get(this, :close_reason)
      get(this, :browser) != nil -> get(get(this, :browser), :close_reason)
      true -> nil
    end
  end

  # upstream: BrowserContextImpl.java:142
  def on_download(this, handler), do: ListenerCollection.add(get(this, :listeners), :download, handler)

  # upstream: BrowserContextImpl.java:147
  def off_download(this, handler), do: ListenerCollection.remove(get(this, :listeners), :download, handler)

  # upstream: BrowserContextImpl.java:151
  def notify_download(this, download), do: ListenerCollection.notify(get(this, :listeners), :download, download)

  # upstream: BrowserContextImpl.java:156
  def on_close(this, handler), do: ListenerCollection.add(get(this, :listeners), :close, handler)

  # upstream: BrowserContextImpl.java:161
  def off_close(this, handler), do: ListenerCollection.remove(get(this, :listeners), :close, handler)

  # upstream: BrowserContextImpl.java:196
  def on_page(this, handler), do: ListenerCollection.add(get(this, :listeners), :page, handler)

  # upstream: BrowserContextImpl.java:201
  def off_page(this, handler), do: ListenerCollection.remove(get(this, :listeners), :page, handler)

  # upstream: BrowserContextImpl.java:215
  def notify_frame_attached(this, frame), do: ListenerCollection.notify(get(this, :listeners), :frameattached, frame)

  # upstream: BrowserContextImpl.java:229
  def notify_frame_detached(this, frame), do: ListenerCollection.notify(get(this, :listeners), :framedetached, frame)

  # upstream: BrowserContextImpl.java:243
  def notify_frame_navigated(this, frame), do: ListenerCollection.notify(get(this, :listeners), :framenavigated, frame)

  # upstream: BrowserContextImpl.java:257
  def notify_page_close(this, page), do: ListenerCollection.notify(get(this, :listeners), :pageclose, page)

  # upstream: BrowserContextImpl.java:271
  def notify_page_load(this, page), do: ListenerCollection.notify(get(this, :listeners), :pageload, page)

  # upstream: BrowserContextImpl.java:335
  defp wait_for_event_with_timeout(this, event_type, code, predicate, timeout) do
    waitables = []
    waitables = waitables ++ [WaitableEvent.new(get(this, :listeners), event_type, predicate)]
    waitables = waitables ++ [__MODULE__.WaitableContextClose.new(this)]
    waitables = waitables ++ [TimeoutSettings.create_waitable(get(this, :timeout_settings), timeout)]
    run_until(this, code, WaitableRace.new(waitables))
  end

  # upstream: BrowserContextImpl.java:344
  def wait_for_page(this, options, code) do
    with_wait_logging(this, "BrowserContext.close", fn _logger -> wait_for_page_impl(this, options, code) end)
  end

  # upstream: BrowserContextImpl.java:348
  defp wait_for_page_impl(this, options, code) do
    options = options || %WaitForPageOptions{}
    wait_for_event_with_timeout(this, :page, code, options.predicate, options.timeout)
  end

  # upstream: BrowserContextImpl.java:372
  def is_closed(this), do: get(this, :closing_or_closed) == true

  # upstream: BrowserContextImpl.java:437
  def browser(this), do: get(this, :browser)

  # upstream: BrowserContextImpl.java:507
  def new_page(this) do
    if get(this, :owner_page) != nil, do: raise(PlaywrightException, message: "Please use browser.newContext()")
    json = send_message(this, "newPage")
    Connection.get_existing_object(this.connection, json["page"]["guid"])
  end

  # upstream: BrowserContextImpl.java:516
  def pages(this), do: get(this, :pages)

  # upstream: BrowserContextImpl.java:591
  def set_default_navigation_timeout(this, timeout),
    do: TimeoutSettings.set_default_navigation_timeout(get(this, :timeout_settings), timeout)

  # upstream: BrowserContextImpl.java:596
  def set_default_timeout(this, timeout), do: TimeoutSettings.set_default_timeout(get(this, :timeout_settings), timeout)

  defmodule WaitableContextClose do
    # upstream: BrowserContextImpl.java:715  (private inner class extends WaitableEvent)
    use Playwright.Impl.WaitableEvent

    # upstream: BrowserContextImpl.java:716
    def new(outer) do
      Playwright.Impl.WaitableEvent.init(__MODULE__, Playwright.Impl.Heap.get(outer, :listeners), :close, nil, outer)
    end

    # upstream: BrowserContextImpl.java:721
    def get(this), do: raise(TargetClosedError, Playwright.Impl.BrowserContextImpl.effective_close_reason(this.outer))
  end

  # upstream: BrowserContextImpl.java:760
  # Only the events needed by the prototype are ported (page, close); dialog/route/console/request/... are not.
  @impl true
  def handle_event(this, event, params) do
    cond do
      "page" == event ->
        page = Connection.get_existing_object(this.connection, params["page"]["guid"])
        update(this, :pages, [], &(&1 ++ [page]))
        ListenerCollection.notify(get(this, :listeners), :page, page)

        opener = Playwright.Impl.PageImpl.opener(page)

        if opener != nil and !Playwright.Impl.PageImpl.is_closed(opener),
          do: Playwright.Impl.PageImpl.notify_popup(opener, page)

      "close" == event ->
        did_close(this)

      true ->
        nil
    end
  end

  # upstream: BrowserContextImpl.java:898
  def did_close(this) do
    put(this, :closing_or_closed, true)
    browser = get(this, :browser)

    if browser != nil do
      update(browser, :contexts, [], &List.delete(&1, this))
      selectors = get(get(get(browser, :browser_type), :playwright), :selectors)
      update(selectors, :contexts_for_selectors, [], &List.delete(&1, this))
    end

    ListenerCollection.notify(get(this, :listeners), :close, this)
  end
end
