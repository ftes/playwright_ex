defmodule Playwright.Impl.AssertionsTimeout do
  # upstream: AssertionsTimeout.java:21
  # Java static mutable field -> :persistent_term (global, like a static).
  alias Playwright.PlaywrightException

  def default_timeout, do: :persistent_term.get({__MODULE__, :default_timeout}, 5_000)

  # upstream: AssertionsTimeout.java:24
  def set_default_timeout(ms) do
    if ms < 0, do: raise(PlaywrightException, message: "Timeout cannot be negative")
    :persistent_term.put({__MODULE__, :default_timeout}, ms)
  end
end
