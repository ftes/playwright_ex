defmodule PlaywrightEx.Library.BrowsertypeLaunchSeleniumTest do
  @upstream "tests/library/browsertype-launch-selenium.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  # test.skip(({ mode }) => mode !== 'default', 'Using test hooks'); test.skip(!chromeDriver):
  # upstream runs these only with PWTEST_SELENIUM (Selenium server jars) and PWTEST_CHROMEDRIVER set.
  # They drive a Selenium grid child process (java) and connect via the in-process
  # `__testHookSeleniumRemoteURL` launch option, which the API does not expose.

  @tag skip: "not ported: Selenium grid jars + chromedriver (PWTEST_SELENIUM) and __testHookSeleniumRemoteURL test hook"
  test "selenium grid 3.141.59 standalone chromium"

  @tag skip: "not ported: Selenium grid jars + chromedriver (PWTEST_SELENIUM) and __testHookSeleniumRemoteURL test hook"
  test "selenium grid 3.141.59 hub + node chromium"

  @tag skip: "not ported: Selenium grid jars + chromedriver (PWTEST_SELENIUM) and __testHookSeleniumRemoteURL test hook"
  test "selenium grid 4.8.3 standalone chromium"

  @tag skip: "not ported: Selenium grid jars + chromedriver (PWTEST_SELENIUM) and __testHookSeleniumRemoteURL test hook"
  test "selenium grid 4.8.3 hub + node chromium"

  @tag skip:
         "not ported: Selenium grid jars + broken-selenium-driver.js (PWTEST_SELENIUM) and __testHookSeleniumRemoteURL test hook"
  test "selenium grid 4.8.3 standalone chromium broken driver"

  @tag skip: "not ported: __testHookSeleniumRemoteURL test hook (upstream also gated on PWTEST_CHROMEDRIVER)"
  test "selenium grid 3.141.59 standalone non-chromium"

  @tag skip: "not ported: Selenium grid jars + chromedriver (PWTEST_SELENIUM) and in-process oop.start driver"
  test "selenium grid 3.141.59 standalone chromium through run-driver"
end
