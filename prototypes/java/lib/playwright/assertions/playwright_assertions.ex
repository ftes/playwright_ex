defmodule Playwright.Assertions.PlaywrightAssertions do
  # upstream: assertions/PlaywrightAssertions.java:52  (static factory methods; overloads -> struct clauses)
  alias Playwright.Impl.{AssertionsTimeout, LocatorAssertionsImpl, LocatorImpl, PageAssertionsImpl, PageImpl}

  # upstream: assertions/PlaywrightAssertions.java:79
  def assert_that(%LocatorImpl{} = locator), do: LocatorAssertionsImpl.new(locator)

  # upstream: assertions/PlaywrightAssertions.java:94
  def assert_that(%PageImpl{} = page), do: PageAssertionsImpl.new(page)

  # upstream: assertions/PlaywrightAssertions.java:109
  def set_default_assertion_timeout(timeout), do: AssertionsTimeout.set_default_timeout(timeout)
end
