defmodule PlaywrightEx.Examples.FileChooserTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.FileChooser
  alias PlaywrightEx.Promise

  example "FileChooser",
    js: ~S"""
    // Start waiting for file chooser before clicking. Note no await.
    const fileChooserPromise = page.waitForEvent('filechooser');
    await page.getByText('Upload file').click();
    const fileChooser = await fileChooserPromise;
    await fileChooser.setFiles(path.join(__dirname, 'myfile.pdf'));
    """,
    html: ~s(<label>Upload file <input type="file"></label>) do
    # Start waiting for file chooser before clicking. Note no await.
    file_chooser_promise = Page.wait_for_event(page, :file_chooser)
    Page.get_by_text(page, "Upload file") |> Locator.click!()
    file_chooser = Promise.await!(file_chooser_promise)
    FileChooser.set_files!(file_chooser, Path.join(__DIR__, "myfile.pdf"))
  end
end
