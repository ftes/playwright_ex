defmodule PlaywrightEx.Client.WritableStream.WritableStreamImpl do
  @upstream "packages/playwright-core/src/client/writableStream.ts"
  @moduledoc """
  Port of `#{@upstream}` (`class WritableStreamImpl`), a `Collectable`: the errors that
  `callback(error)` passes to the pipeline are raised.
  """
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.TimeoutSettings

  defstruct [:_channel]

  def new(channel) do
    %__MODULE__{_channel: channel}
  end

  def _write(this, chunk) do
    ChannelOwner.channel_call(this._channel, :write, %{binary: chunk}, TimeoutSettings.k_no_timeout())
  end

  def _final(this) do
    # Stream might be destroyed after the connection was closed.
    ChannelOwner.channel_call(this._channel, :close, %{}, TimeoutSettings.k_no_timeout())
  end

  defimpl Collectable do
    alias PlaywrightEx.Client.WritableStream.WritableStreamImpl

    def into(this) do
      collector = fn
        acc, {:cont, chunk} ->
          WritableStreamImpl._write(this, chunk)
          acc

        acc, :done ->
          WritableStreamImpl._final(this)
          acc

        _acc, :halt ->
          :ok
      end

      {this, collector}
    end
  end
end

defmodule PlaywrightEx.Client.WritableStream do
  @upstream "packages/playwright-core/src/client/writableStream.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  `stream()` returns a `Collectable` (Node's `Writable`): each chunk collected into it is a
  `write`, the end of the collection a `close`, so `stream.pipeline(readable, writable.stream())`
  is `Enum.into(readable, WritableStream.stream(writable))`.
  """
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.WritableStream.WritableStreamImpl

  def from(stream) do
    stream
  end

  def new(parent, type, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
  end

  def stream(this) do
    WritableStreamImpl.new(this)
  end
end
