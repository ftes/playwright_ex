# upstream: playwright/_impl/_stream.py
defmodule Playwright.Impl.Stream do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.{Channel, ChannelOwner}

  # upstream: _stream.py:23
  def init(parent, type, guid, initializer),
    do: ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)

  # upstream: _stream.py:28
  def save_as(self, path) do
    file = File.open!(path, [:write, :binary])

    try do
      # while True: ... (loop -> recursion)
      write_chunks = fn write_chunks ->
        binary = Channel.send(self[:_channel], "read", nil, %{"size" => 1024 * 1024})

        if Py.bool(binary) do
          IO.binwrite(file, Base.decode64!(binary))
          write_chunks.(write_chunks)
        end
      end

      write_chunks.(write_chunks)
    after
      File.close(file)
    end
  end

  # upstream: _stream.py:41
  def read_all(self) do
    read = fn read, binary ->
      chunk = Channel.send(self[:_channel], "read", nil, %{"size" => 1024 * 1024})
      if !Py.bool(chunk), do: binary, else: read.(read, binary <> Base.decode64!(chunk))
    end

    read.(read, "")
  end
end
