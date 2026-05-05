defmodule PlaywrightEx.DownloadTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  describe "expect_download/2 + await_download/1" do
    test "returns an error when no download is triggered", %{page: page} do
      {:ok, download_ref} = Page.expect_download(page.guid, timeout: 100)
      assert {:error, %{message: "Timeout 100ms exceeded."}} = Page.await_download(download_ref)
    end

    test "returns the path of a downloaded file", %{page: page, frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      {:ok, download_ref} = Page.expect_download(page.guid, timeout: @timeout)

      {:ok, _} =
        eval(frame.guid, """
        () => {
          const blob = new Blob(['hello world'], {type: 'text/plain'});
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url;
          a.download = 'test.txt';
          document.body.appendChild(a);
          a.click();
        }
        """)

      assert {:ok, path} = Page.await_download(download_ref)
      assert {:ok, "hello world"} = File.read(path)
    end
  end
end
