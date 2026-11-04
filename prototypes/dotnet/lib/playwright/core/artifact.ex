defmodule Playwright.Core.Artifact do
  @moduledoc "upstream: Core/Artifact.cs"
  use Playwright.Transport.ChannelOwner, [:absolute_path]

  alias Playwright.PlaywrightException
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Connection

  # upstream: Core/Artifact.cs:38
  def new(parent, guid, initializer) do
    ChannelOwner.new(__MODULE__, parent, guid, absolute_path: initializer.absolute_path)
  end

  # upstream: Core/Artifact.cs:43
  def absolute_path(this), do: this.absolute_path

  # upstream: Core/Artifact.cs:46
  def path_after_finished_async(this) do
    if Connection.is_remote(this.connection) do
      raise PlaywrightException.new("Path is not available when connecting remotely. Use SaveAsAsync() to save a local copy.")
    end
    ChannelOwner.send_message_to_server(this, "pathAfterFinished")["value"]
  end

  # upstream: Core/Artifact.cs:57
  def save_as_async(this, path) do
    if !Connection.is_remote(this.connection) do
      ChannelOwner.send_message_to_server(
      this,
      "saveAs",
      %{
        "path" => path,
      })
      :ok
    else
      # skipped: saveAsStream + Stream copy for remote connections
      raise PlaywrightException.new("Remote SaveAs is not ported")
    end
  end

  # upstream: Core/Artifact.cs:89
  def cancel_async(this), do: ChannelOwner.send_message_to_server(this, "cancel")

  # upstream: Core/Artifact.cs:91
  def failure_async(this), do: ChannelOwner.send_message_to_server(this, "failure")["error"]

  # upstream: Core/Artifact.cs:94
  def delete_async(this), do: ChannelOwner.send_message_to_server(this, "delete")
end
