defmodule PlaywrightEx.Library.BrowsertypeLaunchSeleniumTest do
  @upstream "tests/library/browsertype-launch-selenium.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # test.skip(({ mode }) => mode !== 'default', 'Using test hooks'); test.skip(!chromeDriver):
  # upstream runs these only with PWTEST_SELENIUM (Selenium server jars) and PWTEST_CHROMEDRIVER set.
  # They drive a Selenium grid child process (java) and connect via the in-process
  # `__testHookSeleniumRemoteURL` launch option, which the API does not expose.

  test "selenium grid 3.141.59 standalone chromium"

  test "selenium grid 3.141.59 hub + node chromium"

  test "selenium grid 4.8.3 standalone chromium"

  test "selenium grid 4.8.3 hub + node chromium"

  test "selenium grid 4.8.3 standalone chromium broken driver"

  test "selenium grid 3.141.59 standalone non-chromium"

  test "selenium grid 3.141.59 standalone chromium through run-driver"
end
