defmodule PlaywrightEx.Client.WebError do
  @upstream "packages/playwright-core/src/client/webError.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct."

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.WebError{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_page, :_error, :_location]

  def new(page, error, location) do
    %PlaywrightEx.WebError{_page: page, _error: error, _location: location}
  end

  def page(this) do
    this._page
  end

  def error(this) do
    this._error
  end

  def location(this) do
    this._location
  end
end
