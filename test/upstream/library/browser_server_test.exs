defmodule PlaywrightEx.Library.BrowserServerTest do
  @upstream "tests/library/browser-server.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.Utils

  # it.skip(({ mode }) => mode !== 'default')  -- always default mode

  # it.beforeEach: process.env.PWTEST_SERVER_REGISTRY = testInfo.outputPath('registry'). The
  # driver is another process, so a driver of its own started with it, and a `browser` launched
  # on that driver (stopping the driver closes it).
  setup %{test: test} do
    output_dir = Path.join(System.tmp_dir!(), "playwright-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(output_dir) end)
    registry_dir = Path.join(output_dir, "registry")

    browser_type = TestBrowser.browser_type(start_playwright(test, [{"PWTEST_SERVER_REGISTRY", registry_dir}]))
    browser = BrowserType.launch!(browser_type)
    %{browser_type: browser_type, browser: browser, registry_dir: registry_dir}
  end

  test "should start and stop pipe server", %{browser_type: browser_type, browser: browser} do
    server_info = Browser.bind!(browser, "default")
    assert server_info.endpoint =~ ~r/browser-/

    browser2 = BrowserType.connect!(browser_type, server_info.endpoint)
    page = Browser.new_page!(browser2)
    Page.goto!(page, "data:text/html,<h1>Hello via pipe</h1>")
    assert Locator.text_content!(Page.locator(page, "h1")) == "Hello via pipe"
    Page.close!(page)
    Browser.close!(browser2)
    Browser.unbind!(browser)
  end

  test "should write descriptor on start and remove on stop", %{browser: browser, registry_dir: registry_dir} do
    # `{ wsPath: 'test' } as any`: not a startServer param, the client's validator drops it.
    server_info = Browser.bind!(browser, "my-title")

    [file_name | _] = File.ls!(registry_dir)
    file = Path.join(registry_dir, file_name)

    descriptor = file |> File.read!() |> JSON.decode!()
    assert descriptor["title"] == "my-title"
    Utils.assert_truthy(descriptor["playwrightVersion"])
    Utils.assert_truthy(descriptor["playwrightLib"])
    Utils.assert_truthy(descriptor["browser"]["browserName"])
    assert descriptor["endpoint"] == server_info.endpoint

    # process.platform !== 'win32'  -- no Windows
    assert File.exists?(server_info.endpoint)

    Browser.unbind!(browser)
    refute File.exists?(file)
    refute File.exists?(server_info.endpoint)
  end

  test "should start ws server with host/port and produce well-formed endpoint", %{
    browser_type: browser_type,
    browser: browser
  } do
    server_info = Browser.bind!(browser, "default", host: "localhost", port: 0)
    assert server_info.endpoint =~ ~r/^ws:\/\/(127\.0\.0\.1|\[::1\]):\d+\/[a-f0-9]+$/

    browser2 = BrowserType.connect!(browser_type, server_info.endpoint)
    page = Browser.new_page!(browser2)
    Page.goto!(page, "data:text/html,<h1>Hello via ws</h1>")
    assert Locator.text_content!(Page.locator(page, "h1")) == "Hello via ws"
    Page.close!(page)
    Browser.close!(browser2)
    Browser.unbind!(browser)
  end
end
