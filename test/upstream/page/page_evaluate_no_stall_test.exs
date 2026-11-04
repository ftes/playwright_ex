defmodule PlaywrightEx.Page.PageEvaluateNoStallTest do
  @upstream "tests/page/page-evaluate-no-stall.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  @tag skip: "not ported: toImpl (in-process server internals: Frame.nonStallingRawEvaluateInExistingMainContext)"
  test "should work"

  @tag skip: "not ported: toImpl (in-process server internals: Frame.nonStallingRawEvaluateInExistingMainContext)"
  test "should throw while pending navigation"

  @tag skip: "not ported: toImpl (in-process server internals: Frame.nonStallingRawEvaluateInExistingMainContext)"
  test "should throw when no main execution context"
end
