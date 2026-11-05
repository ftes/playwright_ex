defmodule PlaywrightEx.ExpectTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Expect

  test "not_/1 wraps the receiver; a negated one is not negated again (no expect(x).not.not)" do
    locator = %PlaywrightEx.Locator{}
    assert %Expect{actual: ^locator, isNot: true} = Expect.not_(locator)

    assert_raise ArgumentError, ~r/^expect\.not: the receiver is negated already/, fn ->
      locator |> Expect.not_() |> Expect.not_()
    end

    assert_raise ArgumentError, ~r/^expect\.notToHaveText: the receiver is negated already/, fn ->
      locator |> Expect.not_() |> Expect.not_to_have_text("x")
    end

    assert_raise ArgumentError, ~r/^expect\.notToHaveAttribute: the receiver is negated already/, fn ->
      locator |> Expect.not_() |> Expect.not_to_have_attribute!("disabled", timeout: 1)
    end
  end
end
