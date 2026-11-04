defmodule PlaywrightEx.Page.PageLeaksTest do
  @upstream "tests/page/page-leaks.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  @tag skip: "not ported: toImpl (server internals: leakedJSHandles, requestGC, utility world)"
  test "click should not leak"

  @tag skip: "not ported: toImpl (server internals: leakedJSHandles, requestGC, utility world)"
  test "fill should not leak"

  @tag skip: "not ported: toImpl (server internals: leakedJSHandles, requestGC, utility world)"
  test "expect should not leak"

  @tag skip: "not ported: toImpl (server internals: leakedJSHandles, requestGC, utility world)"
  test "waitFor should not leak"
end
