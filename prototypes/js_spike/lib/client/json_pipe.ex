# upstream: packages/playwright-core/src/client/jsonPipe.ts
defmodule PlaywrightJS.Client.JsonPipe do
  use PlaywrightJS.Client.ChannelOwner

  # upstream: jsonPipe.ts:22
  def from(json_pipe) do
    json_pipe
  end

  # upstream: jsonPipe.ts:26
  def new(parent, type, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
  end

  # upstream: jsonPipe.ts:30
  def channel(this) do
    _channel(this)
  end
end
