defmodule PlaywrightEx.PlaywrightError do
  @moduledoc """
  JS `Error` thrown by Playwright (`packages/playwright-core/src/client/errors.ts`); `name` is
  `"Error"` unless the server says otherwise.
  """
  defexception message: "", name: "Error", log: [], details: nil, stack: "", code: nil, cause: nil
end
