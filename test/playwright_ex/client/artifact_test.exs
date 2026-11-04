defmodule PlaywrightEx.Client.ArtifactTest do
  use ExUnit.Case, async: true

  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Download
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright

  @moduletag timeout: 120_000

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    %{playwright: PlaywrightEx.playwright(__MODULE__)}
  end

  # PLAN spike 6: `saveAs` over a remote connection pipes `saveAsStream` into the file.
  # `BrowserType.connect` is not ported: the local connection is marked remote instead.
  @tag :tmp_dir
  test "saveAs streams the artifact when connected remotely", %{playwright: playwright, tmp_dir: tmp_dir} do
    browser = BrowserType.launch!(Playwright.chromium(playwright))
    page = Browser.new_page!(browser)
    Page.set_content!(page, ~s(<a download="file.txt" href="data:text/plain;charset=utf8;,hello world">download</a>))
    download = Page.expect_download!(page, fn -> Page.click!(page, "a") end)

    connection = get(playwright, :_connection)
    put(connection, :_isRemote, true)

    try do
      assert {:error, error} = Download.path(download)
      assert error.message =~ "Path is not available when connecting remotely"

      path = Path.join([tmp_dir, "nested", "file.txt"])
      Download.save_as!(download, path)
      assert File.read!(path) == "hello world"
    after
      put(connection, :_isRemote, false)
    end

    assert Enum.join(Download.create_read_stream!(download)) == "hello world"
    Browser.close!(browser)
  end
end
