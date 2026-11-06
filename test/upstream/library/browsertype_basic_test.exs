defmodule PlaywrightEx.Library.BrowsertypeBasicTest do
  @upstream "tests/library/browsertype-basic.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.BrowserType

  test "browserType.executablePath should work", %{browser_type: browser_type} do
    executable_path = BrowserType.executable_path(browser_type)
    assert File.exists?(executable_path)
  end

  test "browserType.name should work", %{browser_type: browser_type, browser_name: browser_name} do
    assert BrowserType.name(browser_type) == browser_name
  end

  @tag skip: if(@browser_name in ["chromium", "webkit"], do: "upstream skip: chromium or webkit")
  test "should throw when trying to connect with not-chromium", %{
    browser_type: browser_type
  } do
    # deviation: `connectOverCDP({ endpointURL: 'ws://foo' })`, the options overload: the facade has
    # only the string form (api.json), so this calls that.
    {:error, error} = BrowserType.connect_over_cdp(browser_type, "ws://foo")
    assert Exception.message(error) == "Connecting over CDP is only supported in Chromium and WebKit."
  end
end
