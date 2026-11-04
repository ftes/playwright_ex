defmodule PlaywrightEx.Client.Stream.ReadableStreamImpl do
  @upstream "packages/playwright-core/src/client/stream.ts"
  @moduledoc """
  Port of `#{@upstream}` (`class ReadableStreamImpl`), an `Enumerable` of binary chunks
  (Node's `Readable`): each chunk is a `read`, the end of the stream (or a halted
  enumeration) a `close`. Enumerating it outside the baton (test code) takes the baton per
  read, so any process can consume it (`Enum.into(stream, File.stream!(path))`).
  """
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.TimeoutSettings
  alias PlaywrightEx.Runtime.Promise

  defstruct [:_channel]

  def new(channel) do
    %__MODULE__{_channel: channel}
  end

  # Returns the chunk, or `nil` for `this.push(null)`.
  def _read(this) do
    result = ChannelOwner.channel_call(this._channel, :read, %{size: 1024 * 1024}, TimeoutSettings.k_no_timeout())

    if byte_size(result.binary) > 0,
      do: result.binary,
      else: nil
  end

  def _destroy(this, _error) do
    # Stream might be destroyed after the connection was closed.
    Promise.async(fn -> ChannelOwner.channel_call(this._channel, :close, %{}, TimeoutSettings.k_no_timeout()) end)
    |> Promise.catch_(fn _ -> nil end)

    nil
  end

  defimpl Enumerable do
    alias PlaywrightEx.Client.Stream.ReadableStreamImpl
    alias PlaywrightEx.Runtime.Api

    def reduce(this, acc, fun) do
      Elixir.Stream.resource(
        fn -> this end,
        fn this ->
          case Api.call(nil, this._channel, fn -> ReadableStreamImpl._read(this) end) do
            nil -> {:halt, this}
            chunk -> {[chunk], this}
          end
        end,
        fn this -> Api.call(nil, this._channel, fn -> ReadableStreamImpl._destroy(this, nil) end) end
      )
      |> Enumerable.reduce(acc, fun)
    end

    def count(_this), do: {:error, __MODULE__}
    def member?(_this, _value), do: {:error, __MODULE__}
    def slice(_this), do: {:error, __MODULE__}
  end
end

defmodule PlaywrightEx.Client.Stream do
  @upstream "packages/playwright-core/src/client/stream.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  `stream()` returns an `Enumerable` of binary chunks (Node's `Readable`, see
  `PlaywrightEx.Client.Stream.ReadableStreamImpl`), so `stream.pipe(fs.createWriteStream(path))`
  is `Enum.into(Stream.stream(stream), File.stream!(path))`.
  """
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Stream.ReadableStreamImpl

  def from(stream) do
    stream
  end

  def new(parent, type, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
  end

  def stream(this) do
    ReadableStreamImpl.new(this)
  end
end
