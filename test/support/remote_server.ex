defmodule PlaywrightEx.RemoteServer do
  @upstream "tests/config/remoteServer.ts"
  @moduledoc """
  Port of upstream `#{@upstream}`: `RunServer` only, the driver's `run-server` command.

  # class RemoteServer  -- not ported: launchServer (PLAN: out of scope)
  """

  defmodule RunServer do
    @moduledoc """
    `run-server` started with the pinned driver (as `PlaywrightEx.Driver` runs `run-driver`).

    Deviation: `close/1` kills the process with `kill -9`: `run-server` ignores SIGTERM, and
    an Erlang port can only close stdin.
    """
    defstruct [:port, :os_pid, :_wsEndpoint]

    def start(options \\ %{}) do
      {program, args} = PlaywrightEx.Driver.ensure_installed()
      command = args ++ ["run-server"]
      command = if options[:mode] == "extension", do: command ++ ["--mode=extension"], else: command

      command =
        if options[:artifactsDir], do: command ++ ["--artifacts-dir=#{options.artifactsDir}"], else: command

      command = if options[:unsafe], do: command ++ ["--unsafe"], else: command

      # Upstream inherits the test runner's environment (PWTEST_UNDER_TEST=1); `nil` unsets.
      env =
        for {name, value} <-
              Map.merge(%{"PWTEST_UNDER_TEST" => "1"}, options[:env] || %{}),
            do: {String.to_charlist(name), (value && String.to_charlist(value)) || false}

      port =
        Port.open({:spawn_executable, program}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: command,
          env: env ++ Enum.map(PlaywrightEx.Driver.driver_env(), fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      ws_endpoint = wait_listening(port, "")
      %__MODULE__{port: port, os_pid: os_pid, _wsEndpoint: ws_endpoint}
    end

    defp wait_listening(port, acc) do
      prefix = "Listening on "

      receive do
        {^port, {:data, data}} ->
          acc = acc <> data

          case Regex.run(~r/^#{prefix}(\S+)/m, acc) do
            [_, endpoint] -> endpoint
            nil -> wait_listening(port, acc)
          end

        {^port, {:exit_status, status}} ->
          raise "run-server exited with #{status}: #{acc}"
      after
        30_000 -> raise "run-server did not start: #{acc}"
      end
    end

    def ws_endpoint(this) do
      this._wsEndpoint
    end

    def close(this) do
      System.cmd("kill", ["-9", "#{this.os_pid}"], stderr_to_stdout: true)
      wait_exited(this.os_pid, 50)
    end

    # From any process (the port's exit status goes to its owner).
    defp wait_exited(_os_pid, 0), do: :ok

    defp wait_exited(os_pid, attempts) do
      case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
        {_, 0} ->
          Process.sleep(100)
          wait_exited(os_pid, attempts - 1)

        _ ->
          :ok
      end
    end
  end
end
