defmodule PlaywrightEx.Client.Artifact do
  @upstream "packages/playwright-core/src/client/artifact.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  `createReadStream()` returns the `Enumerable` of `PlaywrightEx.Client.Stream.stream/1`
  (Node's `Readable`).
  """
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.FileUtils
  alias PlaywrightEx.Client.Stream

  def from(artifact) do
    artifact
  end

  def new(parent, type, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
  end

  def path_after_finished(this) do
    if Connection.is_remote(get(this, :_connection)),
      do: raise("Path is not available when connecting remotely. Use saveAs() to save a local copy.")

    channel_call(this, :pathAfterFinished, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def save_as(this, path) do
    if !Connection.is_remote(get(this, :_connection)) do
      channel_call(this, :saveAs, %{path: path}, TimeoutSettings.k_no_timeout())
      nil
    else
      result = channel_call(this, :saveAsStream, %{}, TimeoutSettings.k_no_timeout())
      stream = Stream.from(result.stream)
      FileUtils.mkdir_if_needed(path)
      # stream.stream().pipe(fs.createWriteStream(path)).on('finish', resolve).on('error', reject)
      Enum.into(Stream.stream(stream), File.stream!(path))
      nil
    end
  end

  def failure(this) do
    channel_call(this, :failure, %{}, TimeoutSettings.k_no_timeout())[:error] || nil
  end

  def create_read_stream(this) do
    result = channel_call(this, :stream, %{}, TimeoutSettings.k_no_timeout())
    stream = Stream.from(result.stream)
    Stream.stream(stream)
  end

  def read_into_buffer(this) do
    stream = create_read_stream(this)
    # stream.on('data', ...); stream.on('end', () => resolve(Buffer.concat(chunks)))
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  def cancel(this) do
    channel_call(this, :cancel, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def delete(this) do
    channel_call(this, :delete, %{}, TimeoutSettings.k_no_timeout())
    nil
  end
end
