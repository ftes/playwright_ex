defmodule PlaywrightEx.PlaywrightError do
  @moduledoc """
  JS `Error` thrown by Playwright (`packages/playwright-core/src/client/errors.ts`); `name` is
  `"Error"` unless the server says otherwise.
  """
  @type t :: %__MODULE__{
          message: String.t(),
          name: String.t(),
          log: [String.t()],
          details: map() | nil,
          stack: String.t(),
          code: String.t() | nil,
          cause: term()
        }

  defexception message: "", name: "Error", log: [], details: nil, stack: "", code: nil, cause: nil
end
