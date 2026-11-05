defmodule PlaywrightEx.Library.BrowsertypeLaunchSeleniumTest do
  @upstream "tests/library/browsertype-launch-selenium.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.RemoteServer.ChildProcess
  alias PlaywrightEx.Runtime.Facade

  @browser_name System.get_env("BROWSER", "chromium")

  # test.skip(({ mode }) => mode !== 'default', 'Using test hooks'): we run in the default mode.
  # test.skip(!chromeDriver): the tests need `java` on the PATH, PWTEST_SELENIUM (the directory of
  # the Selenium Server jars) and PWTEST_CHROMEDRIVER (a chromedriver for the installed Google
  # Chrome, which it drives). Upstream's installation test downloads them
  # (tests/installation/fixture-scripts/download-{selenium,chromedriver}.js); our CI downloads the
  # jars and takes the runner image's Chrome and ChromeDriver (.github/workflows/elixir.yml).
  @no_selenium if(!System.get_env("PWTEST_CHROMEDRIVER") or !System.get_env("PWTEST_SELENIUM"),
                 do: "upstream skip: needs PWTEST_CHROMEDRIVER, PWTEST_SELENIUM and java (Selenium Grid)"
               )
  @chromium_only if(@browser_name != "chromium", do: "upstream skip: chromium only", else: @no_selenium)

  # test.slow()
  @moduletag timeout: @slow_timeout

  # testInfo.workerIndex: one module is one worker.
  @worker_index 0

  defp chrome_driver, do: System.fetch_env!("PWTEST_CHROMEDRIVER")

  defp standalone_3_141_59,
    do: Path.join(System.fetch_env!("PWTEST_SELENIUM"), "selenium-server-standalone-3.141.59.jar")

  defp selenium_4_8_3, do: Path.join(System.fetch_env!("PWTEST_SELENIUM"), "selenium-server-4.8.3.jar")
  defp broken_driver(asset), do: asset.("selenium-grid/broken-selenium-driver.js")

  defp write_selenium_config(asset, tmp_dir, port) do
    template = asset.("selenium-grid/selenium-config-standalone.json")
    content = String.replace(File.read!(template), "4444", to_string(port))
    file = Path.join(tmp_dir, "selenium-config-standalone.json")
    File.write!(file, content)
    file
  end

  # The childProcess fixture (tests/config/commonFixtures.ts): the children are killed after the test.
  defp child_process([program | args]) do
    process = ChildProcess.start(System.find_executable(program) || program, args)

    # Upstream SIGKILLs the process group (killProcessGroup): the chromedriver that Selenium 3 keeps
    # running after the session, and its browser, go too. Here: the process and its descendants.
    on_exit(fn ->
      pid = ChildProcess.pid(process)
      System.cmd("kill", ["-9" | Enum.map([pid | descendants(pid)], &to_string/1)], stderr_to_stdout: true)
      ChildProcess.stop(process)
    end)

    process
  end

  defp descendants(pid) do
    {out, _} = System.cmd("pgrep", ["-P", to_string(pid)])
    children = Enum.map(String.split(out), &String.to_integer/1)
    children ++ Enum.flat_map(children, &descendants/1)
  end

  defp output(process), do: ChildProcess.output(process)

  defp wait_for_output(process, substring) do
    ChildProcess.await(process, fn output -> if String.contains?(output, substring), do: {:ok, :ok} end)
  end

  # The waitForPort fixture (tests/config/commonFixtures.ts).
  defp wait_for_port(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _} ->
        Process.sleep(100)
        wait_for_port(port)
    end
  end

  # browserType.launch({ __testHookSeleniumRemoteURL } as any): the facade rejects the hook, so the
  # client is called (as Python's launch_test_hook adds it to the launch message). The client
  # sends __testHook* parameters when under test, as upstream's validator does. The driver passes
  # the launch's default args (`--headless` included) in goog:chromeOptions: Chrome runs headless.
  defp launch(browser_type, test_hook_selenium_remote_url) do
    Facade.async("browserType.launch", browser_type, fn ->
      PlaywrightEx.Client.BrowserType.launch(browser_type, %{__testHookSeleniumRemoteURL: test_hook_selenium_remote_url})
    end)
  end

  @tag :tmp_dir
  @tag skip: @chromium_only
  test "selenium grid 3.141.59 standalone chromium", %{browser_type: browser_type, asset: asset, tmp_dir: tmp_dir} do
    port = @worker_index * 5 + 15_123

    grid =
      child_process([
        "java",
        "-Dwebdriver.chrome.driver=#{chrome_driver()}",
        "-jar",
        standalone_3_141_59(),
        "-config",
        write_selenium_config(asset, tmp_dir, port)
      ])

    wait_for_port(port)

    test_hook_selenium_remote_url = "http://127.0.0.1:#{port}/wd/hub"
    {:ok, browser} = launch(browser_type, test_hook_selenium_remote_url)
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<title>Hello world</title><div>Get Started</div>")
    Page.click!(page, "text=Get Started")
    Expect.to_have_title!(page, "Hello world")
    Browser.close!(browser)

    assert output(grid) =~ "Starting ChromeDriver"
    assert output(grid) =~ "Started new session"
    wait_for_output(grid, "Removing session")
  end

  @tag skip: @chromium_only
  test "selenium grid 3.141.59 hub + node chromium", %{browser_type: browser_type} do
    port = @worker_index * 5 + 15_123
    hub = child_process(["java", "-jar", standalone_3_141_59(), "-role", "hub", "-port", to_string(port)])
    wait_for_port(port)

    node =
      child_process([
        "java",
        "-Dwebdriver.chrome.driver=#{chrome_driver()}",
        "-jar",
        standalone_3_141_59(),
        "-role",
        "node",
        "-host",
        "127.0.0.1",
        "-hub",
        "http://127.0.0.1:#{port}/grid/register"
      ])

    wait_for_output(node, "The node is registered to the hub and ready to use")
    wait_for_output(hub, "Registered a node")

    test_hook_selenium_remote_url = "http://127.0.0.1:#{port}/wd/hub"
    {:ok, browser} = launch(browser_type, test_hook_selenium_remote_url)
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<title>Hello world</title><div>Get Started</div>")
    Page.click!(page, "text=Get Started")
    Expect.to_have_title!(page, "Hello world")
    Browser.close!(browser)

    assert output(hub) =~ "Got a request to create a new session"
    assert output(node) =~ "Starting ChromeDriver"
    assert output(node) =~ "Started new session"
    wait_for_output(node, "Removing session")
  end

  @tag :tmp_dir
  @tag skip: @chromium_only
  test "selenium grid 4.8.3 standalone chromium", %{browser_type: browser_type, asset: asset, tmp_dir: tmp_dir} do
    port = @worker_index * 5 + 15_123

    grid =
      child_process([
        "java",
        "-Dwebdriver.chrome.driver=#{chrome_driver()}",
        "-jar",
        selenium_4_8_3(),
        "standalone",
        "--config",
        write_selenium_config(asset, tmp_dir, port)
      ])

    wait_for_port(port)

    test_hook_selenium_remote_url = "http://127.0.0.1:#{port}/"
    {:ok, browser} = launch(browser_type, test_hook_selenium_remote_url)
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<title>Hello world</title><div>Get Started</div>")
    Page.click!(page, "text=Get Started")
    Expect.to_have_title!(page, "Hello world")
    Browser.close!(browser)

    assert output(grid) =~ "Starting ChromeDriver"
    assert output(grid) =~ "Session created"
    wait_for_output(grid, "Deleted session")
  end

  @tag skip: @chromium_only
  test "selenium grid 4.8.3 hub + node chromium", %{browser_type: browser_type} do
    port = @worker_index * 5 + 15_123
    hub = child_process(["java", "-jar", selenium_4_8_3(), "hub", "--port", to_string(port)])
    wait_for_port(port)
    test_hook_selenium_remote_url = "http://127.0.0.1:#{port}/"

    node =
      child_process([
        "java",
        "-Dwebdriver.chrome.driver=#{chrome_driver()}",
        "-jar",
        selenium_4_8_3(),
        "node",
        "--grid-url",
        "http://127.0.0.1:#{port}",
        "--port",
        to_string(port + 1)
      ])

    wait_for_output(node, "Node has been added")
    wait_for_output(hub, "from DOWN to UP")

    {:ok, browser} = launch(browser_type, test_hook_selenium_remote_url)
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<title>Hello world</title><div>Get Started</div>")
    Page.click!(page, "text=Get Started")
    Expect.to_have_title!(page, "Hello world")
    Browser.close!(browser)

    assert String.downcase(output(hub)) =~ "session request received by the distributor"
    assert output(node) =~ "Starting ChromeDriver"
    wait_for_output(hub, "Deleted session")
  end

  @tag :tmp_dir
  @tag skip: @chromium_only
  test "selenium grid 4.8.3 standalone chromium broken driver", %{
    browser_type: browser_type,
    asset: asset,
    tmp_dir: tmp_dir
  } do
    port = @worker_index * 5 + 15_123

    grid =
      child_process([
        "java",
        "-Dwebdriver.chrome.driver=#{broken_driver(asset)}",
        "-jar",
        selenium_4_8_3(),
        "standalone",
        "--config",
        write_selenium_config(asset, tmp_dir, port)
      ])

    wait_for_port(port)

    test_hook_selenium_remote_url = "http://127.0.0.1:#{port}/"
    {:error, error} = launch(browser_type, test_hook_selenium_remote_url)

    assert Exception.message(error) =~
             "Error connecting to Selenium at http://127.0.0.1:#{port}/session: Could not start a new session"

    refute output(grid) =~ "Starting ChromeDriver"
  end

  @tag skip: if(@browser_name == "chromium", do: "upstream skip: not chromium", else: @no_selenium)
  test "selenium grid 3.141.59 standalone non-chromium", %{browser_type: browser_type} do
    test_hook_selenium_remote_url = "http://127.0.0.1:4444/wd/hub"
    {:error, error} = launch(browser_type, test_hook_selenium_remote_url)
    assert Exception.message(error) =~ "Connecting to SELENIUM_REMOTE_URL is only supported by Chromium"
  end

  @tag :tmp_dir
  @tag skip: @chromium_only
  test "selenium grid 3.141.59 standalone chromium through run-driver", %{asset: asset, tmp_dir: tmp_dir} do
    port = @worker_index * 5 + 15_123

    grid =
      child_process([
        "java",
        "-Dwebdriver.chrome.driver=#{chrome_driver()}",
        "-jar",
        standalone_3_141_59(),
        "-config",
        write_selenium_config(asset, tmp_dir, port)
      ])

    wait_for_port(port)

    # oop.start({ SELENIUM_REMOTE_URL }): a driver of its own with that env (upstream's test process
    # env, PWTEST_UNDER_TEST included, plus SELENIUM_REMOTE_URL).
    name = :selenium_run_driver

    start_supervised!(
      {PlaywrightEx.Supervisor,
       name: name, env: [{"PWTEST_UNDER_TEST", "1"}, {"SELENIUM_REMOTE_URL", "http://127.0.0.1:#{port}/wd/hub"}]},
      id: name
    )

    pw = PlaywrightEx.playwright(name)
    browser = BrowserType.launch!(Playwright.chromium(pw))
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<title>Hello world</title><div>Get Started</div>")
    Page.click!(page, "text=Get Started")
    Expect.to_have_title!(page, "Hello world")
    # Note: it is important to stop the driver without explicitly closing the browser.
    # It should terminate selenium session in this case.
    stop_supervised!(name)

    assert output(grid) =~ "Starting ChromeDriver"
    assert output(grid) =~ "Started new session"
    # It is important that selenium session is terminated.
    wait_for_output(grid, "Removing session")
  end
end
