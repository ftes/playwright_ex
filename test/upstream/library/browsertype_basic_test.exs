defmodule PlaywrightEx.Library.BrowsertypeBasicTest do
  @upstream "tests/library/browsertype-basic.spec.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.BrowserType

  test "browserType.executablePath should work", %{browser_type: browser_type} do
    executable_path = BrowserType.executable_path(browser_type)
    assert File.exists?(executable_path)
  end

  test "browserType.name should work", %{browser_type: browser_type, browser_name: browser_name} do
    assert BrowserType.name(browser_type) == browser_name
  end

  @tag skip: "not ported: connectOverCDP"
  test "should throw when trying to connect with not-chromium"
end
