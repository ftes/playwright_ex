defmodule PlaywrightEx.Page.PageLeaksTest do
  @upstream "tests/page/page-leaks.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  test "click should not leak"

  test "fill should not leak"

  test "expect should not leak"

  test "waitFor should not leak"
end
