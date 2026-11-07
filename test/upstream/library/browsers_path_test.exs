defmodule PlaywrightEx.Library.BrowsersPathTest do
  @upstream "tests/library/browsers-path.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  test "BP-001 should import on an unsupported platform when PLAYWRIGHT_BROWSERS_PATH=0"

  test "BP-002 should import on an unsupported platform with an explicit PLAYWRIGHT_BROWSERS_PATH"
end
