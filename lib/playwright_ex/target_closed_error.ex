defmodule PlaywrightEx.TargetClosedError do
  @moduledoc "JS `TargetClosedError` (`packages/playwright-core/src/client/errors.ts`)."
  defexception message: "Target page, context or browser has been closed",
               name: "Error",
               log: [],
               details: nil,
               stack: "",
               code: nil,
               cause: nil

  def new(cause \\ nil), do: %__MODULE__{message: cause || "Target page, context or browser has been closed"}
end
