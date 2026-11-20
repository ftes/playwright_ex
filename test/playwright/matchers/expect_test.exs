defmodule Playwright.Matchers.ExpectTest do
  use ExUnit.Case, async: true

  alias Playwright.Matchers.Expect

  test "unknown keys of the app env config raise, naming the valid ones" do
    assert_raise ArgumentError,
                 ~r/^config :playwright, :expect: unknown key timout, expected one of timeout, /,
                 fn -> Expect.app_env_expect_config(timout: 1_000) end
  end

  test "the app env config is an ExpectConfig, the matchers' options snake_case" do
    assert Expect.app_env_expect_config([]) == %{testInfo: nil, ignoreSnapshots: false, updateSnapshots: "default"}

    assert Expect.app_env_expect_config(
             timeout: :infinity,
             update_snapshots: :missing,
             ignore_snapshots: true,
             to_have_screenshot: [max_diff_pixels: 10, animations: :allow, type: :webp, path_template: "{arg}{ext}"],
             to_match_aria_snapshot: %{children: :deep_equal, path_template: "{arg}{ext}"},
             to_pass: [timeout: 1_000, intervals: [50]]
           ) == %{
             testInfo: nil,
             timeout: 0,
             updateSnapshots: "missing",
             ignoreSnapshots: true,
             toHaveScreenshot: %{maxDiffPixels: 10, animations: "allow", type: "webp", pathTemplate: "{arg}{ext}"},
             toMatchAriaSnapshot: %{children: "deep-equal", pathTemplate: "{arg}{ext}"},
             toPass: %{timeout: 1_000, intervals: [50]}
           }
  end

  test "a matcher's config: upstream's keys, snake_case; others raise" do
    assert_raise ArgumentError,
                 ~r/^config :playwright, :expect, :to_have_screenshot: unknown key maxDiffPixels, /,
                 fn ->
                   Expect.app_env_expect_config(to_have_screenshot: %{maxDiffPixels: 10})
                 end

    assert_raise ArgumentError,
                 ~r/^config :playwright, :expect, :to_have_screenshot: unknown key mask, /,
                 fn ->
                   Expect.app_env_expect_config(to_have_screenshot: [mask: []])
                 end

    # Upstream's validateConfig and validateProject check these values.
    for value <- [:all, :changed, :missing, :none, :default, "missing"],
        do: assert(Expect.app_env_expect_config(update_snapshots: value).updateSnapshots == to_string(value))

    assert_raise ArgumentError,
                 "config :playwright, :expect: invalid value :always for update_snapshots, expected one of :all, :changed, :missing, :none, :default",
                 fn -> Expect.app_env_expect_config(update_snapshots: :always) end

    assert_raise ArgumentError,
                 "config :playwright, :expect: invalid value \"yes\" for ignore_snapshots, expected a boolean",
                 fn -> Expect.app_env_expect_config(ignore_snapshots: "yes") end

    assert_raise ArgumentError,
                 "config :playwright, :expect, :to_have_screenshot: invalid value :gif for type, expected one of :png, :webp",
                 fn -> Expect.app_env_expect_config(to_have_screenshot: [type: :gif]) end

    assert Expect.app_env_expect_config(to_match_aria_snapshot: [children: :all]).toMatchAriaSnapshot == %{
             children: "all"
           }
  end

  test "to_pass: a timeout of :infinity is 0, as :timeout's; other values raise" do
    assert Expect.app_env_expect_config(to_pass: [timeout: :infinity]).toPass == %{timeout: 0}
    assert Expect.app_env_expect_config(to_pass: %{intervals: [50]}).toPass == %{intervals: [50]}

    assert_raise ArgumentError,
                 "config :playwright, :expect, :to_pass: expected a keyword list or a map with atom keys, got: 5000",
                 fn -> Expect.app_env_expect_config(to_pass: 5000) end

    assert_raise ArgumentError, ~r/^config :playwright, :expect, :to_pass: unknown key timout, /, fn ->
      Expect.app_env_expect_config(to_pass: [timout: 1_000])
    end

    assert_raise ArgumentError,
                 ~s(config :playwright, :expect, :to_pass: expected a keyword list or a map with atom keys, got: %{"timeout" => 1}),
                 fn -> Expect.app_env_expect_config(to_pass: %{"timeout" => 1}) end
  end

  test "test_helper sets the timeout through the app env" do
    assert Expect.expect_config().timeout == 10_000
  end
end
