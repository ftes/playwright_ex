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

  test "soft/1 wraps the receiver, with not_/1 in either order (expect.soft(x).not)" do
    locator = %PlaywrightEx.Locator{}
    soft = %Expect{actual: locator, isNot: false, isSoft: true}
    soft_not = %Expect{actual: locator, isNot: true, isSoft: true}
    assert Expect.soft(locator) == soft
    # A soft receiver is soft already (upstream's `soft` getter returns it).
    assert locator |> Expect.soft() |> Expect.soft() == soft
    assert locator |> Expect.soft() |> Expect.not_() == soft_not
    assert locator |> Expect.not_() |> Expect.soft() == soft_not

    assert_raise ArgumentError, ~r/^expect\.not: the receiver is negated already/, fn ->
      locator |> Expect.soft() |> Expect.not_() |> Expect.not_()
    end

    assert_raise ArgumentError, ~r/^expect\.notToHaveText: the receiver is negated already/, fn ->
      locator |> Expect.not_() |> Expect.soft() |> Expect.not_to_have_text("x")
    end
  end
end
