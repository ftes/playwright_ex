defmodule PlaywrightEx.Library.Chromium.LauncherTest do
  @upstream "tests/library/chromium/launcher.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.CDPSession
  alias PlaywrightEx.RemoteServer.LaunchServer

  @moduletag skip: if(System.get_env("BROWSER", "chromium") != "chromium", do: "upstream skip: Chromium only")

  # `browserType.launchServer(options)` is the `launch_server` fixture (the driver's
  # `launch-server` command); it.skip(mode !== 'default')  -- always default mode.

  test "CR-033 should throw with remote-debugging-pipe argument", %{launch_server: launch_server} do
    options = %{}
    options = Map.put(options, :args, ["--remote-debugging-pipe"] ++ (options[:args] || []))
    {:error, error} = launch_server.(options)
    assert error =~ "Playwright manages remote debugging connection itself"
  end

  test "CR-034 should not throw with remote-debugging-port argument", %{launch_server: launch_server} do
    options = %{}
    options = Map.put(options, :args, ["--remote-debugging-port=0"] ++ (options[:args] || []))
    {:ok, browser} = launch_server.(options)
    LaunchServer.close(browser)
  end

  test "CR-035 should not create pages automatically", %{browser_type: browser_type} do
    test = self()
    browser = BrowserType.launch!(browser_type)
    browser_session = Browser.new_browser_cdp_session!(browser)

    CDPSession.on(browser_session, "Target.targetCreated", fn %{"targetInfo" => target_info} ->
      if target_info["type"] != "browser", do: send(test, {:target, target_info})
    end)

    CDPSession.send!(browser_session, "Target.setDiscoverTargets", %{discover: true})
    Browser.new_context!(browser)
    Browser.close!(browser)
    refute_received {:target, _}
  end
end
