defmodule Playwright.TimeoutError do
  # upstream: TimeoutError.java:23 (extends PlaywrightException)
  defexception [:message, :cause]
end
