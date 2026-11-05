defmodule PlaywrightEx.Library.Chromium.LauncherTest do
  @upstream "tests/library/chromium/launcher.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.CDPSession

  @moduletag skip: if(System.get_env("BROWSER", "chromium") != "chromium", do: "upstream skip: Chromium only")

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should throw with remote-debugging-pipe argument"

  @tag skip: "not ported: launchServer (PLAN: out of scope)"
  test "should not throw with remote-debugging-port argument"

  test "should not create pages automatically", %{browser_type: browser_type} do
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
