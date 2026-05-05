defmodule PlaywrightEx.BrowserTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Browser

  describe "new_context/2" do
    test "consistent viewport size", %{browser: browser} do
      assert {:ok, _} =
               Browser.new_context(browser.guid,
                 viewport: %{width: 800, height: 600},
                 timeout: @timeout
               )
    end

    test "no default viewport", %{browser: browser} do
      assert {:ok, _} = Browser.new_context(browser.guid, viewport: nil, timeout: @timeout)
    end
  end
end
