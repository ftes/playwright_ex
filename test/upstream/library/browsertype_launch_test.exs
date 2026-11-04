defmodule PlaywrightEx.Library.BrowsertypeLaunchTest do
  @upstream "tests/library/browsertype-launch.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.Browser

  @tag skip: "not ported: Page"
  test "should reject all promises when browser is closed"

  test "should throw if userDataDir option is passed", %{browser_type: browser_type} do
    wait_error = catch_error(launch(browser_type, %{userDataDir: "random-path"}))

    assert Exception.message(wait_error) =~
             "userDataDir option is not supported in `browserType.launch`. Use `browserType.launchPersistentContext` instead"
  end

  test "should throw if userDataDir is passed as an argument", %{browser_type: browser_type} do
    wait_error = catch_error(launch(browser_type, %{args: ["--user-data-dir=random-path", "--profile=random-path"]}))

    # The driver words this for sdkLanguage "python" (upstream: "Pass userDataDir parameter to 'browserType.launchPersistentContext").
    assert Exception.message(wait_error) =~ "Pass user_data_dir parameter to 'browser_type.launch_persistent_context"
  end

  test "should throw if port option is passed", %{browser_type: browser_type} do
    error = catch_error(launch(browser_type, %{port: 1234}))
    assert Exception.message(error) =~ "Cannot specify a port without launching as a server."
  end

  @tag skip: "not ported: launchPersistentContext"
  test "should throw if port option is passed for persistent context"

  test "should throw if page argument is passed", %{browser_type: browser_type} do
    wait_error = catch_error(launch(browser_type, %{args: ["http://example.com"]}))
    assert Exception.message(wait_error) =~ "can not specify page"
  end

  test "should reject if launched browser fails immediately", %{browser_type: browser_type, asset: asset} do
    error = catch_error(launch(browser_type, %{executablePath: asset.("dummy_bad_browser_executable.js")}))
    assert Exception.message(error) =~ ~r/browserType\.launch(.|\n)*(spawn UNKNOWN|spawn EFTYPE|Browser logs:)/im
  end

  test "should reject if executable path is invalid", %{browser_type: browser_type} do
    wait_error = catch_error(launch(browser_type, %{executablePath: "random-invalid-path"}))
    assert Exception.message(wait_error) =~ "Failed to launch"
  end

  @tag skip: "not ported: __testHookBeforeCreateBrowser is a JS function"
  test "should handle timeout"

  @tag skip: "not ported: __testHookBeforeCreateBrowser is a JS function"
  test "should handle exception and report launch log"

  test "should accept objects as options", %{browser_type: browser_type} do
    browser = launch(browser_type, %{process: %{env: System.get_env()}})
    close(browser)
  end

  @tag skip: "not ported: BrowserContext"
  test "should fire close event for all contexts"

  test "should be callable twice", %{browser_type: browser_type} do
    browser = launch(browser_type)
    Task.await_many([Task.async(fn -> close(browser) end), Task.async(fn -> close(browser) end)])
    close(browser)
    refute Browser.is_connected(browser)
  end

  @tag skip: "not ported: await using"
  test "should allow await using"
end
