defmodule PlaywrightEx.Client.JsonPipe do
  @upstream "packages/playwright-core/src/client/jsonPipe.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  def from(json_pipe) do
    json_pipe
  end

  def new(parent, type, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
  end

  def channel(this) do
    _channel(this)
  end
end
