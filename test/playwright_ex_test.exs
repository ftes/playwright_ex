defmodule PlaywrightExTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Waiter
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Baton

  @moduletag timeout: 120_000

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    %{playwright: PlaywrightEx.playwright(__MODULE__)}
  end

  test "root Playwright object", %{playwright: playwright} do
    assert BrowserType.name(Playwright.chromium(playwright)) == "chromium"
    assert BrowserType.name(Playwright.firefox(playwright)) == "firefox"
    assert BrowserType.name(Playwright.webkit(playwright)) == "webkit"
    assert %{"iPhone 15" => %{userAgent: _, viewport: %{width: _}}} = Playwright.devices(playwright)
  end

  test "launches and closes chromium", %{playwright: playwright} do
    assert {:ok, browser} = BrowserType.launch(Playwright.chromium(playwright))
    assert inspect(browser) =~ ~r/^#PlaywrightEx\.Browser<browser@\w+>$/
    assert Browser.version(browser) =~ ~r/^\d+\.\d+/
    assert Browser.is_connected(browser)
    assert Browser.browser_type(browser) == Playwright.chromium(playwright)
    refute Baton.held?()

    assert Browser.close(browser) == :ok
    refute Browser.is_connected(browser)
    # Closing twice is fine (TargetClosedError is swallowed, as upstream).
    assert Browser.close!(browser, reason: "done") == :ok
  end

  test "disconnected listeners run during close", %{playwright: playwright} do
    test = self()
    browser = BrowserType.launch!(Playwright.chromium(playwright))
    listener = fn b -> send(test, {:disconnected, b, Baton.held?()}) end
    assert Browser.on(browser, :disconnected, listener) == browser
    Browser.close!(browser)
    assert_received {:disconnected, ^browser, true}

    assert_raise ArgumentError, ~r/browser\.on: unknown event :closed, expected one of :context, :disconnected/, fn ->
      Browser.on(browser, :closed, listener)
    end
  end

  test "protocol errors carry the API name and the call log", %{playwright: playwright} do
    assert {:error, %Errors.PlaywrightError{} = error} =
             BrowserType.launch(Playwright.chromium(playwright), executable_path: "/nonexistent/chrome")

    assert error.message =~ ~r/^browserType\.launch: .*\/nonexistent\/chrome/
    assert is_list(error.log)

    assert_raise Errors.PlaywrightError, ~r/^browserType\.launch: /, fn ->
      BrowserType.launch!(Playwright.chromium(playwright), executable_path: "/nonexistent/chrome")
    end
  end

  test "client-side validation errors", %{playwright: playwright} do
    chromium = Playwright.chromium(playwright)

    assert_raise PlaywrightEx.Protocol.ValidatorPrimitives.ValidationError,
                 "browserType.launch: args: expected array, got string",
                 fn -> BrowserType.launch!(chromium, args: "--no-sandbox") end
  end

  test "options: snake_case keys, nested objects, JS names, unknown keys", %{playwright: playwright} do
    chromium = Playwright.chromium(playwright)
    browser = BrowserType.launch!(chromium, timeout: :infinity, proxy: [server: "per-context"], chromiumSandbox: false)
    Browser.close!(browser)

    assert_raise ArgumentError, ~r/browserType\.launch: unknown option :proxy\.servr, expected one of :bypass/, fn ->
      BrowserType.launch(chromium, proxy: [servr: "x"])
    end
  end

  test "waiter: waits for an event, or times out", %{playwright: playwright} do
    browser = BrowserType.launch!(Playwright.chromium(playwright))

    waiting =
      Task.async(fn ->
        Api.call("browser.waitForEvent", browser, fn ->
          waiter = Waiter.create_for_event(browser, "disconnected")
          Waiter.wait_for_event(waiter, browser, "disconnected")
        end)
      end)

    # Let the waiter subscribe before closing.
    Process.sleep(100)
    Browser.close!(browser)
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
