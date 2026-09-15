defmodule PlaywrightEx.FrameStateTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.FrameState

  test "load states are normalized, added and removed without aliases" do
    state =
      %{url: "about:blank", load_states: [:domcontentloaded]}
      |> FrameState.new()
      |> FrameState.update(:loadstate, %{add: "networkidle"})
      |> FrameState.update(:loadstate, %{add: :load})
      |> FrameState.update(:loadstate, %{remove: "networkidle"})

    assert state.load_states == MapSet.new(["domcontentloaded", "load"])
  end
end
