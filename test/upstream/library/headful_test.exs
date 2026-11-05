defmodule PlaywrightEx.Library.HeadfulTest do
  @upstream "tests/library/headful.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # it.skip(({ headless }) => headless, ...), it.skip(channel === 'chromium-headless-shell')
  @moduletag skip: "upstream skip: headless (avoid popping windows in headless mode)"

  test "should have default url when launching browser @smoke"

  test "should close browser with beforeunload page"

  test "should close browsercontext with pending beforeunload dialog"

  test "should not crash when creating second context"

  test "should click when viewport size is larger than screen"

  test "should dispatch click events to oversized viewports"

  test "should click background tab"

  test "should close browser after context menu was triggered"

  test "should(not) block third party cookies"

  test "should not block third party SameSite=None cookies"

  test "should not override viewport size when passed null"

  test "Page.bringToFront should work"

  test "should click in OOPIF"

  test "should click bottom row w/ infobar in OOPIF"

  test "headless and headful should use same default fonts"

  test "should have the same hyphen rendering on headless and headed"
end
