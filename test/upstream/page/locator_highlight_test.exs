defmodule PlaywrightEx.Page.LocatorHighlightTest do
  @upstream "tests/page/locator-highlight.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  @tag skip: "not ported: expect"
  test "should highlight locator"
end
