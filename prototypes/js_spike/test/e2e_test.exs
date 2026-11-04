# Port of prototypes/e2e/reference.mjs, statement by statement.
defmodule PlaywrightJS.E2ETest do
  use ExUnit.Case, async: false

  import PlaywrightJS.Matchers.Expect
  alias PlaywrightJS.OutOfProcess
  alias PlaywrightJS.Runtime.Promise
  alias PlaywrightJS.Client.{Browser, BrowserContext, BrowserType, Download, Locator, Page, Playwright}

  @fixtures Path.expand("../../e2e/fixtures", __DIR__)

  @tag timeout: 120_000
  test "reference e2e" do
    fixtures = @fixtures
    tmp = Path.join(System.tmp_dir!(), "pw-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    upload = Path.join(tmp, "notes.txt")
    File.write!(upload, "hello upload")

    # import { chromium } from 'playwright';
    %{playwright: playwright, stop: stop} = OutOfProcess.start()
    chromium = Playwright.chromium(playwright)

    browser = BrowserType.launch(chromium)
    context = Browser.new_context(browser)
    page = BrowserContext.new_page(context)

    # Navigation
    Page.goto(page, path_to_file_url(Path.join(fixtures, "form.html")))
    expect(page) |> to_have_title("Sign up")

    # Form + file upload
    page |> Page.get_by_label("Name") |> Locator.fill("Ada")
    page |> Page.get_by_label("Color") |> Locator.select_option("blue")
    page |> Page.get_by_label("I agree") |> Locator.check()
    expect(Page.get_by_label(page, "I agree")) |> to_be_checked()
    page |> Page.get_by_label("Attachment") |> Locator.set_input_files(upload)
    expect(Page.locator(page, "#file-info")) |> to_have_text("notes.txt (12 bytes)")

    # Submit -> navigation
    page |> Page.get_by_role("button", %{name: "Submit"}) |> Locator.click()
    Page.wait_for_url(page, ~r/result\.html/)
    expect(page) |> to_have_url(~r/name=Ada/)
    expect(Page.get_by_test_id(page, "greeting")) |> to_have_text("Hello, Ada (blue)")

    # Window handling
    popup_promise = Promise.async(fn -> Page.wait_for_event(page, "popup") end)
    page |> Page.get_by_role("link", %{name: "Open details"}) |> Locator.click()
    popup = Promise.await(popup_promise)
    Page.wait_for_load_state(popup)
    expect(Page.locator(popup, "h1")) |> to_have_text("Details")
    if length(BrowserContext.pages(context)) != 2, do: raise("expected 2 pages")
    Page.close(popup)
    if length(BrowserContext.pages(context)) != 1, do: raise("expected 1 page")

    # Downloads
    download_promise = Promise.async(fn -> Page.wait_for_event(page, "download") end)
    page |> Page.get_by_role("link", %{name: "Download report"}) |> Locator.click()
    download = Promise.await(download_promise)
    if Download.suggested_filename(download) != "report.csv", do: raise("bad filename")
    saved = Path.join([tmp, "out", "report.csv"])
    Download.save_as(download, saved)
    if File.read!(saved) != "a,b\n1,2", do: raise("bad download content")

    Browser.close(browser)
    stop.()
    IO.puts("reference e2e: OK")
  end

  # node:url pathToFileURL
  defp path_to_file_url(path), do: "file://" <> URI.encode(path)
end
