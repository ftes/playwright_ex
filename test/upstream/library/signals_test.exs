defmodule PlaywrightEx.Library.SignalsTest do
  @upstream "tests/library/signals.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ClientProcess

  # Upstream runs a Node.js client in a child process and sends signals to it. Here the child is
  # a BEAM that uses the Elixir client (`PlaywrightEx.ClientProcess`), as Python runs a Python
  # client: `start_remote_server.("launchServer", options)` starts it. As upstream's
  # `process.kill(pid, signal)`, the tests send the signals to the BEAM only. The driver closes
  # the browser when the BEAM goes away.

  # test.slow()

  setup %{browser_name: browser_name} do
    start_remote_server = fn "launchServer", options ->
      client = ClientProcess.start(browser_name, options)
      on_exit(fn -> ClientProcess.close(client) end)
      client
    end

    %{start_remote_server: start_remote_server}
  end

  defp mac?, do: match?({:unix, :darwin}, :os.type())

  # platformFixtures `macVersion`: Darwin 25 = macOS 26.
  defp mac_version do
    {darwin_major, _, _} = :os.version()
    if darwin_major >= 25, do: darwin_major + 1, else: darwin_major - 9
  end

  test "should close the browser when the node process closes", %{
    start_remote_server: start_remote_server,
    server: server
  } do
    remote_server = start_remote_server.("launchServer", %{url: server.empty_page})
    # isWindows: taskkill  -- no Windows
    ClientProcess.kill(remote_server, "SIGTERM")
    # We might not get browser exitCode in time when killing the parent node process,
    # so we don't check it here.
    assert ClientProcess.child_exit_code(remote_server) == 0
  end

  test "should remove temp dir on process.exit", %{start_remote_server: start_remote_server, server: server} do
    # test.skip(platform === 'win32', ...)  -- no Windows
    file = Path.join(System.tmp_dir!(), "exit-#{System.unique_integer([:positive])}.file")
    on_exit(fn -> File.rm(file) end)
    remote_server = start_remote_server.("launchServer", %{url: server.empty_page, exitOnFile: file})
    temp_dir = ClientProcess.out(remote_server, "tempDir")
    before = File.exists?(temp_dir)
    File.write!(file, "data")
    assert ClientProcess.child_exit_code(remote_server) == 42
    after_exit = File.exists?(temp_dir)
    assert before == true
    assert after_exit == false
  end

  describe "signals" do
    # test.skip(({ platform }) => platform === 'win32')  -- no Windows

    test "should report browser close signal 2", %{
      start_remote_server: start_remote_server,
      server: server,
      browser_name: browser_name
    } do
      remote_server = start_remote_server.("launchServer", %{url: server.empty_page})
      pid = ClientProcess.out(remote_server, "pid")
      System.cmd("kill", ["-KILL", "-#{pid}"])

      if mac?() and browser_name == "webkit" and mac_version() > 13 and
           :erlang.system_info(:system_architecture) |> to_string() |> String.starts_with?("aarch64") do
        # WebKit on newer macOS exits sometimes with exit code, sometimes with signal.
        assert "exitCode:" <>
                 ClientProcess.out(remote_server, "exitCode") <>
                 "signal:" <> ClientProcess.out(remote_server, "signal") =~ ~r/exitCode:137|signal:SIGKILL/
      else
        assert ClientProcess.out(remote_server, "exitCode") == "null"
        assert ClientProcess.out(remote_server, "signal") == "SIGKILL"
      end

      ClientProcess.kill(remote_server, "SIGTERM")
      ClientProcess.child_exit_code(remote_server)
    end

    test "should close the browser on SIGINT", %{start_remote_server: start_remote_server, server: server} do
      remote_server = start_remote_server.("launchServer", %{url: server.empty_page})
      ClientProcess.kill(remote_server, "SIGINT")
      assert ClientProcess.out(remote_server, "exitCode") == "0"
      assert ClientProcess.out(remote_server, "signal") == "null"
      # +Bd: SIGINT ends the BEAM with 130 (upstream's Node.js exits with 130 too).
      assert ClientProcess.child_exit_code(remote_server) == 130
    end

    test "should close the browser on SIGTERM", %{start_remote_server: start_remote_server, server: server} do
      remote_server = start_remote_server.("launchServer", %{url: server.empty_page})
      ClientProcess.kill(remote_server, "SIGTERM")
      assert ClientProcess.out(remote_server, "exitCode") == "0"
      assert ClientProcess.out(remote_server, "signal") == "null"
      # The BEAM handles SIGTERM (init:stop/0) and exits with 0, as upstream's Node.js does.
      assert ClientProcess.child_exit_code(remote_server) == 0
    end

    test "should close the browser on SIGHUP", %{start_remote_server: start_remote_server, server: server} do
      remote_server = start_remote_server.("launchServer", %{url: server.empty_page})
      ClientProcess.kill(remote_server, "SIGHUP")
      assert ClientProcess.out(remote_server, "exitCode") == "0"
      assert ClientProcess.out(remote_server, "signal") == "null"
      # Deviation: upstream's Node.js closes the browser on SIGHUP (handleSIGHUP, in the process
      # that launched it) and exits with 0. The BEAM does not handle SIGHUP: the signal ends it
      # (128 + 1), and the driver, left without a client, closes the browser.
      assert ClientProcess.child_exit_code(remote_server) == 129
    end

    @tag skip:
           "not ported: stallOnClose (__testHookGracefullyClose is a JS function in the launch options; " <>
             "the double-SIGINT kill runs in the signal handlers of the driver, which gets no signals)"
    test "should kill the browser on double SIGINT and remove temp dir"

    @tag skip:
           "not ported: stallOnClose (__testHookGracefullyClose is a JS function in the launch options; " <>
             "the SIGINT + SIGTERM kill runs in the signal handlers of the driver, which gets no signals)"
    test "should kill the browser on SIGINT + SIGTERM"

    @tag skip:
           "not ported: stallOnClose (__testHookGracefullyClose is a JS function in the launch options; " <>
             "the SIGTERM + SIGINT kill runs in the signal handlers of the driver, which gets no signals)"
    test "should kill the browser on SIGTERM + SIGINT"

    test "should not prevent default SIGTERM handling after browser close", %{start_remote_server: start_remote_server} do
      remote_server = start_remote_server.("launchServer", %{startStopAndRunHttp: true})
      assert ClientProcess.out(remote_server, "closed") == "success"
      ClientProcess.kill(remote_server, "SIGTERM")
      # Deviation: upstream's Node.js has no SIGTERM handler left and the signal ends it (exit
      # code null, signal SIGTERM). The BEAM's default SIGTERM handling stops it with 0.
      assert ClientProcess.child_exit_code(remote_server) == 0
    end
  end
end
