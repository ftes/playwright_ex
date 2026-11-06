defmodule PlaywrightEx.Client.FileChooser do
  @upstream "packages/playwright-core/src/client/fileChooser.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct."

  alias PlaywrightEx.Client.ElementHandle

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.FileChooser{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_page, :_elementHandle, :_isMultiple]

  def new(page, element_handle, is_multiple) do
    %PlaywrightEx.FileChooser{_page: page, _elementHandle: element_handle, _isMultiple: is_multiple}
  end

  def element(this) do
    this._elementHandle
  end

  def is_multiple(this) do
    this._isMultiple
  end

  def page(this) do
    this._page
  end

  def set_files(this, files, options \\ nil) do
    ElementHandle.set_input_files(this._elementHandle, files, options || %{})
  end
end
