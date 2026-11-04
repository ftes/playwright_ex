defmodule Playwright.Core.PlaywrightImpl do
  @moduledoc "upstream: Core/PlaywrightImpl.cs"
  use Playwright.Transport.ChannelOwner, [:initializer, :selectors]

  alias Playwright.Core.Selectors
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Connection

  # upstream: Core/PlaywrightImpl.cs:41
  def new(parent, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, guid, initializer: initializer, selectors: Selectors.new())

    # skipped: _devices = _connection.LocalUtils?._devices ?? new();

    ChannelOwner.set(initializer.chromium, :playwright, this)
    ChannelOwner.set(initializer.firefox, :playwright, this)
    ChannelOwner.set(initializer.webkit, :playwright, this)
    # skipped: APIRequest = new APIRequest(this);
    this
  end

  # upstream: Core/PlaywrightImpl.cs:58
  def chromium(this), do: this.initializer.chromium

  # upstream: Core/PlaywrightImpl.cs:60
  def firefox(this), do: this.initializer.firefox

  # upstream: Core/PlaywrightImpl.cs:62
  def webkit(this), do: this.initializer.webkit

  # upstream: Core/PlaywrightImpl.cs:64
  def selectors(this), do: this.selectors

  # upstream: Core/PlaywrightImpl.cs:79 (C# indexer this[string])
  def get(this, browser_type) do
    case browser_type && String.downcase(browser_type) do
      "chromium" -> chromium(this)
      "firefox" -> firefox(this)
      "webkit" -> webkit(this)
      _ -> raise ArgumentError, "Unknown browser type: #{browser_type}"
    end
  end

  # upstream: Core/PlaywrightImpl.cs:88
  def dispose(this), do: Connection.dispose(this.connection)
end
