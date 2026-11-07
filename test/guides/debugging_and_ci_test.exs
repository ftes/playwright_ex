defmodule PlaywrightEx.Guides.DebuggingAndCiTest do
  # The snippets of `guides/debugging-and-ci.md`. Not run: `show-trace` and the headed launch
  # (they open windows), the GitHub Actions and Docker files. The remote browser runs the
  # driver's `run-server` locally instead of in the Docker image.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.RemoteServer.RunServer
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.TimeoutError
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Video
  alias PlaywrightEx.WebError

  require Logger

  @moduletag :tmp_dir

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    playwright = PlaywrightEx.playwright(__MODULE__)
    browser = playwright |> TestBrowser.browser_type() |> BrowserType.launch!()
    %{playwright: playwright, browser: browser}
  end

  setup %{browser: browser} do
    context = Browser.new_context!(browser)
    on_exit(fn -> BrowserContext.close(context) end)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, ~s(<button>Cancel</button><div role="dialog">Hi</div>))
    %{context: context, page: page}
  end

  test "errors and call logs", %{page: page} do
    assert {:error, %TimeoutError{} = error} =
             Page.get_by_role(page, :button, name: "Save") |> Locator.click(timeout: 1_000)

    assert error.message =~ "locator.click: Timeout 1000ms exceeded."
    assert error.message =~ "Call log:\n  - waiting for getByRole('button', { name: 'Save' })"
    assert [_ | _] = error.log

    error =
      assert_raise PlaywrightEx.ExpectError, fn ->
        Expect.to_have_text!(Page.get_by_role(page, :button), "Save", timeout: 100)
      end

    assert Exception.message(error) =~ "Call log:"
  end

  test "traces", %{context: context, page: page, tmp_dir: tmp_dir} do
    tracing = BrowserContext.tracing(context)
    Tracing.start!(tracing, screenshots: true, snapshots: true, sources: true)
    Tracing.group!(tracing, "cancel")
    Page.get_by_role(page, :button, name: "Cancel") |> Locator.click!()
    Tracing.group_end!(tracing)
    Tracing.stop!(tracing, path: Path.join(tmp_dir, "trace.zip"))
    assert File.exists?(Path.join(tmp_dir, "trace.zip"))
  end

  test "screenshots and videos", %{browser: browser, page: page, tmp_dir: tmp_dir} do
    Page.screenshot!(page, path: Path.join(tmp_dir, "page.png"), full_page: true)
    Page.get_by_role(page, :dialog) |> Locator.screenshot!(path: Path.join(tmp_dir, "dialog.png"))
    assert File.exists?(Path.join(tmp_dir, "page.png")) and File.exists?(Path.join(tmp_dir, "dialog.png"))
    assert <<0x89, "PNG", _::binary>> = Page.screenshot!(page)

    context = Browser.new_context!(browser, record_video: %{dir: Path.join(tmp_dir, "videos")})
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<p>Recorded</p>")
    BrowserContext.close!(context)
    assert Page.video(page) |> Video.path!() |> File.exists?()
  end

  @tag capture_log: true
  test "console and page errors", %{context: context, page: page} do
    log =
      capture_log(fn ->
        BrowserContext.on(
          context,
          :console,
          &Logger.info("console.#{ConsoleMessage.type(&1)}: #{ConsoleMessage.text(&1)}")
        )

        BrowserContext.on(context, :web_error, &Logger.error(Exception.message(WebError.error(&1))))

        test_pid = self()
        Page.on(page, :page_error, &send(test_pid, {:page_error, &1}))
        Page.evaluate!(page, "() => { console.warn('careful'); setTimeout(() => { throw new Error('boom') }) }")
        assert_receive {:page_error, %{message: "boom"}}, 5_000
        # Both listeners ran before the page error's listener got to send.
        Logger.flush()
      end)

    assert log =~ "console.warning: careful"
    assert log =~ "boom"
  end

  test "the driver's environment" do
    start_supervised!({PlaywrightEx.Supervisor, name: :"#{__MODULE__}.Debug", env: [{"DEBUG", "pw:none"}]})
    assert %Playwright{} = PlaywrightEx.playwright(:"#{__MODULE__}.Debug")
  end

  test "remote browsers", %{playwright: playwright} do
    server = RunServer.start()
    on_exit(fn -> RunServer.close(server) end)
    browser_type = TestBrowser.browser_type(playwright)

    browser = BrowserType.connect!(browser_type, RunServer.ws_endpoint(server), expose_network: "<loopback>")
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<title>Remote</title>")
    Expect.to_have_title!(page, "Remote")
    Browser.close!(browser)
  end

  test "versions match the image tag" do
    assert PlaywrightEx.Driver.version() == "1.65.0"
    guide = File.read!(Path.expand("../../guides/debugging-and-ci.md", __DIR__))
    assert guide =~ "mcr.microsoft.com/playwright:v#{PlaywrightEx.Driver.version()}-noble"
    assert guide =~ "playwright@#{PlaywrightEx.Driver.version()} run-server"
  end
end
