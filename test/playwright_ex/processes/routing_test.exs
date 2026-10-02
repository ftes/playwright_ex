defmodule PlaywrightEx.RoutingTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Routing

  test "disposal during route or frame subscription prevents dispatch and releases partial subscriptions" do
    for disposed <- ["route", "frame"] do
      owner = self()
      connection = spawn(fn -> forward_calls(owner) end)
      on_exit(fn -> Process.exit(connection, :kill) end)

      state = %{
        connection: connection,
        guid: "page",
        glob: "**/*",
        owner: owner,
        callback: fn _, _ -> send(owner, :callback_ran) end,
        timeout: 1_000,
        on_error: :raise,
        installed: false,
        workers: %{},
        subscriptions: MapSet.new(["page"])
      }

      dispatch =
        Task.async(fn ->
          Routing.handle_info(
            {:playwright_msg, %{guid: "page", method: :route, params: %{route: %{guid: "route"}}}},
            state
          )
        end)

      assert_receive {:rpc, from, {:initializer, "route"}}
      GenServer.reply(from, {:ok, %{request: %{guid: "request"}}})
      assert_receive {:rpc, from, {:initializer, "request"}}
      GenServer.reply(from, {:ok, %{frame: %{guid: "frame"}}})
      assert_receive {:rpc, from, {:route_ancestors, "frame"}}
      GenServer.reply(from, ["page"])
      assert_receive {:rpc, from, {:subscribe, _, "route"}}

      if disposed == "frame" do
        GenServer.reply(from, :ok)
        assert_receive {:rpc, from, {:subscribe, _, "frame"}}
        GenServer.reply(from, {:error, %{reason: :disposed}})
      else
        GenServer.reply(from, {:error, %{reason: :disposed}})
      end

      assert_receive {:rpc, from, {:send, %{guid: "route", method: :abort}}}
      GenServer.reply(from, %{result: %{}})

      if disposed == "frame" do
        assert_receive {:rpc, from, {:unsubscribe, _, "route"}}
        GenServer.reply(from, :ok)
      end

      assert {:noreply, ^state} = Task.await(dispatch)
      refute_receive :callback_ran
    end
  end

  defp forward_calls(owner) do
    receive do
      {:"$gen_call", from, request} ->
        send(owner, {:rpc, from, request})
        forward_calls(owner)
    end
  end
end
