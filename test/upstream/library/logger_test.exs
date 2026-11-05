defmodule PlaywrightEx.Library.LoggerTest do
  @upstream "tests/library/logger.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @tag skip: "not ported: Logger (browserType.launch `logger` option)"
  test "should log @smoke"

  @tag skip: "not ported: Logger (browser.newContext `logger` option)"
  test "should log context-level"
end
