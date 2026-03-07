defmodule PlaywrightEx.Resource.Frame.WaiterTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Resource.Frame.Waiter

  test "evaluate load-state waiter completes when state reached" do
    waiter = Waiter.new_load_state_waiter("load")
    frame_state = %{url: "about:blank", load_states: MapSet.new(["load"])}

    assert {:done, {:ok, nil}} = Waiter.evaluate(waiter, frame_state)
  end

  test "evaluate url waiter transitions and then completes on load-state" do
    waiter = Waiter.new_url_waiter(&(&1 == "about:blank#ok"), "load")

    assert {:update, waiter} =
             Waiter.evaluate(waiter, %{url: "about:blank", load_states: MapSet.new(["commit"])})

    assert {:update, waiter} =
             Waiter.evaluate(waiter, %{url: "about:blank#ok", load_states: MapSet.new(["commit"])})

    assert {:done, {:ok, nil}} =
             Waiter.evaluate(waiter, %{url: "about:blank#ok", load_states: MapSet.new(["load"])})
  end

  test "evaluate returns error when url matcher raises" do
    waiter = Waiter.new_url_waiter(fn _url -> raise "boom" end, "load")
    frame_state = %{url: "about:blank", load_states: MapSet.new(["commit"])}

    assert {:error, {:error, %{message: "boom"}}} = Waiter.evaluate(waiter, frame_state)
  end

  test "update_load_states adds and removes states without aliases" do
    load_states =
      MapSet.new()
      |> Waiter.update_load_states(%{add: "networkidle"})
      |> Waiter.update_load_states(%{add: :load})
      |> Waiter.update_load_states(%{remove: "networkidle"})

    assert MapSet.member?(load_states, "load")
    refute MapSet.member?(load_states, "networkidle")
  end
end
