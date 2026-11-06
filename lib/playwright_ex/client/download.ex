defmodule PlaywrightEx.Client.Download do
  @upstream "packages/playwright-core/src/client/download.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct."

  alias PlaywrightEx.Client.Artifact

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.Download{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_page, :_url, :_suggestedFilename, :_artifact]

  def new(page, url, suggested_filename, artifact) do
    %PlaywrightEx.Download{_page: page, _url: url, _suggestedFilename: suggested_filename, _artifact: artifact}
  end

  def page(this) do
    this._page
  end

  def url(this) do
    this._url
  end

  def suggested_filename(this) do
    this._suggestedFilename
  end

  def path(this) do
    Artifact.path_after_finished(this._artifact)
  end

  def save_as(this, path) do
    Artifact.save_as(this._artifact, path)
  end

  def failure(this) do
    Artifact.failure(this._artifact)
  end

  def create_read_stream(this) do
    Artifact.create_read_stream(this._artifact)
  end

  def cancel(this) do
    Artifact.cancel(this._artifact)
  end

  def delete(this) do
    Artifact.delete(this._artifact)
  end
end
