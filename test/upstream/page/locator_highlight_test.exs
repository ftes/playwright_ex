defmodule PlaywrightEx.Page.LocatorHighlightTest do
  @upstream "tests/page/locator-highlight.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  # it.skip(({ mode }) => mode !== 'default', ...)  -- always default mode

  test "should highlight locator", %{page: page} do
    Page.set_content!(page, "<input type='text' />")
    Locator.highlight!(Page.locator(page, "input"))
    Expect.to_have_text!(Page.locator(page, "x-pw-tooltip"), "locator('input')")
    Expect.to_be_visible!(Page.locator(page, "x-pw-highlight"))
    box1 = Utils.round_box(Locator.bounding_box!(Page.locator(page, "input")))
    box2 = Utils.round_box(Locator.bounding_box!(Page.locator(page, "x-pw-highlight")))
    assert box1 == box2
  end
end
