defmodule Playwright.Impl.DriverException do
  # upstream: DriverException.java:24 (extends PlaywrightException)
  defexception [:message]
end
