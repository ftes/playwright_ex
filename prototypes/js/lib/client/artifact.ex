# upstream: packages/playwright-core/src/client/artifact.ts
defmodule PlaywrightJS.Client.Artifact do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.Connection

  def new(parent, type, guid, initializer), do: ChannelOwner.new(__MODULE__, parent, type, guid, initializer)

  # upstream: artifact.ts:28
  def from(channel) do
    channel
  end

  # upstream: artifact.ts:32
  def path_after_finished(this) do
    if Connection.is_remote(get(this, :_connection)),
      do: raise("Path is not available when connecting remotely. Use saveAs() to save a local copy.")

    channel_call(this, :pathAfterFinished, %{}, TimeoutSettings.k_no_timeout()).value
  end

  # upstream: artifact.ts:38
  def save_as(this, path) do
    if !Connection.is_remote(get(this, :_connection)) do
      channel_call(this, :saveAs, %{path: path}, TimeoutSettings.k_no_timeout())
      nil
    else
      raise "saveAs over a remote connection: not ported (saveAsStream + Stream)"
    end
  end

  # upstream: artifact.ts:54
  def failure(this) do
    channel_call(this, :failure, %{}, TimeoutSettings.k_no_timeout())[:error] || nil
  end

  # upstream: artifact.ts:78
  def cancel(this) do
    channel_call(this, :cancel, %{}, TimeoutSettings.k_no_timeout())
  end

  # upstream: artifact.ts:82
  def delete(this) do
    channel_call(this, :delete, %{}, TimeoutSettings.k_no_timeout())
  end
end
