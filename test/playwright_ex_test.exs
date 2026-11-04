defmodule PlaywrightExTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.BrowserType
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Playwright
  alias PlaywrightEx.Client.Waiter
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Baton

  @moduletag timeout: 120_000

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    %{playwright: PlaywrightEx.playwright(__MODULE__)}
  end

  # What the generated facade will do for every call.
  defp launch(chromium, options \\ %{}),
    do: Api.call("browserType.launch", chromium, fn -> BrowserType.launch(chromium, options) end)

  defp close(browser), do: Api.call("browser.close", browser, fn -> Browser.close(browser) end)

  test "root Playwright object", %{playwright: playwright} do
    assert BrowserType.name(Playwright.chromium(playwright)) == "chromium"
    assert BrowserType.name(Playwright.firefox(playwright)) == "firefox"
    assert BrowserType.name(Playwright.webkit(playwright)) == "webkit"
    assert %{"iPhone 15" => %{userAgent: _, viewport: %{width: _}}} = Playwright.devices(playwright)
  end

  test "launches and closes chromium", %{playwright: playwright} do
    browser = launch(Playwright.chromium(playwright))
    assert Browser.version(browser) =~ ~r/^\d+\.\d+/
    assert Browser.is_connected(browser)
    assert Browser.browser_type(browser) == Playwright.chromium(playwright)
    refute Baton.held?()

    assert close(browser) == nil
    refute Browser.is_connected(browser)
    # Closing twice is fine (TargetClosedError is swallowed, as upstream).
    assert close(browser) == nil
  end

  test "disconnected listeners run during close", %{playwright: playwright} do
    test = self()
    browser = launch(Playwright.chromium(playwright))
    Browser.on(browser, "disconnected", fn b -> send(test, {:disconnected, b, Baton.held?()}) end)
    close(browser)
    assert_received {:disconnected, ^browser, true}
  end

  test "protocol errors carry the API name and the call log", %{playwright: playwright} do
    error =
      assert_raise Errors.PlaywrightError, fn ->
        launch(Playwright.chromium(playwright), %{executablePath: "/nonexistent/chrome"})
      end

    assert error.message =~ ~r/^browserType\.launch: .*\/nonexistent\/chrome/
    assert is_list(error.log)
  end

  test "client-side validation errors", %{playwright: playwright} do
    chromium = Playwright.chromium(playwright)

    assert_raise PlaywrightEx.Protocol.ValidatorPrimitives.ValidationError,
                 "browserType.launch: args: expected array, got string",
                 fn ->
                   launch(chromium, %{args: "--no-sandbox"})
                 end
  end

  test "waiter: waits for an event, or times out", %{playwright: playwright} do
    browser = launch(Playwright.chromium(playwright))

    waiting =
      Task.async(fn ->
        Api.call("browser.waitForEvent", browser, fn ->
          waiter = Waiter.create_for_event(browser, "disconnected")
          Waiter.wait_for_event(waiter, browser, "disconnected")
        end)
      end)

    # Let the waiter subscribe before closing.
    Process.sleep(100)
    close(browser)
    assert Task.await(waiting) == browser

    error =
      assert_raise Errors.TimeoutError, fn ->
        Api.call("browser.waitForEvent", browser, fn ->
          waiter = Waiter.create_for_event(browser, "disconnected")

          Waiter.reject_on_timeout(
            waiter,
            %{timeout: 50},
            "Timeout 50ms exceeded while waiting for event \"disconnected\""
          )

          Waiter.wait_for_event(waiter, browser, "disconnected")
        end)
      end

    assert error.message =~ ~s(Timeout 50ms exceeded while waiting for event "disconnected")
  end
end
