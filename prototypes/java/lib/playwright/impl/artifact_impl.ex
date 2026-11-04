defmodule Playwright.Impl.ArtifactImpl do
  # upstream: ArtifactImpl.java:30
  use Playwright.Impl.ChannelOwner
  alias Playwright.PlaywrightException

  # upstream: ArtifactImpl.java:31
  def new(parent, type, guid, initializer), do: ChannelOwner.init(__MODULE__, parent, type, guid, initializer)

  # upstream: ArtifactImpl.java:55
  def cancel(this), do: send_message(this, "cancel")

  # upstream: ArtifactImpl.java:59
  def delete(this), do: send_message(this, "delete")

  # upstream: ArtifactImpl.java:63
  def failure(this) do
    result = send_message(this, "failure")
    if Map.has_key?(result, "error"), do: result["error"], else: nil
  end

  # upstream: ArtifactImpl.java:71
  def path_after_finished(this) do
    if this.connection.is_remote,
      do:
        raise(PlaywrightException,
          message: "Path is not available when using browserType.connect(). Use download.saveAs() to save a local copy."
        )

    json = send_message(this, "pathAfterFinished")
    json["value"]
  end

  # upstream: ArtifactImpl.java:79  (remote saveAsStream branch not ported)
  def save_as(this, path) do
    if this.connection.is_remote, do: raise(PlaywrightException, message: "not ported: remote saveAs")
    params = %{"path" => to_string(path)}
    send_message(this, "saveAs", params, @no_timeout)
  end
end
