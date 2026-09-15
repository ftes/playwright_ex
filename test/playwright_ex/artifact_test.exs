defmodule PlaywrightEx.ArtifactTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Artifact

  defmodule ProtocolConnection do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts),
      do:
        {:ok,
         Map.merge(
           %{
             remote: true,
             source: nil,
             calls: [],
             chunks: ["hello", " world", ""],
             delay: 0,
             fail: nil,
             close_error: false,
             close_delay: 0
           },
           Map.new(opts)
         )}

    @impl true
    def handle_call(:transport, _from, state) do
      transport = if state.remote, do: PlaywrightEx.WebSocketTransport, else: PlaywrightEx.PortTransport
      {:reply, {:ok, transport}, state}
    end

    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:send, message}, _from, state) do
      state = %{state | calls: [message | state.calls]}

      case message.method do
        :path_after_finished ->
          {:reply, %{result: %{value: state.source}}, state}

        :save_as_stream ->
          {:reply, %{result: %{stream: %{guid: "stream"}}}, state}

        :close ->
          Process.sleep(state.close_delay)
          {:reply, if(state.close_error, do: %{error: %{message: "close failed"}}, else: %{result: %{}}), state}

        :read ->
          read(state)
      end
    end

    defp read(%{fail: :read} = state), do: {:reply, %{error: %{message: "read failed"}}, state}
    defp read(%{fail: :disconnect} = state), do: {:stop, :normal, state}
    defp read(%{fail: :invalid_base64} = state), do: {:reply, %{result: %{binary: "*"}}, state}

    defp read(state) do
      Process.sleep(state.delay)
      [chunk | chunks] = state.chunks
      {:reply, %{result: %{binary: Base.encode64(chunk)}}, %{state | chunks: chunks}}
    end
  end

  @moduletag :tmp_dir

  test "remote saves close the stream without deleting its source", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, []})
    path = Path.join([dir, "nested", "result"])
    assert :ok = Artifact.save_as("artifact", path, connection: connection, timeout: 1000)
    assert File.read!(path) == "hello world"
    assert Enum.map(GenServer.call(connection, :calls), & &1.method) == [:save_as_stream, :read, :read, :read, :close]
    assert File.ls!(Path.dirname(path)) == ["result"]
  end

  for remote <- [false, true] do
    test "#{if remote, do: "remote saves", else: "local copies"} replace existing destinations", %{tmp_dir: dir} do
      source = Path.join(dir, "source")
      target = Path.join(dir, "target")
      File.write!(source, "hello world")
      File.write!(target, "original destination, longer than the new contents")
      connection = start_supervised!({ProtocolConnection, remote: unquote(remote), source: source})

      assert :ok = Artifact.save_as("artifact", target, connection: connection, timeout: 1000)
      assert File.read!(target) == "hello world"
      assert File.read!(source) == "hello world"
      assert Enum.sort(File.ls!(dir)) == ["source", "target"]
    end
  end

  test "read errors close streams and preserve the existing destination", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, fail: :read})
    path = Path.join(dir, "result")
    File.write!(path, "original")
    assert {:error, %{message: "read failed"}} = Artifact.save_as("artifact", path, connection: connection, timeout: 1000)
    assert File.read!(path) == "original"
    assert Enum.any?(GenServer.call(connection, :calls), &(&1.method == :close))
    assert File.ls!(dir) == ["result"]
  end

  test "slow cleanup failures preserve the transfer result", %{tmp_dir: dir} do
    # Allow file I/O under CI load, while making cleanup outlast the transfer timeout.
    for fail <- [nil, :read] do
      connection = start_supervised!({ProtocolConnection, fail: fail, close_error: true, close_delay: 1100}, id: fail)
      path = Path.join(dir, "result-#{inspect(fail)}")
      result = Artifact.save_as("artifact", path, connection: connection, timeout: 1000)

      if fail do
        assert {:error, %{message: "read failed"}} = result
        refute File.exists?(path)
      else
        assert :ok = result
        assert File.read!(path) == "hello world"
      end

      assert List.last(GenServer.call(connection, :calls)).method == :close
    end
  end

  test "exceptions still close the stream and remove staging files", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, fail: :invalid_base64})

    assert_raise ArgumentError, fn ->
      Artifact.save_as("artifact", Path.join(dir, "result"), connection: connection, timeout: 1000)
    end

    assert Enum.any?(GenServer.call(connection, :calls), &(&1.method == :close))
    assert File.ls!(dir) == []
  end

  test "connection exit returns an error and removes staging files", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, fail: :disconnect})

    assert {:error, %{reason: :connection_closed}} =
             Artifact.save_as("artifact", Path.join(dir, "result"), connection: connection, timeout: 1000)

    assert File.ls!(dir) == []
  end

  test "all reads share one deadline and a late response cannot commit the file", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, delay: 400, chunks: ["one", "two", "three", ""]})
    path = Path.join(dir, "result")
    File.write!(path, "original")
    assert {:error, %{reason: :timeout}} = Artifact.save_as("artifact", path, connection: connection, timeout: 1000)
    assert File.read!(path) == "original"
    calls = GenServer.call(connection, :calls)
    timeouts = for %{method: :read, metadata: %{timeout: timeout}} <- calls, do: timeout
    assert length(timeouts) >= 2
    assert List.first(timeouts) > List.last(timeouts)
    assert List.last(calls).method == :close
    assert File.ls!(dir) == ["result"]
  end

  test "unlimited transfer uses protocol zero timeout", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, []})
    assert :ok = Artifact.save_as("artifact", Path.join(dir, "result"), connection: connection, timeout: :infinity)

    assert Enum.all?(GenServer.call(connection, :calls), fn call ->
             call.method == :close or call.metadata.timeout == 0
           end)
  end

  test "zero timeout does not request or create files", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, []})
    path = Path.join([dir, "nested", "result"])
    assert {:error, %{reason: :timeout}} = Artifact.save_as("artifact", path, connection: connection, timeout: 0)
    assert GenServer.call(connection, :calls) == []
    assert File.ls!(dir) == []
  end

  test "an unavailable connection returns an error before staging", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, []})
    GenServer.stop(connection)

    assert {:error, %{reason: :connection_closed}} =
             Artifact.save_as("artifact", Path.join(dir, "result"), connection: connection, timeout: 1000)

    assert File.ls!(dir) == []
  end

  test "an existing file in the parent path returns a file error", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, []})
    parent = Path.join(dir, "file")
    File.write!(parent, "original")
    assert {:error, _} = Artifact.save_as("artifact", Path.join(parent, "result"), connection: connection, timeout: 1000)
    assert File.read!(parent) == "original"
    assert GenServer.call(connection, :calls) == []
  end

  test "local copies preserve source files and failed copies preserve destinations", %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    target = Path.join(dir, "target")
    File.write!(source, "bytes")
    connection = start_supervised!({ProtocolConnection, remote: false, source: source})
    assert :ok = Artifact.save_as("artifact", target, connection: connection, timeout: 1000)
    assert File.read!(source) == "bytes"
    assert File.read!(target) == "bytes"
    File.rm!(source)
    assert {:error, :enoent} = Artifact.save_as("artifact", target, connection: connection, timeout: 1000)
    assert File.read!(target) == "bytes"
    assert File.ls!(dir) == ["target"]
  end

  test "destination errors still close streams and remove staging files", %{tmp_dir: dir} do
    connection = start_supervised!({ProtocolConnection, []})
    path = Path.join(dir, "directory")
    File.mkdir!(path)
    assert {:error, _} = Artifact.save_as("artifact", path, connection: connection, timeout: 1000)
    assert Enum.any?(GenServer.call(connection, :calls), &(&1.method == :close))
    assert File.ls!(dir) == ["directory"]
  end
end
