defmodule PlaywrightEx.Runtime.PromiseBacklogTest do
  # Not mirrored from upstream: after `Promise.all` over local asyncs rejects, the
  # caller frees the others (`serialize_argument_with_callbacks`): their late results leave no
  # message in its mailbox.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Runtime.Promise

  test "a rejected Promise.all leaves no late results behind once freed" do
    for _ <- 1..20 do
      slow = Promise.async(fn -> Promise.await(Promise.timer(20)) && :late end)
      failing = Promise.async(fn -> raise "boom" end)
      promises = [slow, failing]
      assert_raise RuntimeError, "boom", fn -> Promise.await(Promise.all(promises)) end
      Enum.each(promises, &Promise.free/1)
    end

    Process.sleep(100)
    assert {:messages, []} = Process.info(self(), :messages)
  end
end
