defmodule PlaywrightEx.Examples.DownloadTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.Download
  alias PlaywrightEx.Promise

  example "Download",
    js: ~S"""
    // Start waiting for download before clicking. Note no await.
    const downloadPromise = page.waitForEvent('download');
    await page.getByText('Download file').click();
    const download = await downloadPromise;

    // Wait for the download process to complete and save the downloaded file somewhere.
    await download.saveAs('/path/to/save/at/' + download.suggestedFilename());
    """,
    html: ~s(<a href="/file.txt" download>Download file</a>),
    skip: "saves to /path/to/save/at" do
    # Start waiting for download before clicking. Note no await.
    download_promise = Page.wait_for_event(page, :download)
    Page.get_by_text(page, "Download file") |> Locator.click!()
    download = Promise.await!(download_promise)

    # Wait for the download process to complete and save the downloaded file somewhere.
    Download.save_as!(download, "/path/to/save/at/" <> Download.suggested_filename(download))
  end

  example "Download.saveAs",
    js: ~S"""
    await download.saveAs('/path/to/save/at/' + download.suggestedFilename());
    """,
    html: ~s(<a href="/file.txt" download>Download file</a>),
    given: [
      download: Page.expect_download!(page, fn -> Page.get_by_text(page, "Download file") |> Locator.click!() end)
    ],
    skip: "saves to /path/to/save/at" do
    Download.save_as!(download, "/path/to/save/at/" <> Download.suggested_filename(download))
  end
end
