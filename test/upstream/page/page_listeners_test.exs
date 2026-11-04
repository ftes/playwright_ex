defmodule PlaywrightEx.Page.PageListenersTest do
  @upstream "tests/page/page-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @moduletag :page

  # This test is mostly for type checking, the actual tests are in the library/events.

  @tag skip: "not ported: Page.removeAllListeners (behavior option)"
  test "should not throw with ignoreErrors"

  @tag skip: "not ported: Page.removeAllListeners (behavior option)"
  test "should wait"

  @tag skip: "not ported: Page.removeAllListeners (behavior option)"
  test "wait should throw"
end
