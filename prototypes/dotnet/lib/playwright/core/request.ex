defmodule Playwright.Core.Request do
  @moduledoc "upstream: Core/Request.cs (subset: what Frame.WaitForNavigation needs)"
  use Playwright.Transport.ChannelOwner, [:initializer, :redirected_from]

  alias Playwright.Transport.ChannelOwner
  import ChannelOwner, only: [get: 2, set: 3]

  # upstream: Core/Request.cs:47
  def new(parent, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, guid, initializer: initializer, redirected_from: initializer.redirected_from)
    # skipped: Timing = new();

    if this.redirected_from != nil do
      set(initializer.redirected_from, :redirected_to, this)
    end

    # skipped: _provisionalHeaders = new RawHeaders(...)
    this
  end

  # upstream: Core/Request.cs:135
  def redirected_from(this), do: this.redirected_from

  # upstream: Core/Request.cs:137
  def redirected_to(this), do: get(this, :redirected_to)

  # upstream: Core/Request.cs:143 (fallback overrides not ported)
  def url(this), do: this.initializer.url

  # upstream: Core/Request.cs:145
  def final_request(this), do: if(redirected_to(this) != nil, do: final_request(redirected_to(this)), else: this)

  # upstream: Core/Request.cs:152
  def response_async(this), do: ChannelOwner.send_message_to_server(this, "response", nil, as: Playwright.Core.Response)
end
