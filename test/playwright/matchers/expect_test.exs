defmodule Playwright.Matchers.ExpectTest do
  use ExUnit.Case, async: true

  alias Playwright.Matchers.Expect

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
             to_match_aria_snapshot: %{children: "equal"},
             to_pass: [timeout: 1_000, intervals: [50]]
           ) == %{
             testInfo: nil,
             timeout: 0,
             updateSnapshots: "missing",
             ignoreSnapshots: true,
             toHaveScreenshot: %{maxDiffPixels: 10},
             toMatchAriaSnapshot: %{children: "equal"},
             toPass: %{timeout: 1_000, intervals: [50]}
           }
  end

  test "to_pass: a timeout of :infinity is 0, as :timeout's; other values raise" do
    assert Expect.app_env_expect_config(to_pass: [timeout: :infinity]).toPass == %{timeout: 0}
    assert Expect.app_env_expect_config(to_pass: %{intervals: [50]}).toPass == %{intervals: [50]}

    assert_raise ArgumentError,
                 ~r/^config :playwright_ex, :expect, :to_pass: expected a keyword list or map with the keys \[:timeout, :intervals\], got: 5000/,
                 fn -> Expect.app_env_expect_config(to_pass: 5000) end

    assert_raise ArgumentError, ~r/^config :playwright_ex, :expect, :to_pass: .*got: \[timout: 1000\]/, fn ->
      Expect.app_env_expect_config(to_pass: [timout: 1_000])
    end
  end

  test "test_helper sets the timeout through the app env" do
    assert Expect.expect_config().timeout == 10_000
  end
end
