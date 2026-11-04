defmodule Playwright.Core.Download do
  @moduledoc "upstream: Core/Download.cs (not a ChannelOwner -> plain struct)"
  alias Playwright.Core.Artifact

  defstruct [:page, :url, :suggested_filename, :artifact]

  # upstream: Core/Download.cs:38
  def new(page, url, suggested_filename, artifact) do
    %__MODULE__{
      page: page,
      url: url,
      suggested_filename: suggested_filename,
      artifact: artifact
    }
  end

  # upstream: Core/Download.cs:46
  def page(this), do: this.page

  # upstream: Core/Download.cs:48
  def url(this), do: this.url

  # upstream: Core/Download.cs:50
  def suggested_filename(this), do: this.suggested_filename

  # upstream: Core/Download.cs:52
  def path_async(this), do: Artifact.path_after_finished_async(this.artifact)

  # upstream: Core/Download.cs:54
  def failure_async(this), do: Artifact.failure_async(this.artifact)

  # upstream: Core/Download.cs:56
  def delete_async(this), do: Artifact.delete_async(this.artifact)

  # upstream: Core/Download.cs:58
  def save_as_async(this, path), do: Artifact.save_as_async(this.artifact, path)

  # upstream: Core/Download.cs:62
  def cancel_async(this), do: Artifact.cancel_async(this.artifact)
end
