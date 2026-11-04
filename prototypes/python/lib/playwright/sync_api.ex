# upstream: playwright/sync_api/__init__.py (subset)
# The generated sync/async wrapper layer (_generated.py) is not reproduced: on the
# BEAM every call already blocks the calling process, so the impl modules are the
# public API. A generated layer would only map snake_case kwargs -> impl kwargs and
# carry docs/typespecs.
defmodule Playwright.SyncApi do
  alias Playwright.Impl.Assertions.{LocatorAssertions, PageAssertions}
  alias Playwright.Impl.{Locator, Page}
  alias Playwright.SyncApi.PlaywrightContextManager

  # upstream: sync_api/__init__.py:99
  def sync_playwright, do: PlaywrightContextManager.init()

  # upstream: sync_api/__init__.py:137 (Expect.__call__ -> _dispatch)
  def expect(actual, message \\ nil) do
    cond do
      is_struct(actual, Page) -> PageAssertions.init(actual, nil, false, message, false)
      is_struct(actual, Locator) -> LocatorAssertions.init(actual, nil, false, message, false)
      true -> raise ArgumentError, "Unsupported type: #{inspect(actual)}"
    end
  end
end
