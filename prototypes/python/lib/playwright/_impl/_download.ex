# upstream: playwright/_impl/_download.py
defmodule Playwright.Impl.Download do
  # class Download: immutable -> plain struct
  defstruct [:_page, :_loop, :_dispatcher_fiber, :_url, :_suggested_filename, :_artifact]
  alias Playwright.Impl.Artifact

  # upstream: _download.py:26
  def init(page, url, suggested_filename, artifact) do
    %__MODULE__{
      _page: page,
      _loop: page[:_loop],
      _dispatcher_fiber: page[:_dispatcher_fiber],
      _url: url,
      _suggested_filename: suggested_filename,
      _artifact: artifact
    }
  end

  # upstream: _download.py:40
  def page(self), do: self._page

  # upstream: _download.py:44
  def url(self), do: self._url

  # upstream: _download.py:48
  def suggested_filename(self), do: self._suggested_filename

  # upstream: _download.py:51
  def delete(self), do: Artifact.delete(self._artifact)

  # upstream: _download.py:54
  def failure(self), do: Artifact.failure(self._artifact)

  # upstream: _download.py:57
  def path(self), do: Artifact.path_after_finished(self._artifact)

  # upstream: _download.py:60
  def save_as(self, path), do: Artifact.save_as(self._artifact, path)

  # upstream: _download.py:63
  def cancel(self), do: Artifact.cancel(self._artifact)
end
