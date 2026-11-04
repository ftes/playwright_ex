defmodule Playwright.PlaywrightException do
  # upstream: PlaywrightException.java:23
  # Java: `class PlaywrightException extends RuntimeException`. Elixir exceptions have no inheritance, so the
  # subclass hierarchy is spelled out as a list usable in `rescue e in @playwright_exception`.
  defexception [:message, :cause]

  defmacro __using__(_) do
    quote do
      @playwright_exception [
        Playwright.PlaywrightException,
        Playwright.TimeoutError,
        Playwright.Impl.TargetClosedError,
        Playwright.Impl.DriverException,
        Playwright.Impl.ServerErrorWithDetails
      ]
    end
  end
end
