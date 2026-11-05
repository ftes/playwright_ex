defmodule PlaywrightEx.Isomorphic.CssParser do
  @upstream "packages/isomorphic/cssParser.ts"
  @moduledoc """
  Port of `#{@upstream}`: only `InvalidSelectorError`, which `selectorParser` throws. Parsing CSS
  (and `cssTokenizer.ts`) is the driver's job; the client only renders selectors.
  """

  defmodule InvalidSelectorError do
    @moduledoc false
    defexception [:message]
  end

  def is_invalid_selector_error(error) do
    is_struct(error, InvalidSelectorError)
  end

  # parseCSS, serializeSelector  -- not ported: CSS bodies of parsed selectors stay strings (selectorParser)
end
