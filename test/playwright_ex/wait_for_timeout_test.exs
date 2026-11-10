defmodule PlaywrightEx.WaitForTimeoutTest do
  # Not mirrored from upstream: `wait_for_timeout(timeout)` is a duration, so `:infinity` (no
  # timeout for a `timeout:` option) is rejected as a non-number, not turned into a 0 ms wait.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Protocol.ValidatorPrimitives.ValidationError

  @moduletag :page

  test "wait_for_timeout rejects :infinity", %{page: page} do
    assert {:error, %ValidationError{message: "page.waitForTimeout: waitTimeout: expected float, got object"}} =
             Page.wait_for_timeout(page, :infinity)

    assert {:error, %ValidationError{message: "frame.waitForTimeout: waitTimeout: expected float, got object"}} =
             Frame.wait_for_timeout(Page.main_frame(page), :infinity)
  end
end
