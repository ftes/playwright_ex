defmodule PlaywrightEx.Client.Video do
  @upstream "packages/playwright-core/src/client/video.ts"
  @moduledoc """
  Port of `#{@upstream}`. No mutable state: a plain struct. Upstream extends `EventEmitter`
  without emitting any event, so it is not an emitter here.
  """
  alias PlaywrightEx.Client.Artifact
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Runtime.Heap

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.Video{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_artifact, _isRemote: false]

  def new(connection, artifact) do
    # super();  -- not ported: no events
    %PlaywrightEx.Video{_isRemote: Connection.is_remote(connection), _artifact: artifact}
  end

  def path(this) do
    if this._isRemote,
      do: raise("Path is not available when connecting remotely. Use saveAs() to save a local copy.")

    if !this._artifact, do: raise("Video recording has not been started.")
    Heap.get(this._artifact, :_initializer).absolutePath
  end

  def save_as(this, path) do
    if !this._artifact, do: raise("Video recording has not been started.")
    Artifact.save_as(this._artifact, path)
  end

  def delete(this) do
    if this._artifact, do: Artifact.delete(this._artifact)
    nil
  end
end
