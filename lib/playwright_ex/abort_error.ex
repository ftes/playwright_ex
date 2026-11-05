defmodule PlaywrightEx.AbortError do
  @moduledoc "JS `AbortError` (`packages/playwright-core/src/client/errors.ts`)."
  defexception message: "The operation was aborted",
               name: "AbortError",
               log: [],
               details: nil,
               stack: "",
               code: nil,
               cause: nil
end
