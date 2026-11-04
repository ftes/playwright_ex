# Port of prototypes/e2e/reference.mjs, written the way the Python sync API docs
# read (`with sync_playwright() as p:`, `with page.expect_popup() as popup_info:`).
defmodule E2ETest do
  use ExUnit.Case
  import Playwright.SyncApi
  alias Playwright.Impl.{Browser, BrowserContext, BrowserType, Download, Locator, Page}
  alias Playwright.Impl.Assertions.{LocatorAssertions, PageAssertions}
  alias Playwright.Impl.EventContextManagerImpl, as: EventInfo

  @fixtures Path.expand("../../e2e/fixtures", __DIR__)

  @tag timeout: 120_000
  test "reference scenario" do
    tmp = Path.join(System.tmp_dir!(), "pw-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    upload = Path.join(tmp, "notes.txt")
    File.write!(upload, "hello upload")

    # with sync_playwright() as playwright:
    Py.with_(sync_playwright(), fn playwright ->
      browser = BrowserType.launch(playwright["chromium"])
      context = Browser.new_context(browser)
      page = BrowserContext.new_page(context)

      # Navigation
      Page.goto(page, "file://" <> Path.join(@fixtures, "form.html"))
      expect(page) |> PageAssertions.to_have_title("Sign up")

      # Form + file upload
      page |> Page.get_by_label("Name") |> Locator.fill("Ada")
      page |> Page.get_by_label("Color") |> Locator.select_option("blue")
      page |> Page.get_by_label("I agree") |> Locator.check()
      expect(Page.get_by_label(page, "I agree")) |> LocatorAssertions.to_be_checked()
      page |> Page.get_by_label("Attachment") |> Locator.set_input_files(upload)

      expect(Page.locator(page, "#file-info"))
      |> LocatorAssertions.to_have_text("notes.txt (12 bytes)")

      # Submit -> navigation
      page |> Page.get_by_role("button", name: "Submit") |> Locator.click()
      Page.wait_for_url(page, ~r/result\.html/)
      expect(page) |> PageAssertions.to_have_url(~r/name=Ada/)

      expect(Page.get_by_test_id(page, "greeting"))
      |> LocatorAssertions.to_have_text("Hello, Ada (blue)")

      # Window handling
      # with page.expect_popup() as popup_info:
      popup_info = Page.expect_popup(page)
      page |> Page.get_by_role("link", name: "Open details") |> Locator.click()
      popup = EventInfo.value(popup_info)
      Page.wait_for_load_state(popup)
      expect(Page.locator(popup, "h1")) |> LocatorAssertions.to_have_text("Details")
      assert length(BrowserContext.pages(context)) == 2, "expected 2 pages"
      Page.close(popup)
      assert length(BrowserContext.pages(context)) == 1, "expected 1 page"

      # Downloads
      # with page.expect_download() as download_info:
      download_info = Page.expect_download(page)
      page |> Page.get_by_role("link", name: "Download report") |> Locator.click()
      download = EventInfo.value(download_info)
      assert Download.suggested_filename(download) == "report.csv", "bad filename"
      saved = Path.join([tmp, "out", "report.csv"])
      Download.save_as(download, saved)
      assert File.read!(saved) == "a,b\n1,2", "bad download content"

      Browser.close(browser)
    end)
  end
end
