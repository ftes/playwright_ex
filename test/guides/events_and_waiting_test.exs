defmodule PlaywrightEx.Guides.EventsAndWaitingTest do
  # The snippets of `guides/events-and-waiting.md`, against `PlaywrightEx.TestServer`.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Download
  alias PlaywrightEx.Expect
  alias PlaywrightEx.FileChooser
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.TestServer

  @moduletag :tmp_dir

  @home """
  <title>Home</title>
  <a href="/report.csv">Export</a>
  <button onclick="console.log('not yet'); console.log('saved')">Save</button>
  <button onclick="if (confirm('Sure?')) document.title = 'Deleted'">Delete</button>
  <button onclick="document.title = prompt('Number?')">Pick a number</button>
  <a href="/terms" target="_blank">Open terms</a>
  <input type="file" id="avatar" hidden><button onclick="avatar.click()">Upload avatar</button>
  <a href="/settings">Settings</a>
  """

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    dir = Path.join(System.tmp_dir!(), "guide-events-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    server = TestServer.server(start_supervised!({TestServer, dir_path: dir}))
    TestServer.set_content(server, "/", @home, "text/html")
    TestServer.set_content(server, "/terms", "<title>Terms</title>", "text/html")
    TestServer.set_content(server, "/settings", "<title>Settings</title>", "text/html")

    TestServer.set_route(server, "/report.csv", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="report.csv"))
      |> Plug.Conn.send_resp(200, "a,b")
    end)

    browser = PlaywrightEx.playwright(__MODULE__) |> TestBrowser.browser_type() |> BrowserType.launch!()
    %{browser: browser, base_url: server.prefix}
  end

  setup %{browser: browser, base_url: base_url} do
    context = Browser.new_context!(browser, base_url: base_url)
    BrowserContext.set_default_timeout(context, 5_000)
    on_exit(fn -> BrowserContext.close(context) end)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/")
    %{context: context, page: page}
  end

  test "one event: promise and expect_* forms", %{page: page} do
    promise = Page.wait_for_event(page, :download)
    Page.get_by_text(page, "Export") |> Locator.click!()
    download = Promise.await!(promise)
    assert Download.suggested_filename(download) == "report.csv"

    download = Page.expect_download!(page, fn -> Page.get_by_text(page, "Export") |> Locator.click!() end)
    assert Download.suggested_filename(download) == "report.csv"

    Page.evaluate!(page, "() => { setTimeout(() => console.log('later'), 100) }")
    assert ConsoleMessage.text(Page.wait_for_event!(page, :console)) == "later"

    save = fn -> Page.get_by_role(page, :button, name: "Save") |> Locator.click!() end
    message = Page.expect_console_message!(page, save, predicate: &(ConsoleMessage.text(&1) == "saved"), timeout: 1_000)

    assert ConsoleMessage.text(message) == "saved"
  end

  test "listeners", %{page: page} do
    test_pid = self()
    listener = fn request -> send(test_pid, {:request, Request.method(request), Request.url(request)}) end

    Page.on(page, :request, listener)
    Page.goto!(page, "/")
    assert_receive {:request, "GET", _url}, 1_000
    Page.off(page, :request, listener)

    Page.reload!(page)
    refute_received {:request, _, _}
  end

  test "dialogs", %{page: page} do
    # No listener: dismissed.
    Page.get_by_role(page, :button, name: "Delete") |> Locator.click!()
    Expect.to_have_title!(page, "Home")

    Page.on(page, :dialog, &Dialog.accept/1)
    Page.get_by_role(page, :button, name: "Delete") |> Locator.click!()
    Expect.to_have_title!(page, "Deleted")
    Page.remove_all_listeners!(page, :dialog)

    Page.once(page, :dialog, &Dialog.accept(&1, "42"))
    Page.get_by_role(page, :button, name: "Pick a number") |> Locator.click!()
    Expect.to_have_title!(page, "42")
  end

  test "downloads", %{page: page, tmp_dir: dir} do
    download = Page.expect_download!(page, fn -> Page.get_by_text(page, "Export") |> Locator.click!() end)
    assert Download.suggested_filename(download) == "report.csv"
    Download.save_as!(download, Path.join(dir, Download.suggested_filename(download)))
    assert File.read!(Path.join(dir, "report.csv")) == "a,b"
    assert File.read!(Download.path!(download)) == "a,b"
  end

  test "popups and new pages", %{context: context, page: page} do
    test_pid = self()
    BrowserContext.on(context, :page, &send(test_pid, {:page, &1}))

    popup = Page.expect_popup!(page, fn -> Page.get_by_text(page, "Open terms") |> Locator.click!() end)
    Expect.to_have_title!(popup, "Terms")
    assert_receive {:page, ^popup}, 1_000
  end

  test "file choosers", %{page: page} do
    png = "fake png"

    chooser = Page.expect_file_chooser!(page, fn -> Page.get_by_text(page, "Upload avatar") |> Locator.click!() end)
    FileChooser.set_files!(chooser, %{name: "avatar.png", mimeType: "image/png", buffer: png})

    assert Page.evaluate!(page, "avatar.files[0].name") == "avatar.png"
  end

  test "navigations", %{page: page} do
    Page.get_by_role(page, :link, name: "Settings") |> Locator.click!()
    Expect.to_have_url!(page, ~r"/settings$")

    Page.go_back!(page)
    Page.get_by_role(page, :link, name: "Settings") |> Locator.click!()
    Page.wait_for_url!(page, "**/settings")
    Page.wait_for_load_state!(page)
  end
end
