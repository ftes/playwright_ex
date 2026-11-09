defmodule PlaywrightEx.PlaywrightError do
  @moduledoc """
  A Playwright error other than a timeout, closed target or abort.

  Port of JS `Error` thrown by Playwright (`packages/playwright-core/src/client/errors.ts`).
  `PlaywrightEx.TimeoutError`, `PlaywrightEx.TargetClosedError` and `PlaywrightEx.AbortError` have
  the same fields. They keep their JS names:

    * `message` - JS's message: the API name, the error, then the call log
      (`"locator.click: Timeout 100ms exceeded.\nCall log:\n..."`).
    * `name` - the JS error name: `"Error"` unless the driver sends another.
    * `log` - the call log, a list of lines.
    * `details` - the error details the protocol declares for the call (a map), else `nil`.
    * `stack` - the driver's JS stack trace (`""` for errors of the client).
    * `code` - a system error code (`"ECONNREFUSED"`), else `nil`.
    * `cause` - the error behind this one, else `nil`: the `File.Error` of a storage-state file
      that can't be read, the reason given to `PlaywrightEx.AbortController.abort/2`.
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

  defexception message: "", name: "Error", log: [], details: nil, stack: "", code: nil, cause: nil
end
