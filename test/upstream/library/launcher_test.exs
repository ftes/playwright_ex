defmodule PlaywrightEx.Library.LauncherTest do
  @upstream "tests/library/launcher.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Playwright

  test "BT-018 should have an errors object", %{playwright: playwright} do
    assert inspect(Playwright.errors(playwright)."TimeoutError") =~ "TimeoutError"
  end

  test "BT-019 should have a devices object", %{playwright: playwright} do
    assert Playwright.devices(playwright)["iPhone 6"]
    assert Playwright.devices(playwright)["iPhone 6"].default_browser_type == "webkit"
  end

  test "BT-020 should kill browser process on timeout after close"

  if !match?({:unix, :linux}, :os.type()), do: @tag(skip: "upstream skip: linux only")
  @tag :headed

  test "BT-021 should throw a friendly error if its headed and there is no xserver on linux running", %{
    browser_type: browser_type
  } do
    {:error, error} =
      PlaywrightEx.BrowserType.launch(browser_type, headless: false, env: Map.delete(System.get_env(), "DISPLAY"))

    assert is_exception(error)
    assert Exception.message(error) =~ ~r/Looks like you launched a headed browser without having a XServer running./
    assert Exception.message(error) =~ ~r/xvfb-run/
  end
end
