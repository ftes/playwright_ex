defmodule Playwright.Client.WaiterTest do
  # Unit test of the ported waiter: `Browser` has no public `waitForEvent`, so it runs the
  # client inside `Facade.call/2` as the facade would.
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserType
  alias Playwright.Client.Waiter
  alias Playwright.Runtime.Facade
  alias Playwright.TestBrowser
  alias Playwright.TimeoutError

  setup_all do
    start_supervised!({Playwright.Supervisor, name: __MODULE__})
    %{playwright: Playwright.instance(__MODULE__)}
  end

  test "waits for an event, or times out", %{playwright: playwright} do
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))

    waiting =
      Task.async(fn ->
        Facade.call("browser.waitForEvent", fn ->
          waiter = Waiter.create_for_event(browser, "disconnected")
          Waiter.wait_for_event(waiter, browser, "disconnected")
        end)
      end)

    # Let the waiter subscribe before closing.
    Process.sleep(100)
    Browser.close!(browser)
    assert Task.await(waiting, :infinity) == browser

    error =
      assert_raise TimeoutError, fn ->
        Facade.call("browser.waitForEvent", fn ->
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
