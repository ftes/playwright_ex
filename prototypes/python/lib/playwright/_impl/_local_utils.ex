# upstream: playwright/_impl/_local_utils.py (subset)
defmodule Playwright.Impl.LocalUtils do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.ChannelOwner

  # upstream: _local_utils.py:24
  def init(parent, type, guid, initializer) do
    self = ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)

    Py.set(
      self,
      :devices,
      Map.new(initializer["deviceDescriptors"], fn device ->
        {device["name"], device["descriptor"]}
      end)
    )

    self
  end
end
