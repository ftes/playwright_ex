# upstream: packages/playwright-core/src/client/writableStream.ts
defmodule PlaywrightJS.Client.WritableStream do
  use PlaywrightJS.Client.ChannelOwner

  # upstream: writableStream.ts:24
  def from(stream) do
    stream
  end

  # upstream: writableStream.ts:28
  def new(parent, type, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
  end

  # upstream: writableStream.ts:32 (stream(): Writable) -- Node Writable becomes pipe-from-enumerable
  def stream(this, chunks) do
    Enum.each(chunks, fn chunk -> _write(this, chunk) end)
    _final(this)
  end

  # upstream: writableStream.ts:45
  defp _write(this, chunk) do
    channel_call(this, :write, %{binary: Base.encode64(chunk)}, TimeoutSettings.k_no_timeout())
  end

  # upstream: writableStream.ts:50
  defp _final(this) do
    # Stream might be destroyed after the connection was closed.
    channel_call(this, :close, %{}, TimeoutSettings.k_no_timeout())
    nil
  end
end
