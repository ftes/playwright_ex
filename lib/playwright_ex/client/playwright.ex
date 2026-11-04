defmodule PlaywrightEx.Client.Playwright do
  @upstream "packages/playwright-core/src/client/playwright.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.BrowserType
  alias PlaywrightEx.Client.Connection

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    # this.request = new APIRequest(this);  -- not ported: fetch
    put(this, :chromium, BrowserType.from(initializer.chromium))
    put(get(this, :chromium), :_playwright, this)
    put(this, :firefox, BrowserType.from(initializer.firefox))
    put(get(this, :firefox), :_playwright, this)
    put(this, :webkit, BrowserType.from(initializer.webkit))
    put(get(this, :webkit), :_playwright, this)
    # Android.from / Electron.from  -- not ported: DummyChannelOwners
    put(this, :_android, initializer.android)
    put(get(this, :_android), :_playwright, this)
    put(this, :_electron, initializer.electron)
    put(get(this, :_electron), :_playwright, this)
    local_utils = Connection.local_utils(get(this, :_connection))
    put(this, :devices, (local_utils && get(local_utils, :devices)) || %{})
    # this.selectors = new Selectors();  -- not ported: selectors
    put(this, :errors, %{TimeoutError: PlaywrightEx.Client.Errors.TimeoutError})
    this
  end

  # readonly properties
  def chromium(this), do: get(this, :chromium)
  def firefox(this), do: get(this, :firefox)
  def webkit(this), do: get(this, :webkit)
  def devices(this), do: get(this, :devices)

  def from(channel) do
    channel
  end

  defp _browser_types(this) do
    [get(this, :chromium), get(this, :firefox), get(this, :webkit)]
  end

  def _pre_launched_browser(this) do
    browser = Browser.from(get(this, :_initializer).preLaunchedBrowser)
    Browser._connect_to_browser_type(browser, get(this, String.to_existing_atom(get(browser, :_name))), %{}, nil)
    browser
  end

  def _all_contexts(this) do
    Enum.flat_map(_browser_types(this), fn type -> get(type, :_contexts) || [] end)
  end

  def _all_pages(this) do
    # context.pages()  -- not ported: BrowserContext
    Enum.flat_map(_all_contexts(this), fn _context -> [] end)
  end
end
