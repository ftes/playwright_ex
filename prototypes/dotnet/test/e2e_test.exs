defmodule E2ETest do
  # Port of prototypes/e2e/reference.mjs, written the way the .NET client reads:
  #   await page.GetByLabel("Name").FillAsync("Ada");  ->  page |> Page.get_by_label("Name") |> Locator.fill_async("Ada")
  #   await Expect(page).ToHaveTitleAsync("Sign up");   ->  page |> expect() |> PageAssertions.to_have_title_async("Sign up")
  use ExUnit.Case, async: false

  import Playwright.Assertions
  alias Playwright.Core.{Browser, BrowserContext, BrowserType, Download, Locator, LocatorAssertions, Page, PageAssertions, PlaywrightImpl}

  @moduletag timeout: 120_000
  @fixtures Path.expand("../../e2e/fixtures", __DIR__)

  test "reference scenario" do
    tmp = Path.join(System.tmp_dir!(), "pw-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    upload = Path.join(tmp, "notes.txt")
    File.write!(upload, "hello upload")

    playwright = Playwright.create_async()
    browser = playwright |> PlaywrightImpl.chromium() |> BrowserType.launch()
    context = Browser.new_context(browser)
    page = BrowserContext.new_page(context)

    # Navigation
    Page.goto_async(page, "file://" <> Path.join(@fixtures, "form.html"))
    page |> expect() |> PageAssertions.to_have_title_async("Sign up")

    # Form + file upload
    page |> Page.get_by_label("Name") |> Locator.fill_async("Ada")
    page |> Page.get_by_label("Color") |> Locator.select_option_async("blue")
    page |> Page.get_by_label("I agree") |> Locator.check_async()
    page |> Page.get_by_label("I agree") |> expect() |> LocatorAssertions.to_be_checked_async()
    page |> Page.get_by_label("Attachment") |> Locator.set_input_files_async(upload)
    page |> Page.locator("#file-info") |> expect() |> LocatorAssertions.to_have_text_async("notes.txt (12 bytes)")

    # Submit -> navigation
    page |> Page.get_by_role(:button, name: "Submit") |> Locator.click_async()
    Page.wait_for_url_async(page, ~r/result\.html/)
    page |> expect() |> PageAssertions.to_have_url_async(~r/name=Ada/)
    page |> Page.get_by_test_id("greeting") |> expect() |> LocatorAssertions.to_have_text_async("Hello, Ada (blue)")

    # Window handling
    popup =
      Page.run_and_wait_for_popup_async(page, fn ->
        page |> Page.get_by_role(:link, name: "Open details") |> Locator.click_async()
      end)

    Page.wait_for_load_state_async(popup)
    popup |> Page.locator("h1") |> expect() |> LocatorAssertions.to_have_text_async("Details")
    assert length(BrowserContext.pages(context)) == 2, "expected 2 pages"
    Page.close_async(popup)
    assert length(BrowserContext.pages(context)) == 1, "expected 1 page"

    # Downloads
    download =
      Page.run_and_wait_for_download_async(page, fn ->
        page |> Page.get_by_role(:link, name: "Download report") |> Locator.click_async()
      end)

    assert Download.suggested_filename(download) == "report.csv", "bad filename"
    saved = Path.join([tmp, "out", "report.csv"])
    Download.save_as_async(download, saved)
    assert File.read!(saved) == "a,b\n1,2", "bad download content"

    Browser.close(browser)
  end
end
