defmodule PlaywrightEx.Library.BrowsertypeLaunchTest do
  @upstream "tests/library/browsertype-launch.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page

  test "should reject all promises when browser is closed", %{browser_type: browser_type} do
    browser = BrowserType.launch!(browser_type)
    page = BrowserContext.new_page!(Browser.new_context!(browser))
    never_resolves = Task.async(fn -> Page.evaluate(page, "() => new Promise(r => {})") end)
    Page.evaluate!(page, "() => new Promise(f => window.builtins.setTimeout(f, 0))")
    Browser.close!(browser)
    {:error, error} = Task.await(never_resolves)
    # WebKit under task-set -c 1 is giving browser, rest are giving target.
    assert Exception.message(error) =~ " closed"
  end

  # `{ userDataDir } as any`: the facade rejects options that are not in the API.
  test "should throw if userDataDir option is passed", %{browser_type: browser_type} do
    wait_error = catch_error(BrowserType.launch(browser_type, user_data_dir: "random-path"))
    assert Exception.message(wait_error) =~ "browserType.launch: unknown option :user_data_dir"
  end

  test "should throw if userDataDir is passed as an argument", %{browser_type: browser_type} do
    {:error, wait_error} =
      BrowserType.launch(browser_type, args: ["--user-data-dir=random-path", "--profile=random-path"])

    assert Exception.message(wait_error) =~ "Pass userDataDir parameter to 'browserType.launchPersistentContext"
  end

  # `{ port: 1234 } as any`: the facade rejects options that are not in the API.
  test "should throw if port option is passed", %{browser_type: browser_type} do
    error = catch_error(BrowserType.launch(browser_type, port: 1234))
    assert Exception.message(error) =~ "browserType.launch: unknown option :port"
  end

  # `{ port: 1234 } as any`: the facade rejects options that are not in the API.
  test "should throw if port option is passed for persistent context", %{browser_type: browser_type} do
    error = catch_error(BrowserType.launch_persistent_context(browser_type, "foo", port: 1234))
    assert Exception.message(error) =~ "browserType.launchPersistentContext: unknown option :port"
  end

  test "should throw if page argument is passed", %{browser_type: browser_type} do
    {:error, wait_error} = BrowserType.launch(browser_type, args: ["http://example.com"])
    assert Exception.message(wait_error) =~ "can not specify page"
  end

  test "should reject if launched browser fails immediately", %{browser_type: browser_type, asset: asset} do
    {:error, error} = BrowserType.launch(browser_type, executable_path: asset.("dummy_bad_browser_executable.js"))
    assert Exception.message(error) =~ ~r/browserType\.launch(.|\n)*(spawn UNKNOWN|spawn EFTYPE|Browser logs:)/im
  end

  test "should reject if executable path is invalid", %{browser_type: browser_type} do
    {:error, wait_error} = BrowserType.launch(browser_type, executable_path: "random-invalid-path")
    assert Exception.message(wait_error) =~ "Failed to launch"
  end

  @tag skip: "not ported: __testHookBeforeCreateBrowser is a JS function"
  test "should handle timeout"

  @tag skip: "not ported: __testHookBeforeCreateBrowser is a JS function"
  test "should handle exception and report launch log"

  @tag skip: "not ported: `process` is not a launch option (@ts-expect-error), the facade rejects it"
  test "should accept objects as options"

  test "should fire close event for all contexts", %{browser_type: browser_type} do
    browser = BrowserType.launch!(browser_type)
    context = Browser.new_context!(browser)
    test = self()
    BrowserContext.on(context, :close, fn _ -> send(test, :closed) end)
    Browser.close!(browser)
    assert_received :closed
  end

  test "should be callable twice", %{browser_type: browser_type} do
    browser = BrowserType.launch!(browser_type)
    Task.await_many([Task.async(fn -> Browser.close!(browser) end), Task.async(fn -> Browser.close!(browser) end)])
    Browser.close!(browser)
    refute Browser.is_connected(browser)
  end

  @tag skip: "not ported: await using"
  test "should allow await using"
end
