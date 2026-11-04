defmodule Playwright.Core.Response do
  @moduledoc "upstream: Core/Response.cs (subset)"
  use Playwright.Transport.ChannelOwner, [:initializer]

  alias Playwright.Transport.ChannelOwner

  # upstream: Core/Response.cs:44
  def new(parent, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, guid, initializer: initializer)
    ChannelOwner.set(initializer.request, :timing, initializer.timing)
    ChannelOwner.set(initializer.request, :response, this)
    # skipped: _finishedTask = new(); _headers = new RawHeaders(...)
    this
  end

  # upstream: Core/Response.cs:58
  def ok(this), do: status(this) == 0 or (status(this) >= 200 and status(this) <= 299)

  # upstream: Core/Response.cs:60
  def request(this), do: this.initializer.request

  # upstream: Core/Response.cs:64
  def status(this), do: this.initializer.status

  # upstream: Core/Response.cs:66
  def url(this), do: this.initializer.url
end
