defmodule PlaywrightEx.TimeoutError do
  @moduledoc "JS `TimeoutError` (`packages/playwright-core/src/client/errors.ts`)."
  @type t :: %__MODULE__{
          message: String.t(),
          name: String.t(),
          log: [String.t()],
          details: map() | nil,
          stack: String.t(),
          code: String.t() | nil,
          cause: term()
        }

  defexception message: "", name: "TimeoutError", log: [], details: nil, stack: "", code: nil, cause: nil
end
