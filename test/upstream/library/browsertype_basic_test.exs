defmodule PlaywrightEx.Library.BrowsertypeBasicTest do
  @upstream "tests/library/browsertype-basic.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserType

  test "browserType.executablePath should work", %{browser_type: browser_type} do
    executable_path = BrowserType.executable_path(browser_type)
    assert File.exists?(executable_path)
  end

  test "browserType.name should work", %{browser_type: browser_type, browser_name: browser_name} do
    assert BrowserType.name(browser_type) == browser_name
  end

  test "should throw when trying to connect with not-chromium", %{
    browser_type: browser_type,
    browser_name: browser_name
  } do
    if browser_name not in ["chromium", "webkit"] do
      {:error, error} = BrowserType.connect_over_cdp(browser_type, "ws://foo")
      assert Exception.message(error) == "Connecting over CDP is only supported in Chromium and WebKit."
    end
  end
end
