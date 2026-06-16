defmodule PlaywrightEx.FrameExpectTest do
  @moduledoc """
  End-to-end coverage for `Frame.expect/2`, which must return the same
  `{:ok, boolean}` under both the 1.60 and 1.61 driver wire contracts.
  """
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Frame

  setup %{frame: frame} do
    set_html(frame.guid, ~s(<div id="present">hello</div>))
    :ok
  end

  describe "expect/2 visibility (driver-version agnostic)" do
    test "present element, is_not: false -> matches true", %{frame: frame} do
      assert {:ok, true} =
               Frame.expect(frame.guid,
                 selector: "#present",
                 expression: "to.be.visible",
                 is_not: false,
                 timeout: @timeout
               )
    end

    test "absent element, is_not: false -> matches false", %{frame: frame} do
      assert {:ok, false} =
               Frame.expect(frame.guid,
                 selector: "#missing",
                 expression: "to.be.visible",
                 is_not: false,
                 timeout: @timeout
               )
    end

    test "absent element, is_not: true (expect-not-visible satisfied) -> matches false", %{frame: frame} do
      assert {:ok, false} =
               Frame.expect(frame.guid,
                 selector: "#missing",
                 expression: "to.be.visible",
                 is_not: true,
                 timeout: @timeout
               )
    end

    test "assert_has finds a present element", %{frame: frame} do
      assert_has(frame.guid, "#present")
    end

    test "refute_has on an absent element", %{frame: frame} do
      refute_has(frame.guid, "#missing")
    end
  end
end
