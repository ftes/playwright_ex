defmodule PlaywrightEx.Library.BrowsersPathTest do
  @upstream "tests/library/browsers-path.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @tag skip: "not ported: requires playwright-core in a Node process with a spoofed process.platform"
  test "should import on an unsupported platform when PLAYWRIGHT_BROWSERS_PATH=0"

  @tag skip: "not ported: requires playwright-core in a Node process with a spoofed process.platform"
  test "should import on an unsupported platform with an explicit PLAYWRIGHT_BROWSERS_PATH"
end
