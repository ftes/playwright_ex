defmodule Playwright.Matchers.ExpectTest do
  use ExUnit.Case, async: true

  alias Playwright.Matchers.Expect

  test "unknown keys of the config's expect raise, naming the valid ones" do
    assert_raise ArgumentError,
                 ~r/^config :playwright, :test: unknown option expect.timout, expected one of timeout, /,
                 fn -> Expect.app_env_expect_config(expect: [timout: 1_000]) end

    assert_raise ArgumentError,
                 "config :playwright, :test: invalid value 5 for expect, expected a keyword list or a map",
                 fn -> Expect.app_env_expect_config(expect: 5) end

    assert_raise ArgumentError,
                 "config :playwright, :test: expected a keyword list, got: :x",
                 fn -> Expect.app_env_expect_config(:x) end
  end

  test "the app env config is an ExpectConfig, the matchers' options snake_case" do
    assert Expect.app_env_expect_config([]) == %{testInfo: nil, ignoreSnapshots: false, updateSnapshots: "default"}

    # The runner's keys are `Playwright.Test.Options`'.
    assert Expect.app_env_expect_config(workers: 2, tracing: :on) == Expect.app_env_expect_config([])

    assert Expect.app_env_expect_config(
             expect: [
               timeout: :infinity,
               to_have_screenshot: [max_diff_pixels: 10, animations: :allow, type: :webp, path_template: "{arg}{ext}"],
               to_match_aria_snapshot: %{children: :deep_equal, path_template: "{arg}{ext}"},
               to_pass: [timeout: 1_000, intervals: [50]]
             ],
             update_snapshots: :missing,
             ignore_snapshots: true
           ) == %{
             testInfo: nil,
             timeout: 0,
             updateSnapshots: "missing",
             ignoreSnapshots: true,
             toHaveScreenshot: %{maxDiffPixels: 10, animations: "allow", type: "webp", pathTemplate: "{arg}{ext}"},
             toMatchAriaSnapshot: %{children: "deep-equal", pathTemplate: "{arg}{ext}"},
             toPass: %{timeout: 1_000, intervals: [50]}
           }

    assert Expect.app_env_expect_config(expect: %{timeout: 1}).timeout == 1
  end

  test "a matcher's config: upstream's keys, snake_case; others raise" do
    assert_raise ArgumentError,
                 ~r/^config :playwright, :test: unknown option expect.to_have_screenshot.maxDiffPixels, /,
                 fn ->
                   Expect.app_env_expect_config(expect: [to_have_screenshot: %{maxDiffPixels: 10}])
                 end

    assert_raise ArgumentError,
                 ~r/^config :playwright, :test: unknown option expect.to_have_screenshot.mask, /,
                 fn ->
                   Expect.app_env_expect_config(expect: [to_have_screenshot: [mask: []]])
                 end

    assert_raise ArgumentError,
                 "config :playwright, :test: invalid value :x for expect.to_have_screenshot.animations, expected one of :allow, :disabled",
                 fn -> Expect.app_env_expect_config(expect: [to_have_screenshot: [animations: :x]]) end

    # Of a duplicated key the later wins, as JS's spread, in the matchers' configs too.
    assert Expect.app_env_expect_config(expect: [timeout: 1, timeout: 2]).timeout == 2
    assert Expect.app_env_expect_config(expect: [timeout: 1], expect: [timeout: 2]).timeout == 2
    assert Expect.app_env_expect_config(expect: [to_pass: [timeout: 1, timeout: 2]]).toPass == %{timeout: 2}
    assert Playwright.Application.options!("x", [a: 1, b: 2, a: 3], [:a, :b]) == [b: 2, a: 3]

    # Upstream's validateConfig and validateProject check these values.
    for value <- [:all, :changed, :missing, :none, :default, "missing"],
        do: assert(Expect.app_env_expect_config(update_snapshots: value).updateSnapshots == to_string(value))

    assert_raise ArgumentError,
                 "config :playwright, :test: invalid value :always for update_snapshots, expected one of :all, :changed, :missing, :none, :default",
                 fn -> Expect.app_env_expect_config(update_snapshots: :always) end

    assert_raise ArgumentError,
                 "config :playwright, :test: invalid value \"yes\" for ignore_snapshots, expected a boolean",
                 fn -> Expect.app_env_expect_config(ignore_snapshots: "yes") end

    assert_raise ArgumentError,
                 "config :playwright, :test: invalid value :gif for expect.to_have_screenshot.type, expected one of :png, :webp",
                 fn -> Expect.app_env_expect_config(expect: [to_have_screenshot: [type: :gif]]) end

    assert Expect.app_env_expect_config(expect: [to_match_aria_snapshot: [children: :all]]).toMatchAriaSnapshot == %{
             children: "all"
           }
  end

  test "to_pass: a timeout of :infinity is 0, as :timeout's; other values raise" do
    assert Expect.app_env_expect_config(expect: [to_pass: [timeout: :infinity]]).toPass == %{timeout: 0}
    assert Expect.app_env_expect_config(expect: [to_pass: %{intervals: [50]}]).toPass == %{intervals: [50]}

    assert_raise ArgumentError,
                 "config :playwright, :test: invalid value 5000 for expect.to_pass, expected a keyword list or a map",
                 fn -> Expect.app_env_expect_config(expect: [to_pass: 5000]) end

    assert_raise ArgumentError, ~r/^config :playwright, :test: unknown option expect.to_pass.timout, /, fn ->
      Expect.app_env_expect_config(expect: [to_pass: [timout: 1_000]])
    end

    assert_raise ArgumentError,
                 ~s(config :playwright, :test: unknown option expect.to_pass."timeout", expected one of timeout, intervals),
                 fn -> Expect.app_env_expect_config(expect: [to_pass: %{"timeout" => 1}]) end

    # A list of pairs as the map.
    assert_raise ArgumentError,
                 ~s(config :playwright, :test: unknown option expect.to_pass."timeout", expected one of timeout, intervals),
                 fn -> Expect.app_env_expect_config(expect: [to_pass: [{"timeout", 1}]]) end

    assert_raise ArgumentError,
                 ~s(config :playwright, :test: unknown option expect."timeout", expected one of timeout, ) <>
                   "to_have_screenshot, to_match_aria_snapshot, to_pass",
                 fn -> Expect.app_env_expect_config(expect: [{"timeout", 1}]) end
  end

  test "test_helper sets the timeout through the app env" do
    assert Expect.expect_config().timeout == 10_000
  end
end

defmodule Playwright.Matchers.ExpectCacheTest do
  # Not async: it changes the app env and the cached config, which are global.
  use ExUnit.Case, async: false

  alias Playwright.Matchers.Expect

  test "the cache is keyed on the matchers' keys: a runner key's change keeps it, theirs rebuild it" do
    env = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, env) end)
    config = Expect.app_env_expect_config()

    Application.put_env(:playwright, :test, Keyword.put(env, :trace, :on))
    key = Keyword.take(env, [:expect, :update_snapshots, :ignore_snapshots])
    assert {^key, ^config} = :persistent_term.get({Expect, :app_env_expect_config})
    assert Expect.app_env_expect_config() == config

    Application.put_env(:playwright, :test, Keyword.put(env, :update_snapshots, :none))
    assert Expect.app_env_expect_config().updateSnapshots == "none"

    Application.put_env(:playwright, :test, :x)

    assert_raise ArgumentError,
                 "config :playwright, :test: expected a keyword list, got: :x",
                 &Expect.app_env_expect_config/0
  end
end
