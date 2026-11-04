defmodule PlaywrightEx.Library.DownloadTest do
  @upstream "tests/library/download.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Download
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.TestServer

  # config/errors.ts
  @k_target_closed_error_message "Target page, context or browser has been closed"

  defp send_attachment(conn, body, disposition \\ "attachment") do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
    |> Plug.Conn.put_resp_header("content-disposition", disposition)
    |> Plug.Conn.send_resp(200, body)
  end

  # res.writeHead(200); res.flushHeaders(); res.write(...): the response never ends.
  defp stall(conn, chunks) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=file.txt")
      |> Plug.Conn.send_chunked(200)

    for chunk <- chunks, do: Plug.Conn.chunk(conn, chunk)
    Process.sleep(:infinity)
  end

  defp click_download(page, selector \\ "a", options \\ []) do
    Page.expect_download!(page, fn -> Page.click!(page, selector, options) end)
  end

  describe "download event" do
    # it.skip(({ mode }) => mode !== 'default', 'download.path() is not available in remote mode');  -- always default mode

    setup %{server: server} do
      TestServer.set_route(server, "/download", &send_attachment(&1, "Hello world"))

      TestServer.set_route(
        server,
        "/downloadWithFilename",
        &send_attachment(&1, "Hello world", "attachment; filename=file.txt")
      )

      # Chromium requires a large enough payload to trigger the download event soon enough
      TestServer.set_route(server, "/downloadWithDelay", &stall(&1, [String.duplicate("a", 4096), "foo"]))

      TestServer.set_route(server, "/downloadWithCOOP", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
        |> send_attachment("Hello world")
      end)

      :ok
    end

    test "should report download when navigation turns into download @smoke", %{
      browser: browser,
      server: server,
      browser_name: browser_name
    } do
      page = Browser.new_page!(browser)
      download = Page.wait_for_event(page, :download)
      response_or_error = Page.goto(page, server.prefix <> "/download")
      download = Promise.await!(download)
      assert Download.page(download) == page
      assert Download.url(download) == "#{server.prefix}/download"
      path = Download.path!(download)
      assert File.exists?(path)
      assert File.read!(path) == "Hello world"

      assert {:error, error} = response_or_error
      assert error.message =~ "Download is starting"

      if browser_name != "firefox", do: assert(Page.url(page) == "about:blank")
      Page.close!(page)
    end

    test "should work with Cross-Origin-Opener-Policy", %{browser: browser, server: server, browser_name: browser_name} do
      page = Browser.new_page!(browser)
      download = Page.wait_for_event(page, :download)
      response_or_error = Page.goto(page, server.prefix <> "/downloadWithCOOP")
      download = Promise.await!(download)
      assert Download.page(download) == page
      assert Download.url(download) == "#{server.prefix}/downloadWithCOOP"
      path = Download.path!(download)
      assert File.exists?(path)
      assert File.read!(path) == "Hello world"
      assert {:error, error} = response_or_error
      assert error.message =~ "Download is starting"
      if browser_name != "firefox", do: assert(Page.url(page) == "about:blank")
      Page.close!(page)
    end

    test "should report downloads with acceptDownloads: false", %{browser: browser, server: server} do
      page = Browser.new_page!(browser, accept_downloads: false)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/downloadWithFilename">download</a>))
      download = click_download(page)
      assert Download.page(download) == page
      assert Download.url(download) == "#{server.prefix}/downloadWithFilename"
      assert Download.suggested_filename(download) == "file.txt"
      {:error, error} = Download.path(download)
      assert Download.failure!(download) =~ "acceptDownloads"
      assert error.message =~ "acceptDownloads: true"
      Page.close!(page)
    end

    test "should report downloads with acceptDownloads: true", %{browser: browser, server: server} do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      path = Download.path!(download)
      assert File.exists?(path)
      assert File.read!(path) == "Hello world"
      Page.close!(page)
    end

    test "should report proper download url when download is from download attribute", %{
      browser: browser,
      server: server
    } do
      page = Browser.new_page!(browser)
      Page.goto!(page, server.prefix <> "/empty.html")
      Page.set_content!(page, ~s(<a href="#{server.prefix}/chromium-linux.zip" download="foo.zip">download</a>))
      download = click_download(page)
      assert Download.url(download) == "#{server.prefix}/chromium-linux.zip"
      Page.close!(page)
    end

    test "should report downloads for download attribute", %{browser: browser, server: server} do
      page = Browser.new_page!(browser)
      Page.goto!(page, server.prefix <> "/empty.html")
      Page.set_content!(page, ~s(<a href="#{server.prefix}/chromium-linux.zip" download="foo.zip">download</a>))
      download = click_download(page)
      assert Download.suggested_filename(download) == "foo.zip"
      path = Download.path!(download)
      assert File.exists?(path)
      Page.close!(page)
    end

    @tag :tmp_dir
    test "should save to user-specified path without updating original path", %{
      browser: browser,
      server: server,
      tmp_dir: tmp_dir
    } do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      user_path = Path.join(tmp_dir, "download.txt")
      Download.save_as!(download, user_path)
      assert File.exists?(user_path)
      assert File.read!(user_path) == "Hello world"

      original_path = Download.path!(download)
      assert File.exists?(original_path)
      assert File.read!(original_path) == "Hello world"
      Page.close!(page)
    end

    @tag :tmp_dir
    test "should save to two different paths with multiple saveAs calls", %{
      browser: browser,
      server: server,
      tmp_dir: tmp_dir
    } do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      user_path = Path.join(tmp_dir, "download.txt")
      Download.save_as!(download, user_path)
      assert File.exists?(user_path)
      assert File.read!(user_path) == "Hello world"

      another_user_path = Path.join(tmp_dir, "download (2).txt")
      Download.save_as!(download, another_user_path)
      assert File.exists?(another_user_path)
      assert File.read!(another_user_path) == "Hello world"
      Page.close!(page)
    end

    @tag :tmp_dir
    test "should save to overwritten filepath", %{browser: browser, server: server, tmp_dir: tmp_dir} do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      dir = Path.join(tmp_dir, "downloads")
      user_path = Path.join(dir, "download.txt")
      Download.save_as!(download, user_path)
      assert length(File.ls!(dir)) == 1
      Download.save_as!(download, user_path)
      assert length(File.ls!(dir)) == 1
      assert File.exists?(user_path)
      assert File.read!(user_path) == "Hello world"
      Page.close!(page)
    end

    @tag :tmp_dir
    test "should create subdirectories when saving to non-existent user-specified path", %{
      browser: browser,
      server: server,
      tmp_dir: tmp_dir
    } do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      nested_path = Path.join([tmp_dir, "these", "are", "directories", "download.txt"])
      Download.save_as!(download, nested_path)
      assert File.exists?(nested_path)
      assert File.read!(nested_path) == "Hello world"
      Page.close!(page)
    end

    @tag :tmp_dir
    test "should error when saving with downloads disabled", %{browser: browser, server: server, tmp_dir: tmp_dir} do
      page = Browser.new_page!(browser, accept_downloads: false)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      user_path = Path.join(tmp_dir, "download.txt")
      {:error, %{message: message}} = Download.save_as(download, user_path)
      assert message =~ "Pass { acceptDownloads: true } when you are creating your browser context"
      Page.close!(page)
    end

    @tag :tmp_dir
    test "should error when saving after deletion", %{browser: browser, server: server, tmp_dir: tmp_dir} do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      user_path = Path.join(tmp_dir, "download.txt")
      Download.delete!(download)
      {:error, %{message: message}} = Download.save_as(download, user_path)
      assert message =~ "Target page, context or browser has been closed"
      Page.close!(page)
    end

    test "should report non-navigation downloads", %{browser: browser, server: server} do
      # Mac WebKit embedder does not download in this case, although Safari does.
      TestServer.set_route(server, "/download", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
        |> Plug.Conn.send_resp(200, "Hello world")
      end)

      page = Browser.new_page!(browser)
      Page.goto!(page, server.empty_page)
      Page.set_content!(page, ~s(<a download="file.txt" href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      assert Download.suggested_filename(download) == "file.txt"
      path = Download.path!(download)
      assert File.exists?(path)
      assert File.read!(path) == "Hello world"
      Page.close!(page)
    end

    test "should report download path within page.on('download', …) handler for Files", %{
      browser: browser,
      server: server
    } do
      page = Browser.new_page!(browser)
      test = self()
      Page.on(page, :download, fn dl -> send(test, {:path, Download.path!(dl)}) end)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      Page.click!(page, "a")
      assert_receive {:path, path}, 10_000
      assert File.read!(path) == "Hello world"
      Page.close!(page)
    end

    test "should report download path within page.on('download', …) handler for Blobs", %{
      browser: browser,
      server: server
    } do
      page = Browser.new_page!(browser)
      test = self()
      Page.on(page, :download, fn dl -> send(test, {:path, Download.path!(dl)}) end)
      Page.goto!(page, server.prefix <> "/download-blob.html")
      Page.click!(page, "a")
      assert_receive {:path, path}, 10_000
      assert File.read!(path) == "Hello world"
      Page.close!(page)
    end

    test "should report alt-click downloads", %{browser: browser, server: server, browser_name: browser_name} do
      # it.skip(browserName === 'firefox', 'Firefox does not download on alt-click.');
      if browser_name != "firefox" do
        TestServer.set_route(server, "/download", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
          |> Plug.Conn.send_resp(200, "Hello world")
        end)

        page = Browser.new_page!(browser)
        Page.goto!(page, server.empty_page)
        Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
        download = click_download(page, "a", modifiers: [:alt])
        path = Download.path!(download)
        assert File.exists?(path)
        assert File.read!(path) == "Hello world"
        Page.close!(page)
      end
    end

    test "should report new window downloads", %{browser: browser, server: server} do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a target=_blank href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      path = Download.path!(download)
      assert File.exists?(path)
      Page.close!(page)
    end

    test "should delete file", %{browser: browser, server: server} do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      path = Download.path!(download)
      assert File.exists?(path)
      Download.delete!(download)
      refute File.exists?(path)
      Page.close!(page)
    end

    test "should expose stream", %{browser: browser, server: server} do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      stream = Download.create_read_stream!(download)
      content = Enum.join(stream)
      assert content == "Hello world"
      Page.close!(page)
    end

    test "should delete downloads on context destruction", %{browser: browser, server: server} do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download1 = click_download(page)
      download2 = click_download(page)
      path1 = Download.path!(download1)
      path2 = Download.path!(download2)
      assert File.exists?(path1)
      assert File.exists?(path2)
      BrowserContext.close!(Page.context(page))
      refute File.exists?(path1)
      refute File.exists?(path2)
    end

    test "should delete downloads on browser gone", %{server: server, browser_type: browser_type} do
      browser = BrowserType.launch!(browser_type)
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download1 = click_download(page)
      download2 = click_download(page)
      path1 = Download.path!(download1)
      path2 = Download.path!(download2)
      assert File.exists?(path1)
      assert File.exists?(path2)
      Browser.close!(browser)
      refute File.exists?(path1)
      refute File.exists?(path2)
      refute File.exists?(Path.join(path1, ".."))
    end

    @tag :tmp_dir
    test "should save downloads to artifactsDir", %{server: server, browser_type: browser_type, tmp_dir: tmp_dir} do
      artifacts_dir = Path.join(tmp_dir, "artifacts")
      browser = BrowserType.launch!(browser_type, artifacts_dir: artifacts_dir)
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      download_path = Download.path!(download)
      assert String.starts_with?(download_path, artifacts_dir)
      assert File.exists?(download_path)
      Browser.close!(browser)
      # User-provided artifactsDir should not be cleaned up.
      assert File.exists?(artifacts_dir)
    end

    @tag :tmp_dir
    test "should close the context without awaiting the failed download", %{
      browser: browser,
      server: server,
      https_server: https_server,
      browser_name: browser_name,
      tmp_dir: tmp_dir
    } do
      # it.skip(browserName !== 'chromium', 'Only Chromium downloads on alt-click');
      if browser_name == "chromium" do
        page = Browser.new_page!(browser)
        Page.goto!(page, server.empty_page)

        Page.set_content!(
          page,
          ~s(<a href="#{https_server.prefix}/downloadWithFilename" download="file.txt">click me</a>)
        )

        # Use alt-click to force the download. Otherwise browsers might try to navigate first,
        # probably because of http -> https link.
        download = click_download(page, "a", modifiers: [:alt])

        [download_error, save_error, _] =
          await_all([
            fn -> Download.path(download) end,
            fn -> Download.save_as(download, Path.join(tmp_dir, "download.txt")) end,
            fn -> BrowserContext.close!(Page.context(page)) end
          ])

        assert {:error, %{message: "download.path: canceled"}} = download_error
        {:error, %{message: message}} = save_error

        assert message in [
                 "download.saveAs: File not found on disk. Check download.failure() for details.",
                 "download.saveAs: canceled"
               ]
      end
    end

    @tag :tmp_dir
    test "should close the context without awaiting the download", %{
      browser: browser,
      server: server,
      tmp_dir: tmp_dir
    } do
      # it.skip(browserName === 'webkit' && (platform === 'linux' || channel === 'webkit-wsl'), ...)
      if !webkit_on_linux?() do
        TestServer.set_route(server, "/downloadStall", &stall(&1, ["Hello world"]))
        page = Browser.new_page!(browser)
        Page.goto!(page, server.empty_page)
        Page.set_content!(page, ~s(<a href="#{server.prefix}/downloadStall" download="file.txt">click me</a>))
        download = click_download(page)

        [download_error, save_error, _] =
          await_all([
            fn -> Download.path(download) end,
            fn -> Download.save_as(download, Path.join(tmp_dir, "download.txt")) end,
            fn -> BrowserContext.close!(Page.context(page)) end
          ])

        # The exact error message is racy, because sometimes browser is fast enough
        # to cancel the download.
        {:error, %{message: download_message}} = download_error
        {:error, %{message: save_message}} = save_error
        assert download_message in ["download.path: canceled", "download.path: " <> @k_target_closed_error_message]

        assert save_message in [
                 "download.saveAs: canceled",
                 "download.saveAs: " <> @k_target_closed_error_message
               ]
      end
    end

    @tag :tmp_dir
    test "should throw if browser dies", %{server: server, browser_type: browser_type, tmp_dir: tmp_dir} do
      if !webkit_on_linux?() do
        TestServer.set_route(server, "/downloadStall", &stall(&1, ["Hello world"]))
        browser = BrowserType.launch!(browser_type)
        page = Browser.new_page!(browser)
        Page.set_content!(page, ~s(<a href="#{server.prefix}/downloadStall">click me</a>))
        download = click_download(page)

        [download_error, save_error, _] =
          await_all([
            fn -> Download.path(download) end,
            fn -> Download.save_as(download, Path.join(tmp_dir, "download.txt")) end,
            # (browser as any)._channel.killForTests()
            fn -> Api.call(nil, browser, fn -> ChannelOwner.channel_call(browser, :killForTests, %{}) end) end
          ])

        assert {:error, %{message: "download.path: " <> @k_target_closed_error_message}} = download_error
        {:error, %{message: save_message}} = save_error
        assert save_message =~ "download.saveAs: " <> @k_target_closed_error_message
        Browser.close!(browser)
      end
    end

    @tag :tmp_dir
    test "should download large binary.zip", %{browser: browser, server: server, tmp_dir: tmp_dir} do
      zip_file = Path.join(tmp_dir, "binary.zip")
      content = :crypto.strong_rand_bytes(Bitwise.bsl(1, 20))
      File.write!(zip_file, content)
      TestServer.set_route(server, "/binary.zip", &TestServer.serve_file(server, &1, zip_file))

      page = Browser.new_page!(browser)
      Page.goto!(page, server.prefix <> "/empty.html")
      Page.set_content!(page, ~s(<a href="#{server.prefix}/binary.zip" download="binary.zip">download</a>))
      download = click_download(page)
      download_path = Download.path!(download)
      file_content = File.read!(download_path)
      assert byte_size(file_content) == byte_size(content)
      assert file_content == content

      stream = Download.create_read_stream!(download)
      data = stream |> Enum.to_list() |> IO.iodata_to_binary()
      assert byte_size(data) == byte_size(content)
      assert data == content
      Page.close!(page)
    end

    test "should be able to cancel pending downloads", %{browser: browser, server: server} do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/downloadWithDelay">download</a>))
      download = click_download(page)
      Download.cancel!(download)
      failure = Download.failure!(download)
      assert failure == "canceled"
      Page.close!(page)
    end

    test "should not fail explicitly to cancel a download even if that is already finished", %{
      browser: browser,
      server: server
    } do
      page = Browser.new_page!(browser)
      Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
      download = click_download(page)
      path = Download.path!(download)
      assert File.exists?(path)
      assert File.read!(path) == "Hello world"
      Download.cancel!(download)
      failure = Download.failure!(download)
      assert failure == nil
      Page.close!(page)
    end

    @tag skip: "not ported: route"
    test "should report downloads with interception"

    @tag :tmp_dir
    test "should emit download event from nested iframes", %{server: server, browser: browser, tmp_dir: tmp_dir} do
      page = Browser.new_page!(browser)

      for {from, body} <- [
            {"/1", ~s(<iframe src="#{server.prefix}/2"></iframe>)},
            {"/2", ~s(<iframe src="#{server.prefix}/3"></iframe>)},
            {"/3", ~s( <a href="#{server.prefix}/download">download</a>)}
          ] do
        TestServer.set_route(server, from, fn conn ->
          conn |> Plug.Conn.put_resp_header("content-type", "text/html") |> Plug.Conn.send_resp(200, body)
        end)
      end

      Page.goto!(page, server.prefix <> "/1")

      download =
        Page.expect_download!(page, fn ->
          Frame.click!(Page.frame(page, %{url: server.prefix <> "/3"}), "text=download")
        end)

      user_path = Path.join(tmp_dir, "download.txt")
      Download.save_as!(download, user_path)
      assert File.exists?(user_path)
      assert File.read!(user_path) == "Hello world"
      Page.close!(page)
    end
  end

  test "should be able to download a PDF file", %{browser: browser, server: server, asset: asset} do
    page = Browser.new_page!(browser)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(\n    <a href="/empty.pdf" download>download</a>\n  ))
    download = click_download(page)
    assert_download_to_pdf(download, asset.("empty.pdf"))
    Page.close!(page)
  end

  @tag skip: "not ported: route, APIRequestContext"
  test "should be able to download a inline PDF file via response interception"

  test "should be able to download a inline PDF file via navigation", %{
    browser: browser,
    server: server,
    asset: asset
  } do
    # it.skip(browserName === 'chromium' && !isHeadlessShell, ...)  -- headless chromium is the headless shell
    page = Browser.new_page!(browser)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(\n    <a href="/empty.pdf">open</a>\n  ))
    download = click_download(page)
    assert_download_to_pdf(download, asset.("empty.pdf"))
    Page.close!(page)
  end

  @tag :tmp_dir
  test "should save to user-specified path", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    TestServer.set_route(server, "/download", &send_attachment(&1, "Hello world"))

    page = Browser.new_page!(browser)
    Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
    download = click_download(page)
    user_path = Path.join(tmp_dir, "download.txt")
    Download.save_as!(download, user_path)
    assert File.exists?(user_path)
    assert File.read!(user_path) == "Hello world"
    Page.close!(page)
  end

  test ~s(should download even if there is no "attachment" value), %{browser: browser, server: server} do
    # Do not set the "attachment" value.
    TestServer.set_route(server, "/download", &send_attachment(&1, "Hello world", "filename=foo.txt"))

    page = Browser.new_page!(browser)
    Page.set_content!(page, ~s(<a href="#{server.prefix}/download">download</a>))
    click_download(page)
    Page.close!(page)
  end

  test "should convert navigation to a resource with unsupported mime type into download", %{
    browser: browser,
    server: server
  } do
    TestServer.set_route(server, "/download", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.send_resp(200, "Hello world")
    end)

    page = Browser.new_page!(browser)
    Page.expect_download!(page, fn -> Page.goto(page, "#{server.prefix}/download") end)
    Page.close!(page)
  end

  @tag :page
  test "should download links with data url", %{page: page} do
    Page.set_content!(
      page,
      ~s(<a download="SomeFile.txt" href="data:text/plain;charset=utf8;,hello world">Download!</a>)
    )

    download_promise = Page.wait_for_event(page, :download)
    Locator.click!(Page.get_by_text(page, "Download"))
    download = Promise.await!(download_promise)
    assert Download.suggested_filename(download) == "SomeFile.txt"
  end

  @tag skip: "not ported: route"
  test "should download successfully when routing"

  defp assert_download_to_pdf(download, file_path) do
    assert Download.suggested_filename(download) == Path.basename(file_path)
    stream = Download.create_read_stream!(download)
    data = stream |> Enum.to_list() |> IO.iodata_to_binary()
    assert String.ends_with?(Download.url(download), "/" <> Path.basename(file_path))
    expected_prefix = "%PDF"
    assert binary_part(data, 0, byte_size(expected_prefix)) == expected_prefix
    assert_buffer(data, File.read!(file_path))
  end

  defp assert_buffer(expected, actual) do
    assert byte_size(expected) == byte_size(actual)
    assert expected == actual
  end

  # Promise.all([...]) of calls that run concurrently.
  defp await_all(funs), do: funs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 30_000))

  defp webkit_on_linux?, do: System.get_env("BROWSER") == "webkit" and :os.type() == {:unix, :linux}
end
