defmodule PlaywrightJava.E2ETest do
  # Port of prototypes/e2e/reference.mjs, step by step, in the style of the Java client
  # (synchronous calls, `wait_for_*(fn -> action end)` instead of event promises, `assert_that(...)`).
  use ExUnit.Case, async: true

  import Playwright.Assertions.PlaywrightAssertions
  alias Playwright.{Browser, BrowserContext, BrowserType, Download, Locator, Page}
  alias Playwright.Assertions.{LocatorAssertions, PageAssertions}

  @fixtures Path.expand("../../e2e/fixtures", __DIR__)

  test "reference scenario" do
    tmp = Path.join(System.tmp_dir!(), "pw-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    upload = Path.join(tmp, "notes.txt")
    File.write!(upload, "hello upload")

    playwright = Playwright.create()
    browser = playwright |> Playwright.chromium() |> BrowserType.launch()
    context = Browser.new_context(browser)
    page = BrowserContext.new_page(context)

    # Navigation
    Page.navigate(page, "file://" <> Path.join(@fixtures, "form.html"))
    page |> assert_that() |> PageAssertions.has_title("Sign up")

    # Form + file upload
    page |> Page.get_by_label("Name") |> Locator.fill("Ada")
    page |> Page.get_by_label("Color") |> Locator.select_option("blue")
    page |> Page.get_by_label("I agree") |> Locator.check()
    page |> Page.get_by_label("I agree") |> assert_that() |> LocatorAssertions.is_checked()
    page |> Page.get_by_label("Attachment") |> Locator.set_input_files(upload)
    page |> Page.locator("#file-info") |> assert_that() |> LocatorAssertions.has_text("notes.txt (12 bytes)")

    # Submit -> navigation
    page |> Page.get_by_role(:button, name: "Submit") |> Locator.click()
    Page.wait_for_url(page, ~r/result\.html/)
    page |> assert_that() |> PageAssertions.has_url(~r/name=Ada/)
    page |> Page.get_by_test_id("greeting") |> assert_that() |> LocatorAssertions.has_text("Hello, Ada (blue)")

    # Window handling
    popup =
      Page.wait_for_popup(page, fn ->
        page |> Page.get_by_role(:link, name: "Open details") |> Locator.click()
      end)

    Page.wait_for_load_state(popup)
    popup |> Page.locator("h1") |> assert_that() |> LocatorAssertions.has_text("Details")
    assert length(BrowserContext.pages(context)) == 2
    Page.close(popup)
    assert length(BrowserContext.pages(context)) == 1

    # Downloads
    download =
      Page.wait_for_download(page, fn ->
        page |> Page.get_by_role(:link, name: "Download report") |> Locator.click()
      end)

    assert Download.suggested_filename(download) == "report.csv"
    saved = Path.join([tmp, "out", "report.csv"])
    Download.save_as(download, saved)
    assert File.read!(saved) == "a,b\n1,2"

    Browser.close(browser)
    Playwright.close(playwright)
  end
end
