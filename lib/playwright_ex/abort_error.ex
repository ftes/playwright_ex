defmodule PlaywrightEx.AbortError do
  @moduledoc """
  JS `AbortError` (`packages/playwright-core/src/client/errors.ts`): a call was cancelled through
  its `signal:` (`PlaywrightEx.AbortController`). The fields are those of
  `PlaywrightEx.PlaywrightError`; `name` is `"AbortError"` and `cause` the reason given to
  `PlaywrightEx.AbortController.abort/2`.
  """
  @typedoc "See the module docs for the fields."
  @type t :: %__MODULE__{
          message: String.t(),
          name: String.t(),
          log: [String.t()],
          details: map() | nil,
          stack: String.t(),
          code: String.t() | nil,
          cause: term()
        }

  defexception message: "The operation was aborted",
               name: "AbortError",
               log: [],
               details: nil,
               stack: "",
               code: nil,
               cause: nil
end
