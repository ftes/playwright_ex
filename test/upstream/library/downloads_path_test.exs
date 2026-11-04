defmodule PlaywrightEx.Library.DownloadsPathTest do
  @upstream "tests/library/downloads-path.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Download
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  defp click_download(page), do: Page.expect_download!(page, fn -> Page.click!(page, "a") end)

  describe "downloads path" do
    # it.skip(({ mode }) => mode !== 'default', 'download.path() is not available in remote mode');  -- always default mode

    setup %{server: server} do
      TestServer.set_route(server, "/download", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
        |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=file.txt")
        |> Plug.Conn.send_resp(200, "Hello world")
      end)

      :ok
    end

    @tag :tmp_dir
    test "should keep downloadsPath folder", %{browser_type: browser_type, server: server, tmp_dir: tmp_dir} do
      downloads_browser = BrowserType.launch!(browser_type, downloads_path: tmp_dir)
      page = Browser.new_page!(downloads_browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      assert Download.url(download) == "#{server.prefix}/download"
      assert Download.suggested_filename(download) == "file.txt"
      Download.path(download)
      Page.close!(page)
      Browser.close!(downloads_browser)
      assert File.exists?(tmp_dir)
    end

    @tag :tmp_dir
    test "should delete downloads when context closes", %{browser_type: browser_type, server: server, tmp_dir: tmp_dir} do
      downloads_browser = BrowserType.launch!(browser_type, downloads_path: tmp_dir)
      page = Browser.new_page!(downloads_browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      path = Download.path!(download)
      assert File.exists?(path)
      Page.close!(page)
      refute File.exists?(path)
      Browser.close!(downloads_browser)
    end

    @tag :tmp_dir
    test "should report downloads in downloadsPath folder", %{
      browser_type: browser_type,
      server: server,
      tmp_dir: tmp_dir
    } do
      downloads_browser = BrowserType.launch!(browser_type, downloads_path: tmp_dir)
      page = Browser.new_page!(downloads_browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      path = Download.path!(download)
      assert String.starts_with?(path, tmp_dir)
      Page.close!(page)
      Browser.close!(downloads_browser)
    end

    @tag :tmp_dir
    test "should report downloads in downloadsPath folder with a relative path", %{
      browser_type: browser_type,
      server: server,
      tmp_dir: tmp_dir
    } do
      downloads_browser = BrowserType.launch!(browser_type, downloads_path: Path.relative_to_cwd(tmp_dir))
      page = Browser.new_page!(downloads_browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      download_path = Download.path!(download)
      assert String.starts_with?(download_path, tmp_dir)
      Page.close!(page)
      Browser.close!(downloads_browser)
    end

    @tag :tmp_dir
    test "should accept downloads in persistent context", %{
      launch_persistent: launch_persistent,
      server: server,
      tmp_dir: tmp_dir
    } do
      %{context: context, page: page} = launch_persistent.(downloads_path: tmp_dir)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      assert Download.url(download) == "#{server.prefix}/download"
      assert Download.suggested_filename(download) == "file.txt"
      path = Download.path!(download)
      assert String.starts_with?(path, tmp_dir)
      BrowserContext.close!(context)
    end

    @tag :tmp_dir
    test "should delete downloads when persistent context closes", %{
      launch_persistent: launch_persistent,
      server: server,
      tmp_dir: tmp_dir
    } do
      %{context: context, page: page} = launch_persistent.(downloads_path: tmp_dir)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      path = Download.path!(download)
      assert File.exists?(path)
      BrowserContext.close!(context)
      refute File.exists?(path)
    end
  end
end
