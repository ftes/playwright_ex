defmodule PlaywrightEx.PortTransportTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.PortTransport

  @tag :tmp_dir
  test "rejects Playwright versions older than 1.63", %{tmp_dir: tmp_dir} do
    executable = Path.join(tmp_dir, "playwright")
    File.write!(executable, "#!/bin/sh\nprintf 'Version 1.62.1\\n'\n")
    File.chmod!(executable, 0o755)

    assert_raise RuntimeError,
                 "Unsupported Playwright version 1.62.1; PlaywrightEx requires version 1.63.0 or newer",
                 fn ->
                   PortTransport.start_link(executable: executable)
                 end
  end

  test "buffers fragmented one-to-three-byte frame headers" do
    json = JSON.encode!(%{id: 7, result: %{}})
    frame = <<byte_size(json)::unsigned-little-integer-size(32), json::binary>>
    state = %PortTransport{port: :fake_port, connection_name: self()}

    <<first::binary-size(1), second::binary-size(2), rest::binary>> = frame
    assert {:noreply, state} = PortTransport.handle_info({:fake_port, {:data, first}}, state)
    refute_receive {:"$gen_cast", _}

    assert {:noreply, state} = PortTransport.handle_info({:fake_port, {:data, second}}, state)
    refute_receive {:"$gen_cast", _}

    assert {:noreply, _state} = PortTransport.handle_info({:fake_port, {:data, rest}}, state)
    assert_receive {:"$gen_cast", {:playwright_msg, %{id: 7, result: %{}}}}
  end

  test "parses multiple frames from one port message" do
    frames =
      for id <- [1, 2] do
        json = JSON.encode!(%{id: id, result: %{}})
        <<byte_size(json)::unsigned-little-integer-size(32), json::binary>>
      end

    state = %PortTransport{port: :fake_port, connection_name: self()}
    assert {:noreply, _state} = PortTransport.handle_info({:fake_port, {:data, IO.iodata_to_binary(frames)}}, state)
    assert_receive {:"$gen_cast", {:playwright_msg, %{id: 1}}}
    assert_receive {:"$gen_cast", {:playwright_msg, %{id: 2}}}
  end
end
