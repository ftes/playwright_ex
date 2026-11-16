defmodule Playwright.Matchers.IgnoreSnapshotsTest do
  # Not async: it sets the expect config, which is global as in JS.
  use ExUnit.Case, async: false

  alias Playwright.Matchers.Expect
  alias Playwright.Matchers.ToMatchSnapshot

  setup do
    Expect.set_expect_config(Map.put(Expect.app_env_expect_config(), :ignoreSnapshots, true))
    on_exit(fn -> :persistent_term.erase({Expect, :expect_config}) end)
  end

  test "toHaveScreenshot with ignoreSnapshots passes, expecting the options it was given, as upstream" do
    options = %{name: "home.png", maxDiffPixels: 10}

    assert %{pass: true, name: "toHaveScreenshot", expected: ^options} =
             ToMatchSnapshot.to_have_screenshot(%{isNot: false}, nil, options)

    assert %{pass: false, expected: expected} = ToMatchSnapshot.to_have_screenshot(%{isNot: true}, nil)
    assert expected == %{}
  end
end
