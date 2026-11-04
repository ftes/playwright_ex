# upstream: packages/playwright-core/src/client/playwright.ts
defmodule PlaywrightJS.Client.Playwright do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.{BrowserType, Connection.DummyChannelOwner}

  # upstream: playwright.ts:45
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    # this.request = new APIRequest(this);  -- not ported
    put(this, :chromium, BrowserType.from(initializer.chromium))
    put(get(this, :chromium), :_playwright, this)
    put(this, :firefox, BrowserType.from(initializer.firefox))
    put(get(this, :firefox), :_playwright, this)
    put(this, :webkit, BrowserType.from(initializer.webkit))
    put(get(this, :webkit), :_playwright, this)
    put(this, :_android, DummyChannelOwner.from(initializer.android))
    put(get(this, :_android), :_playwright, this)
    put(this, :_electron, DummyChannelOwner.from(initializer.electron))
    put(get(this, :_electron), :_playwright, this)
    # this.devices = this._connection.localUtils()?.devices ?? {};  -- not ported
    # this.selectors = new Selectors();  -- not ported
    put(this, :errors, %{TimeoutError: PlaywrightJS.Client.Errors.TimeoutError})
    this
  end

  # readonly properties
  def chromium(this), do: get(this, :chromium)
  def firefox(this), do: get(this, :firefox)
  def webkit(this), do: get(this, :webkit)

  # upstream: playwright.ts:63
  def from(channel) do
    channel
  end

  # upstream: playwright.ts:67
  defp _browser_types(this) do
    [get(this, :chromium), get(this, :firefox), get(this, :webkit)]
  end

  # upstream: playwright.ts:77
  def _all_contexts(this) do
    Enum.flat_map(_browser_types(this), fn type -> get(type, :_contexts) || [] end)
  end

  # upstream: playwright.ts:81
  def _all_pages(this) do
    Enum.flat_map(_all_contexts(this), fn context -> PlaywrightJS.Client.BrowserContext.pages(context) end)
  end
end
