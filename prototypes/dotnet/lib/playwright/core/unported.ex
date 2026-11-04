defmodule Playwright.Core.Unported do
  @moduledoc "Inert ChannelOwner for protocol types this prototype does not port (APIRequestContext, LocalUtils, Tracing, ...)."
  use Playwright.Transport.ChannelOwner, [:type]

  def new(parent, guid, type), do: Playwright.Transport.ChannelOwner.new(__MODULE__, parent, guid, type: type)
end
