defmodule PlaywrightEx.Page.LocatorListTest do
  @upstream "tests/page/locator-list.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "locator.all should work", %{page: page} do
    Page.set_content!(page, "<div><p>A</p><p>B</p><p>C</p></div>")
    texts = for p <- Locator.all!(Page.locator(page, "div >> p")), do: Locator.text_content!(p)
    assert texts == ["A", "B", "C"]
  end
end
