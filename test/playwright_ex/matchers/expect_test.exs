defmodule PlaywrightEx.Matchers.ExpectTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Matchers.Expect

  test "unknown keys of the app env config raise, naming the valid ones" do
    assert_raise ArgumentError,
                 ~r/^config :playwright_ex, :expect: unknown keys \[:timout\], expected one of \[:timeout, /,
                 fn -> Expect.app_env_expect_config(timout: 1_000) end
  end

  test "the app env config is an ExpectConfig" do
    assert Expect.app_env_expect_config([]) == %{testInfo: nil, ignoreSnapshots: false, updateSnapshots: "default"}

    assert Expect.app_env_expect_config(
             timeout: :infinity,
             update_snapshots: :missing,
             ignore_snapshots: true,
             to_have_screenshot: %{maxDiffPixels: 10},
             to_match_aria_snapshot: %{children: "equal"}
           ) == %{
             testInfo: nil,
             timeout: 0,
             updateSnapshots: "missing",
             ignoreSnapshots: true,
             toHaveScreenshot: %{maxDiffPixels: 10},
             toMatchAriaSnapshot: %{children: "equal"}
           }
  end

  test "test_helper sets the timeout through the app env" do
    assert Expect.expect_config().timeout == 10_000
  end
end
