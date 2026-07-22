defmodule PlaywrightEx.PortTransportTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.PortTransport

  test "honors PLAYWRIGHT_NODEJS_PATH for JavaScript CLI files" do
    node = System.find_executable("node") || flunk("Node.js executable not found on PATH")
    {executable, marker_path} = create_cli_fixture()

    pid =
      start_transport(executable,
        env: %{"PLAYWRIGHT_NODEJS_PATH" => node}
      )

    assert_eventually(fn -> File.read(marker_path) == {:ok, "run-driver"} end)
    GenServer.stop(pid)
  end

  test "preserves JavaScript shebang execution on Unix" do
    if :os.type() == {:win32, :nt} do
      :ok
    else
      node = System.find_executable("node") || flunk("Node.js executable not found on PATH")
      {executable, marker_path} = create_cli_fixture("#!#{node}\n")
      File.chmod!(executable, 0o755)

      pid = start_transport(executable)

      assert_eventually(fn -> File.read(marker_path) == {:ok, "run-driver"} end)
      GenServer.stop(pid)
    end
  end

  defp create_cli_fixture(shebang \\ "") do
    test_dir =
      Path.join(
        System.tmp_dir!(),
        "playwright port transport #{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)

    marker_path = Path.join(test_dir, "invocation.txt")
    executable = Path.join(test_dir, "playwright cli.js")
    marker_base64 = Base.encode64(marker_path)

    File.write!(executable, """
    #{shebang}const fs = require('node:fs')
    const marker = Buffer.from('#{marker_base64}', 'base64').toString()

    if (process.argv[2] === '--version') {
      console.log('Version 1.61.1')
    } else if (process.argv[2] === 'run-driver') {
      fs.writeFileSync(marker, 'run-driver')
      process.stdin.resume()
    }
    """)

    {executable, marker_path}
  end

  defp start_transport(executable, opts \\ []) do
    name = String.to_atom("port_transport_test_#{System.unique_integer([:positive])}")
    connection_name = String.to_atom("port_transport_connection_#{System.unique_integer([:positive])}")

    assert {:ok, pid} =
             PortTransport.start_link(
               [
                 executable: executable,
                 name: name,
                 connection_name: connection_name
               ] ++ opts
             )

    pid
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, attempts) when attempts <= 0, do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
