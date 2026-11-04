# upstream: playwright/_impl/_artifact.py
defmodule Playwright.Impl.Artifact do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.{Channel, ChannelOwner}
  alias Playwright.Impl.Errors.Error
  alias Playwright.Impl.{Helper, Stream}
  import Playwright.Impl.Connection, only: [from_channel: 1]

  # upstream: _artifact.py:25
  def init(parent, type, guid, initializer) do
    self = ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)
    Py.set(self, :absolute_path, initializer["absolutePath"])
    self
  end

  # upstream: _artifact.py:31
  def path_after_finished(self) do
    if self[:_connection][:is_remote],
      do:
        raise(
          Error.new(
            "Path is not available when using browser_type.connect(). Use save_as() to save a local copy."
          )
        )

    path = Channel.send(self[:_channel], "pathAfterFinished", nil)
    path
  end

  # upstream: _artifact.py:42
  def save_as(self, path) do
    stream = from_channel(Channel.send(self[:_channel], "saveAsStream", nil))
    Helper.make_dirs_for_file(path)
    Stream.save_as(stream, path)
  end

  # upstream: _artifact.py:55
  def failure(self) do
    reason = Channel.send(self[:_channel], "failure", nil)
    if reason == nil, do: nil, else: Helper.patch_error_message(reason)
  end

  # upstream: _artifact.py:64
  def delete(self), do: Channel.send(self[:_channel], "delete", nil)

  # upstream: _artifact.py:70
  def read_info_buffer(self) do
    stream = from_channel(Channel.send(self[:_channel], "stream", nil))
    buffer = Stream.read_all(stream)
    buffer
  end

  # upstream: _artifact.py:83
  def cancel(self), do: Channel.send(self[:_channel], "cancel", nil)
end
