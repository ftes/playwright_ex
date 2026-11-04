defmodule Playwright.Core.DriverMessages do
  @moduledoc "upstream: Core/DriverMessages.cs"

  # upstream: Core/DriverMessages.cs:34
  def target_closed_exception_message, do: "Target page, context or browser has been closed"

  # upstream: Core/DriverMessages.cs:36
  def is_target_closed_error(e), do: is_struct(e, Playwright.TargetClosedException)
end
