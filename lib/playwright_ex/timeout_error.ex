defmodule PlaywrightEx.TimeoutError do
  @moduledoc "JS `TimeoutError` (`packages/playwright-core/src/client/errors.ts`)."
  defexception message: "", name: "TimeoutError", log: [], details: nil, stack: "", code: nil, cause: nil
end
