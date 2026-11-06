defmodule PlaywrightEx.TargetClosedError do
  @moduledoc """
  JS `TargetClosedError` (`packages/playwright-core/src/client/errors.ts`): the page, context or
  browser of a call has been closed, or the driver has exited. The fields are those of
  `PlaywrightEx.PlaywrightError`; `name` is `"Error"`, as in JS.
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

  defexception message: "Target page, context or browser has been closed",
               name: "Error",
               log: [],
               details: nil,
               stack: "",
               code: nil,
               cause: nil

  @doc false
  # `new TargetClosedError(cause)`, for the client.
  def new(cause \\ nil), do: %__MODULE__{message: cause || "Target page, context or browser has been closed"}
end
