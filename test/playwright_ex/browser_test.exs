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

    test "normalizes one HTTP credential to the Playwright 1.63 protocol array", %{browser: browser} do
      assert {:ok, _} =
               Browser.new_context(browser.guid,
                 http_credentials: %{username: "user", password: "password"},
                 timeout: @timeout
               )
    end

    test "accepts multiple origin-specific HTTP credentials", %{browser: browser} do
      assert {:ok, _} =
               Browser.new_context(browser.guid,
                 http_credentials: [
                   %{username: "one", password: "first", origin: "https://one.example"},
                   %{username: "two", password: "second", origin: "https://two.example", send: :always}
                 ],
                 timeout: @timeout
               )
    end

    test "normalizes Playwright 1.63 context enums, headers, and acronym casing", %{browser: browser} do
      assert {:ok, _} =
               Browser.new_context(browser.guid,
                 accept_downloads: false,
                 bypass_csp: true,
                 color_scheme: :no_preference,
                 extra_http_headers: %{"x-playwright-ex" => "1"},
                 timeout: @timeout
               )

      assert {:ok, _} =
               Browser.new_context(browser.guid,
                 color_scheme: :null,
                 timeout: @timeout
               )

      assert {:ok, _} =
               Browser.new_context(browser.guid,
                 color_scheme: :no_override,
                 timeout: @timeout
               )
    end
  end
end
