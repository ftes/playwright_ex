defmodule PlaywrightEx.Page.PageRequestGcTest do
  @upstream "tests/page/page-request-gc.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  @tag skip: "not ported: Page.requestGC"
  test "should work"

  @tag skip: "not ported: Page.requestGC"
  test "should collect element retained by locator hit-target interceptor after detach"
end
