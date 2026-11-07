defmodule PlaywrightEx.Page.PageEvaluateNoStallTest do
  @upstream "tests/page/page-evaluate-no-stall.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  test "EV-135 should work"

  test "EV-136 should throw while pending navigation"

  test "EV-137 should throw when no main execution context"
end
