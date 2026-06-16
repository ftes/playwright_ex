defmodule PlaywrightEx.ChannelResponseTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.ChannelResponse

  describe "unwrap_expect/2" do
    test "1.60 reply: trusts result.matches regardless of is_not" do
      assert {:ok, true} = ChannelResponse.unwrap_expect(%{id: 1, result: %{matches: true}}, false)
      assert {:ok, false} = ChannelResponse.unwrap_expect(%{id: 1, result: %{matches: false}}, false)
      assert {:ok, true} = ChannelResponse.unwrap_expect(%{id: 1, result: %{matches: true}}, true)
    end

    test "1.61 satisfied reply (no result/error): matches == not is_not" do
      assert {:ok, true} = ChannelResponse.unwrap_expect(%{id: 6, method: nil}, false)
      assert {:ok, false} = ChannelResponse.unwrap_expect(%{id: 6, method: nil}, true)
    end

    test "1.61 unsatisfied reply (error + error_details): matches == is_not" do
      reply = %{
        id: 27,
        method: nil,
        error: %{error: %{message: "Expect failed", name: "ExpectError", stack: "..."}},
        log: ["  - Expect \"to.be.visible\" with timeout 2000ms"],
        error_details: %{
          timed_out: true,
          received: %{value: %{v: "undefined"}, aria_snapshot: "- text: hello"},
          custom_error_message: "element(s) not found"
        }
      }

      assert {:ok, false} = ChannelResponse.unwrap_expect(reply, false)
      assert {:ok, true} = ChannelResponse.unwrap_expect(reply, true)
    end

    test "genuine protocol error without error_details still propagates" do
      reply = %{id: 9, error: %{error: %{message: "boom", name: "Error", stack: "..."}}}
      assert {:error, %{error: %{name: "Error"}}} = ChannelResponse.unwrap_expect(reply, false)
    end
  end
end
