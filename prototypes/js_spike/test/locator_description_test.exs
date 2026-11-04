# Spike 7: matcher failures render the locator via LocalUtils.asLocatorDescription (sdkLanguage "python").
defmodule PlaywrightJS.LocatorDescriptionTest do
  use ExUnit.Case, async: false
  import PlaywrightJS.Matchers.Expect
  alias PlaywrightJS.TestHelper
  alias PlaywrightJS.Client.{Locator, Page}
  alias PlaywrightJS.Matchers.MatcherHint.ExpectError

  test "toHaveText failure shows the python-style locator" do
    %{page: page} = env = TestHelper.launch()
    Page.goto(page, TestHelper.fixture_url("form.html"))

    e =
      assert_raise ExpectError, fn ->
        expect(Page.get_by_role(page, "button", %{name: "Submit"}), %{timeout: 100}) |> to_have_text("Nope")
      end

    assert e.message =~ ~s{expect(locator).toHaveText(expected) failed}
    assert e.message =~ ~s{Locator:  get_by_role("button", name="Submit")}
    # sdkLanguage "python" at initialize: the server's call log uses the same rendering.
    assert e.message =~ ~s{waiting for get_by_role("button", name="Submit")}
    assert e.message =~ ~s{Received: "Submit"}

    assert Locator.to_string(page |> Page.locator("form") |> Locator.get_by_test_id("x")) == ~s{locator("form").get_by_test_id("x")}
    assert Locator.to_string(Page.get_by_label(page, "I agree")) == ~s{get_by_label("I agree")}
    TestHelper.close(env)
  end
end
