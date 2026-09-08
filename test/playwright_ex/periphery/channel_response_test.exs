defmodule PlaywrightEx.ChannelResponseTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.ChannelResponse

  test "unwraps an omitted void result as an empty result object" do
    assert {:ok, :ok} = ChannelResponse.unwrap(%{id: 1}, fn %{} -> :ok end)
  end

  test "preserves protocol call logs on errors" do
    response = %{id: 1, error: %{message: "boom"}, log: ["waiting for selector"]}

    assert {:error, %{message: "boom", log: ["waiting for selector"]}} =
             ChannelResponse.unwrap(response, & &1)
  end

  test "preserves error details and call logs together" do
    response = %{
      id: 1,
      error: %{message: "boom"},
      error_details: %{timed_out: true},
      log: ["waiting"]
    }

    assert {:error, {%{message: "boom", log: ["waiting"]}, %{timed_out: true}}} =
             ChannelResponse.unwrap(response, & &1)
  end
end
