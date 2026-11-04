defmodule PlaywrightEx.Page.PageClickDuringNavigationTest do
  @upstream "tests/page/page-click-during-navigation.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  @tag skip: "not ported: __testHookAfterStable (in-process test hook)"
  test "should not fail with internal error upon navigation"
end
