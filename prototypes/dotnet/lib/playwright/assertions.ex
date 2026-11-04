defmodule Playwright.Assertions do
  @moduledoc "upstream: Assertions.cs (static Expect overloads -> pattern match on the handle type)"
  alias Playwright.Core.AssertionsBase
  alias Playwright.Core.Locator
  alias Playwright.Core.LocatorAssertions
  alias Playwright.Core.Page
  alias Playwright.Core.PageAssertions

  # upstream: Assertions.cs:40
  def set_default_expect_timeout(timeout), do: AssertionsBase.set_default_timeout(timeout)

  # upstream: Assertions.cs:42 + :44 + :55 + :60
  def expect(subject, message \\ nil)
  def expect(%Locator{} = locator, message), do: LocatorAssertions.new(locator, false, message)
  def expect(%Page{} = page, message), do: PageAssertions.new(page, false, message)
end
