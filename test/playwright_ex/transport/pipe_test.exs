defmodule PlaywrightEx.Transport.PipeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PlaywrightEx.Transport.Pipe

  # `sh -c '...' run-driver`: the appended `run-driver` becomes `$0`.
  defp start(script) do
    test = self()

    start_supervised!(
      {Pipe,
       executable: {"/bin/sh", ["-c", script]},
       on_message: &send(test, {:message, &1}),
       on_close: &send(test, {:closed, &1})},
      restart: :temporary
    )
  end

  test "round-trips messages like JSON.stringify/JSON.parse" do
    pipe = start("exec cat")
    Pipe.send_message(pipe, %{id: 1, params: %{a: nil, b: :null, c: [%{d: nil, e: "x"}]}})
    assert_receive {:message, %{"id" => 1, "params" => %{"b" => :null, "c" => [%{"e" => "x"}]} = params}}, 5000
    refute Map.has_key?(params, "a")
  end

  test "reassembles large messages and keeps order" do
    pipe = start("exec cat")
    large = String.duplicate("0123456789", 500_000)

    for i <- 1..20, do: Pipe.send_message(pipe, %{id: i, s: if(i == 10, do: large, else: "small")})

    for i <- 1..20 do
      assert_receive {:message, %{"id" => ^i, "s" => s}}, 5000
      assert s == if(i == 10, do: large, else: "small")
    end
  end

  test "a message that cannot be encoded is not written: a call gets an error, others are logged" do
    pipe = start("exec cat")

    log =
      capture_log(fn ->
        Pipe.send_messages(pipe, [
          %{id: 1, method: "evaluate", params: %{s: <<0xFF>>}},
          %{guid: "x", method: "__abort__", params: %{reason: {:not, :json}}},
          %{id: 2, s: "ok"}
        ])

        assert_receive {:message, %{"id" => 1, "error" => %{"error" => %{"message" => message}}}}, 5000
        assert message =~ "Message cannot be encoded as JSON: "
        # Written after the others: the pipe lives on.
        assert_receive {:message, %{"id" => 2, "s" => "ok"}}, 5000
      end)

    assert log =~ "Playwright message dropped, it cannot be encoded as JSON"
    refute_received {:message, _}
  end

  test "close/1 closes the pipe and calls on_close once" do
    pipe = start("exec cat")
    assert :ok = Pipe.close(pipe)
    assert_receive {:closed, nil}, 5000
    refute_receive {:closed, _}
  end

  @tag :tmp_dir
  test "close/1 waits until the driver has exited", %{tmp_dir: tmp_dir} do
    exited = Path.join(tmp_dir, "exited")
    pipe = start("cat >/dev/null; sleep 0.3; touch '#{exited}'")
    assert :ok = Pipe.close(pipe)
    assert File.exists?(exited)
  end

  test "driver exit calls on_close with its exit status" do
    start("exit 3")
    assert_receive {:closed, 3}, 5000
  end
end
