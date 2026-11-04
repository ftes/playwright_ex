# Not part of reference.mjs: checks the error/timeout mapping (TimeoutError, apiName prefix, ExpectError).
defmodule PlaywrightJS.ErrorsTest do
  use ExUnit.Case, async: false

  import PlaywrightJS.Matchers.Expect
  alias PlaywrightJS.OutOfProcess
  alias PlaywrightJS.Client.{Browser, BrowserContext, BrowserType, Errors, Locator, Page, Playwright}
  alias PlaywrightJS.Matchers.MatcherHint.ExpectError

  test "timeouts and expect failures" do
    %{playwright: playwright, stop: stop} = OutOfProcess.start()
    browser = BrowserType.launch(Playwright.chromium(playwright))
    page = browser |> Browser.new_context() |> BrowserContext.new_page()
    Page.goto(page, "file://" <> Path.expand("../../e2e/fixtures/form.html", __DIR__))

    e = assert_raise Errors.TimeoutError, fn -> Page.wait_for_event(page, "popup", %{timeout: 100}) end
    assert e.message =~ ~s(page.waitForEvent: Timeout 100ms exceeded while waiting for event "popup")
    assert e.message =~ "waiting for event \"popup\""

    e = assert_raise Errors.TimeoutError, fn -> page |> Page.locator("#nope") |> Locator.click(%{timeout: 100}) end
    assert e.message =~ "locator.click: Timeout 100ms exceeded."
    assert e.message =~ "Call log:"

    e = assert_raise ExpectError, fn -> expect(page, %{timeout: 100}) |> to_have_title("Nope") end
    assert e.message =~ "expect(page).toHaveTitle(expected) failed"
    assert e.message =~ ~s(Received: "Sign up")

    expect(Page.get_by_label(page, "I agree")) |> not_() |> to_be_checked()

    Browser.close(browser)
    stop.()
  end
end
