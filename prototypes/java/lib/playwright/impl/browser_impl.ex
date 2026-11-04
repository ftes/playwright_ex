defmodule Playwright.Impl.BrowserImpl do
  # upstream: BrowserImpl.java:35
  use Playwright.Impl.ChannelOwner
  alias Playwright.Browser.{CloseOptions, NewContextOptions}
  alias Playwright.Impl.{ListenerCollection, Serialization, Utils}

  # upstream: BrowserImpl.java:50
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.init(__MODULE__, parent, type, guid, initializer)
    put(this, :contexts, [])
    put(this, :listeners, ListenerCollection.new())
    put(this, :is_connected, true)
    this
  end

  # upstream: BrowserImpl.java:55
  def on_context(this, handler), do: ListenerCollection.add(get(this, :listeners), :context, handler)

  # upstream: BrowserImpl.java:60
  def off_context(this, handler), do: ListenerCollection.remove(get(this, :listeners), :context, handler)

  # upstream: BrowserImpl.java:65
  def on_disconnected(this, handler), do: ListenerCollection.add(get(this, :listeners), :disconnected, handler)

  # upstream: BrowserImpl.java:70
  def off_disconnected(this, handler), do: ListenerCollection.remove(get(this, :listeners), :disconnected, handler)

  # upstream: BrowserImpl.java:75
  def browser_type(this), do: get(this, :browser_type)

  # upstream: BrowserImpl.java:80
  def close(this, options) do
    options = options || %CloseOptions{}
    put(this, :close_reason, options.reason)

    if get(this, :is_connected_over_web_socket) do
      Connection.close(this.connection)
    else
      try do
        send_message(this, "close")
      rescue
        e in @playwright_exception -> if !Utils.is_safe_close_error(e), do: reraise(e, __STACKTRACE__)
      end
    end
  end

  # upstream: BrowserImpl.java:114
  def contexts(this), do: get(this, :contexts)

  # upstream: BrowserImpl.java:119
  def is_connected(this), do: get(this, :is_connected)

  # upstream: BrowserImpl.java:124
  def new_context(this, options) do
    options = options || %NewContextOptions{}

    # harOptions / recordHar* / storageState / recordVideo / viewportSize / clientCertificates / httpCredentials:
    # not ported (upstream lines 132-186).
    params = Serialization.to_json_tree(options)
    params = Map.delete(params, "acceptDownloads")

    params =
      if options.accept_downloads != nil,
        do: Map.put(params, "acceptDownloads", if(options.accept_downloads, do: "accept", else: "deny")),
        else: params

    selectors = get(get(browser_type(this), :playwright), :selectors)
    params = Map.put(params, "selectorEngines", Serialization.to_json_tree(get(selectors, :selector_engines)))
    params = Map.put(params, "testIdAttributeName", selectors.test_id_attribute_name)
    result = send_message(this, "newContext", params, @no_timeout)
    context = Connection.get_existing_object(this.connection, result["context"]["guid"])
    # context.initializeHarFromOptions(harOptions): not ported
    context
  end

  # upstream: BrowserImpl.java:270
  defp name(this), do: this.initializer["name"]

  # upstream: BrowserImpl.java:274
  def is_chromium(this), do: "chromium" == name(this)

  # upstream: BrowserImpl.java:279
  def version(this), do: this.initializer["version"]

  # upstream: BrowserImpl.java:284
  @impl true
  def handle_event(this, event, parameters) do
    case event do
      "context" ->
        did_create_context(this, Connection.get_existing_object(this.connection, parameters["context"]["guid"]))

      "close" ->
        did_close(this)

      _ ->
        nil
    end
  end

  # upstream: BrowserImpl.java:314
  defp did_create_context(this, context) do
    put(context, :browser, this)
    update(this, :contexts, [], &(&1 ++ [context]))
    # Note: when connecting to a browser, initial contexts arrive before `_browserType` is set,
    # and will be configured later in `ConnectToBrowserType`.
    if get(this, :browser_type) != nil do
      # context.setTracesDir(tracePath): not ported
      selectors = get(get(get(this, :browser_type), :playwright), :selectors)
      update(selectors, :contexts_for_selectors, [], &(&1 ++ [context]))
    end

    ListenerCollection.notify(get(this, :listeners), :context, context)
  end

  # upstream: BrowserImpl.java:326
  defp did_close(this) do
    put(this, :is_connected, false)
    ListenerCollection.notify(get(this, :listeners), :disconnected, this)
  end
end
