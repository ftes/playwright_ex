# upstream: packages/playwright-core/src/client/stream.ts
defmodule PlaywrightJS.Client.Stream do
  use PlaywrightJS.Client.ChannelOwner

  # upstream: stream.ts:24
  def from(stream) do
    stream
  end

  # upstream: stream.ts:28
  def new(parent, type, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
  end

  # upstream: stream.ts:32 (stream(): Readable) -- Node Readable becomes a pull loop into `sink`
  def stream(this, sink) do
    _read_all(this, sink)
  end

  # upstream: stream.ts:45 (ReadableStreamImpl._read, repeated until EOF, then _destroy)
  defp _read_all(this, sink) do
    result = channel_call(this, :read, %{size: 1024 * 1024}, TimeoutSettings.k_no_timeout())
    binary = Base.decode64!(result.binary)

    if byte_size(binary) > 0 do
      sink.(binary)
      _read_all(this, sink)
    else
      # Stream might be destroyed after the connection was closed.
      try do
        channel_call(this, :close, %{}, TimeoutSettings.k_no_timeout())
      rescue
        _ -> nil
      end

      nil
    end
  end
end
