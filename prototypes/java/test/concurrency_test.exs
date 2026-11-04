defmodule PlaywrightJava.ConcurrencyTest do
  # Not part of reference.mjs: checks the OTP mapping lets several processes share one connection/browser
  # (Java would need one Playwright per thread).
  use ExUnit.Case, async: true

  import Playwright.Assertions.PlaywrightAssertions
  alias Playwright.{Browser, BrowserContext, BrowserType, Locator, Page}
  alias Playwright.Assertions.LocatorAssertions

  @form "file://" <> Path.expand("../../e2e/fixtures/form.html", __DIR__)

  test "processes share one browser" do
    playwright = Playwright.create()
    browser = playwright |> Playwright.chromium() |> BrowserType.launch()

    1..4
    |> Task.async_stream(fn i ->
      page = browser |> Browser.new_context() |> BrowserContext.new_page()
      Page.navigate(page, @form)
      page |> Page.get_by_label("Name") |> Locator.fill("user #{i}")

      popup =
        Page.wait_for_popup(page, fn ->
          Page.navigate(page, "data:text/html,<a href='about:blank' target=_blank>go</a>")
          page |> Page.locator("a") |> Locator.click()
        end)

      popup |> Page.locator("body") |> assert_that() |> LocatorAssertions.has_text("")
      length(BrowserContext.pages(Page.context(page)))
    end)
    |> Enum.each(fn {:ok, pages} -> assert pages == 2 end)

    Browser.close(browser)
    Playwright.close(playwright)
  end
end
