# upstream: packages/playwright-core/src/client/download.ts
# Download is never mutated after construction -> plain immutable struct (no heap).
defmodule PlaywrightJS.Client.Download do
  use PlaywrightJS.Client.Api
  alias PlaywrightJS.Client.Artifact

  defstruct [:_page, :_url, :_suggestedFilename, :_artifact]

  # upstream: download.ts:28
  def new(page, url, suggested_filename, artifact) do
    %__MODULE__{_page: page, _url: url, _suggestedFilename: suggested_filename, _artifact: artifact}
  end

  # upstream: download.ts:35
  def page(this) do
    this._page
  end

  # upstream: download.ts:39
  def url(this) do
    this._url
  end

  # upstream: download.ts:43
  def suggested_filename(this) do
    this._suggestedFilename
  end

  # upstream: download.ts:47
  def path(this) do
    Artifact.path_after_finished(this._artifact)
  end

  # upstream: download.ts:51
  def save_as(this, path) do
    Artifact.save_as(this._artifact, path)
  end

  # upstream: download.ts:55
  def failure(this) do
    Artifact.failure(this._artifact)
  end

  # upstream: download.ts:63
  def cancel(this) do
    Artifact.cancel(this._artifact)
  end

  # upstream: download.ts:67
  def delete(this) do
    Artifact.delete(this._artifact)
  end
end
