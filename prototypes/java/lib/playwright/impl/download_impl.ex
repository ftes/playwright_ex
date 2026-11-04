defmodule Playwright.Impl.DownloadImpl do
  # upstream: DownloadImpl.java:26  (not a ChannelOwner: an immutable value)
  alias Playwright.Impl.ArtifactImpl

  defstruct [:page, :artifact, :initializer]
  @type t :: %__MODULE__{}

  # upstream: DownloadImpl.java:31
  def new(page, artifact, initializer), do: %__MODULE__{page: page, artifact: artifact, initializer: initializer}

  # upstream: DownloadImpl.java:38
  def url(this), do: this.initializer["url"]

  # upstream: DownloadImpl.java:43
  def suggested_filename(this), do: this.initializer["suggestedFilename"]

  # upstream: DownloadImpl.java:48
  def cancel(this), do: ArtifactImpl.cancel(this.artifact)

  # upstream: DownloadImpl.java:58
  def delete(this), do: ArtifactImpl.delete(this.artifact)

  # upstream: DownloadImpl.java:63
  def failure(this), do: ArtifactImpl.failure(this.artifact)

  # upstream: DownloadImpl.java:68
  def page(this), do: this.page

  # upstream: DownloadImpl.java:73
  def path(this), do: ArtifactImpl.path_after_finished(this.artifact)

  # upstream: DownloadImpl.java:78
  def save_as(this, path), do: ArtifactImpl.save_as(this.artifact, path)
end
