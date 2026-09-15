defmodule PlaywrightEx.FrameWaiterTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.FrameWaiter

  test "evaluate load-state waiter completes when state reached" do
    waiter = FrameWaiter.new_load_state_waiter("load")
    frame_state = %{url: "about:blank", load_states: MapSet.new(["load"])}

    assert {:done, {:ok, nil}} = FrameWaiter.evaluate(waiter, frame_state)
  end

  test "evaluate url waiter transitions and then completes on load-state" do
    waiter = FrameWaiter.new_url_waiter(&(&1 == "about:blank#ok"), "load")

    assert {:update, waiter} =
             FrameWaiter.evaluate(waiter, %{url: "about:blank", load_states: MapSet.new(["commit"])})

    assert {:update, waiter} =
             FrameWaiter.evaluate(waiter, %{url: "about:blank#ok", load_states: MapSet.new(["commit"])})

    assert {:done, {:ok, nil}} =
             FrameWaiter.evaluate(waiter, %{url: "about:blank#ok", load_states: MapSet.new(["load"])})
  end

  test "evaluate propagates unexpected url matcher errors" do
    waiter = FrameWaiter.new_url_waiter(fn _url -> raise "boom" end, "load")
    frame_state = %{url: "about:blank", load_states: MapSet.new(["commit"])}

    assert_raise RuntimeError, "boom", fn -> FrameWaiter.evaluate(waiter, frame_state) end
    waiter = FrameWaiter.new_url_waiter(fn _url -> exit(:unexpected) end, "load")
    assert catch_exit(FrameWaiter.evaluate(waiter, frame_state)) == :unexpected
  end
end
