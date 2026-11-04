# upstream: playwright/_impl/_browser.py (subset)
defmodule Playwright.Impl.Browser do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.{Channel, ChannelOwner}
  alias Playwright.Impl.{BrowserContext, BrowserType, Connection, Errors}
  import Playwright.Impl.Connection, only: [from_channel: 1]
  import Playwright.Impl.Helper, only: [locals_to_params: 1]

  # upstream: _browser.py:66
  def init(parent, type, guid, initializer) do
    self = ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)
    Py.set(self, :_browser_type, nil)
    Py.set(self, :_is_connected, true)
    Py.set(self, :_should_close_connection_on_close, false)
    Py.set(self, :_cr_tracing_path, nil)
    Py.set(self, :_contexts, MapSet.new())
    Py.set(self, :_traces_dir, nil)

    Channel.on(self[:_channel], "context", fn params ->
      _did_create_context(self, from_channel(params["context"]))
    end)

    Channel.on(self[:_channel], "close", fn _ -> _on_close(self) end)
    Py.set(self, :_close_reason, nil)
    self
  end

  # upstream: _browser.py:89
  def _connect_to_browser_type(self, browser_type, traces_dir \\ nil) do
    # Note: when using connect(), `browserType` is different from `this.parent`.
    # This is why browser type is not wired up in the constructor, and instead this separate method is called later on.
    Py.set(self, :_browser_type, browser_type)
    Py.set(self, :_traces_dir, traces_dir)
    for context <- self[:_contexts], do: _setup_browser_context(self, context)
  end

  # upstream: _browser.py:101
  def _did_create_context(self, context) do
    Py.set(context, :_browser, self)
    Py.set(self, :_contexts, MapSet.put(self[:_contexts], context))
    # Note: when connecting to a browser, initial contexts arrive before `_browserType` is set,
    # and will be configured later in `ConnectToBrowserType`.
    if self[:_browser_type], do: _setup_browser_context(self, context)
    emit(self, "context", context)
  end

  # upstream: _browser.py:110
  def _setup_browser_context(self, context) do
    # context._tracing._traces_dir / context._request._tracing._traces_dir (omitted)
    true = self[:_browser_type] != nil
    selectors = self[:_browser_type][:_playwright][:selectors]

    Py.set(
      selectors,
      :_contexts_for_selectors,
      MapSet.put(selectors[:_contexts_for_selectors], context)
    )
  end

  # upstream: _browser.py:116
  def _on_close(self) do
    Py.set(self, :_is_connected, false)
    emit(self, "disconnected", self)
  end

  # upstream: _browser.py:121
  def contexts(self), do: MapSet.to_list(self[:_contexts])

  # upstream: _browser.py:125
  def browser_type(self) do
    true = self[:_browser_type] != nil
    self[:_browser_type]
  end

  # upstream: _browser.py:129
  def is_connected(self), do: self[:_is_connected]

  # upstream: _browser.py:132
  def new_context(self, opts \\ []) do
    params = locals_to_params(binding())
    true = self[:_browser_type] != nil
    params = BrowserType._prepare_browser_context_params(self[:_browser_type], params)
    channel = Channel.send(self[:_channel], "newContext", nil, params)
    context = from_channel(channel)
    # await context._initialize_har_from_options(...)  (omitted)
    context
  end

  # upstream: _browser.py:187
  def new_page(self, opts \\ []) do
    params = locals_to_params(binding())

    inner = fn ->
      context = new_context(self, params)
      page = BrowserContext.new_page(context)
      Py.set(page, :_owned_context, context)
      Py.set(context, :_owner_page, page)
      page
    end

    Connection.wrap_api_call(self[:_connection], inner, false, "Create page")
  end

  # upstream: _browser.py:238
  def close(self, opts \\ []) do
    Py.set(self, :_close_reason, opts[:reason])

    try do
      if self[:_should_close_connection_on_close] do
        Connection.stop_async(self[:_connection])
      else
        Channel.send(self[:_channel], "close", nil, %{"reason" => opts[:reason]})
      end
    rescue
      e -> if not Errors.is_target_closed_error(e), do: reraise(e, __STACKTRACE__)
    end
  end

  # upstream: _browser.py:250
  def version(self), do: self[:_initializer]["version"]
end
