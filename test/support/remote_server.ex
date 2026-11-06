defmodule PlaywrightEx.RemoteServer do
  @upstream "tests/config/remoteServer.ts"
  @moduledoc """
  Port of upstream `#{@upstream}`: `RunServer` (the driver's `run-server` command) and
  `RemoteServer` (the `launchServer` kind of `startRemoteServer`).

  `RemoteServer` runs upstream's own `tests/config/remote-server-impl.js` with the driver's
  Node.js; `require('playwright-core')` there resolves to the driver package (`NODE_PATH`).
  `LaunchServer` stands in for `browserType.launchServer(options)` (not in the API,
  architecture: Generated facade): the driver's hidden `launch-server` command, as Python's
  `launch_server` fixture.

  Deviations: the child process is not detached (no process group: an Erlang port cannot do
  that), so signals go to the child only. Its exit code is the port's exit status: a signal
  `N` that ends the process gives `128 + N`, not `null` and the signal.
  """

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.RemoteServer.ChildProcess

  # export interface PlaywrightServer  -- ported as PlaywrightEx.RemoteServer.PlaywrightServer
  # export class RunServer  -- ported as PlaywrightEx.RemoteServer.RunServer
  # export type RemoteServerOptions: a map with the JS keys (`stallOnClose`, `url`, ...).

  # export class RemoteServer
  defstruct [:_process, :_browserType, :_browser, :_wsEndpoint]

  def _start(browser_type, remote_server_options \\ %{}) do
    browser_options =
      PlaywrightEx.Runtime.Api.call(nil, browser_type, fn ->
        PlaywrightEx.Runtime.Heap.get(PlaywrightEx.Runtime.Heap.get(browser_type, :_playwright), :_defaultLaunchOptions)
      end) || %{}

    # JSON.stringify drops the `undefined` ones.
    launch_options =
      browser_options
      |> Map.take([:args, :headless, :channel, :executablePath])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.merge(%{handleSIGINT: true, handleSIGTERM: true, handleSIGHUP: true})

    launch_options =
      if remote_server_options[:sharedBrowser], do: Map.put(launch_options, :_sharedBrowser, true), else: launch_options

    launch_options =
      if dir = remote_server_options[:artifactsDir],
        do: Map.put(launch_options, :artifactsDir, dir),
        else: launch_options

    options =
      Map.merge(
        %{browserTypeName: BrowserType.name(browser_type), channel: nil, launchOptions: launch_options},
        Map.new(remote_server_options)
      )

    {node, [cli]} = PlaywrightEx.Driver.ensure_installed()
    impl = Path.join(PlaywrightEx.Upstream.ensure!(), "tests/config/remote-server-impl.js")
    {node, args, env} = ChildProcess.exit_on_stdin_eof({node, [impl, JSON.encode!(options)]})
    process = ChildProcess.start(node, args, Map.put(env, "NODE_PATH", node_path(cli)))
    this = %__MODULE__{_process: process, _browserType: browser_type}
    this = %{this | _wsEndpoint: out(this, "wsEndpoint")}

    if url = remote_server_options[:url] do
      browser = BrowserType.connect!(browser_type, this._wsEndpoint)
      page = Browser.new_page!(browser)
      Page.goto!(page, url)
      %{this | _browser: browser}
    else
      this
    end
  end

  # A `node_modules` with `playwright-core` (the driver package), for `NODE_PATH`.
  defp node_path(cli) do
    dir = Path.join(System.tmp_dir!(), "playwright_ex-#{PlaywrightEx.Driver.version()}-node_modules")
    link = Path.join(dir, "playwright-core")

    File.mkdir_p!(dir)
    # Concurrent callers: the first link wins.
    File.ln_s(Path.dirname(cli), link)
    dir
  end

  # _addOutput: `ChildProcess` collects the output; `out/2` parses it.

  def out(this, key) do
    ChildProcess.await(this._process, fn output ->
      case Regex.run(~r/\(#{Regex.escape(key)}=>([^()]+)\)/, output) do
        [_, value] -> {:ok, value}
        nil -> nil
      end
    end)
  end

  def ws_endpoint(this) do
    this._wsEndpoint
  end

  def child(this) do
    ChildProcess.pid(this._process)
  end

  def child_exit_code(this) do
    ChildProcess.exit_code(this._process)
  end

  def close(%{_process: process} = this) do
    if this._browser, do: Browser.close(this._browser)
    if Process.alive?(process), do: close_process(process)
  end

  defp close_process(process) do
    ChildProcess.kill(process, "SIGINT")

    # `setTimeout(() => this._process.kill('SIGINT'), 30000)`: kill it after 30 s instead.
    case ChildProcess.exit_code(process, 30_000) do
      :timeout -> ChildProcess.kill(process, "SIGKILL")
      _ -> :ok
    end

    ChildProcess.stop(process)
  end

  defmodule PlaywrightServer do
    @moduledoc "Upstream's `interface PlaywrightServer`: `wsEndpoint()` and `close()` of either kind."
    alias PlaywrightEx.RemoteServer
    alias PlaywrightEx.RemoteServer.RunServer

    def ws_endpoint(%RunServer{} = server), do: RunServer.ws_endpoint(server)
    def ws_endpoint(%RemoteServer{} = server), do: RemoteServer.ws_endpoint(server)

    def close(%RunServer{} = server), do: RunServer.close(server)
    def close(%RemoteServer{} = server), do: RemoteServer.close(server)
  end

  defmodule LaunchServer do
    @moduledoc """
    `browserType.launchServer(options)` for the tests (`BrowserServer` is not in the API,
    architecture: Generated facade): the driver's hidden `launch-server --browser <name> --config
    <options.json>` command, which prints the `wsEndpoint`. As Python's `RemoteServer` test helper
    (its `conftest.py`).

    `start/2` returns `{:error, message}` (the output) when the launch fails, as
    `launchServer(options).catch(e => e)`. `close/1` sends SIGINT (the server closes the browser,
    `handleSIGINT`), `kill/1` SIGKILL.
    """
    alias PlaywrightEx.RemoteServer.ChildProcess

    defstruct [:_process, :_wsEndpoint]

    def start(browser_name, options \\ %{}) do
      config = Path.join(System.tmp_dir!(), "playwright_ex-launch-server-#{System.unique_integer([:positive])}.json")
      File.write!(config, JSON.encode!(Map.new(options)))
      {program, args} = PlaywrightEx.Driver.ensure_installed()

      {program, args, env} =
        ChildProcess.exit_on_stdin_eof(
          {program, args ++ ["launch-server", "--browser", browser_name, "--config", config]}
        )

      process = ChildProcess.start(program, args, env)

      result =
        ChildProcess.await(
          process,
          fn output ->
            case Regex.run(~r/^(wss?:\/\/\S+)$/m, output) do
              [_, endpoint] -> {:ok, endpoint}
              nil -> nil
            end
          end,
          raise: false
        )

      File.rm(config)

      case result do
        {:ok, endpoint} ->
          {:ok, %__MODULE__{_process: process, _wsEndpoint: endpoint}}

        {:error, output} ->
          ChildProcess.stop(process)
          {:error, output}
      end
    end

    def start!(browser_name, options \\ %{}) do
      case start(browser_name, options) do
        {:ok, server} -> server
        {:error, output} -> raise "launch-server failed: #{output}"
      end
    end

    def ws_endpoint(this), do: this._wsEndpoint

    def close(%{_process: process} = this) do
      if Process.alive?(process) do
        ChildProcess.kill(process, "SIGINT")
        if ChildProcess.exit_code(process, 30_000) == :timeout, do: kill(this), else: ChildProcess.stop(process)
      end

      :ok
    end

    def kill(%{_process: process}) do
      if Process.alive?(process) do
        ChildProcess.kill(process, "SIGKILL")
        ChildProcess.exit_code(process)
        ChildProcess.stop(process)
      end

      :ok
    end
  end

  defmodule ChildProcess do
    @moduledoc """
    Upstream's `TestChildProcess` (`tests/config/commonFixtures.ts`), as far as the remote servers
    use it: a process that owns the port, collects the output (stdout and stderr) and the exit
    status, so that any test process can wait for them. Not linked: it outlives the test process
    until `stop/1`, for the `on_exit` callbacks.

    Deviation: upstream kills the child's process group in an `exit` handler of the test runner.
    The BEAM runs no code when it is killed (`kill -9`, a crash), so the children exit by
    themselves when their stdin, the BEAM end of the port's pipe, closes: Node.js children
    preload `exit_on_stdin_eof.js` (`exit_on_stdin_eof/1`), the child BEAM of
    `PlaywrightEx.ClientProcess` reads its stdin until EOF.
    """
    use GenServer

    @exit_on_stdin_eof Path.expand("exit_on_stdin_eof.js", __DIR__)

    @doc """
    The command `{program, args}` of a Node.js process (`node` or the driver,
    `PlaywrightEx.Driver.executable/0`) with `exit_on_stdin_eof.js` preloaded, and the env for
    that: `{program, args, env}`. A driver that is no `node` binary (`PLAYWRIGHT_EX_EXECUTABLE`)
    gets the preload in `NODE_OPTIONS`.
    """
    def exit_on_stdin_eof({program, args}) do
      if Path.basename(program, ".exe") == "node" do
        {program, ["-r", @exit_on_stdin_eof | args], %{}}
      else
        node_options = String.trim(~s(#{System.get_env("NODE_OPTIONS")} --require "#{@exit_on_stdin_eof}"))
        {program, args, %{"NODE_OPTIONS" => node_options}}
      end
    end

    def start(program, args, env \\ %{}) do
      {:ok, pid} = GenServer.start(__MODULE__, {program, args, env})
      pid
    end

    def pid(this), do: GenServer.call(this, :os_pid)

    def output(this), do: GenServer.call(this, :output)

    @doc """
    Waits until `fun.(output)` returns `{:ok, value}` and returns that. Raises (or returns
    `{:error, output}` with `raise: false`) when the process exits first or after 60 s.
    """
    def await(this, fun, opts \\ []) do
      result = GenServer.call(this, {:await, fun}, :infinity)

      case {result, opts[:raise]} do
        {_, false} -> result
        {{:ok, value}, _} -> value
        {{:error, output}, _} -> raise "child process: #{output}"
      end
    end

    @doc "Waits for the exit status (`:timeout` after `timeout` ms)."
    def exit_code(this, timeout \\ :infinity) do
      GenServer.call(this, :exit_code, timeout)
    catch
      :exit, {:timeout, _} -> :timeout
    end

    @doc "`process.kill(pid, signal)`: sends the signal (`\"SIGINT\"`, ...) to the process."
    def kill(this, signal) do
      if os_pid = GenServer.call(this, :alive_os_pid),
        do: System.cmd("kill", ["-" <> String.replace_prefix(signal, "SIG", ""), "#{os_pid}"], stderr_to_stdout: true)

      :ok
    end

    def stop(this), do: GenServer.stop(this)

    @impl true
    def init({program, args, env}) do
      env =
        for {name, value} <- Map.merge(%{"PWTEST_UNDER_TEST" => "1"}, env),
            do: {String.to_charlist(name), (value && String.to_charlist(value)) || false}

      driver_env = Enum.map(PlaywrightEx.Driver.driver_env(), fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)

      port =
        Port.open({:spawn_executable, program}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          env: env ++ driver_env
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      {:ok, %{port: port, os_pid: os_pid, output: "", status: nil, awaits: [], exits: []}}
    end

    @impl true
    def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}
    def handle_call(:alive_os_pid, _from, state), do: {:reply, if(state.status == nil, do: state.os_pid), state}
    def handle_call(:output, _from, state), do: {:reply, state.output, state}

    def handle_call({:await, fun}, from, state) do
      case fun.(state.output) do
        {:ok, value} ->
          {:reply, {:ok, value}, state}

        nil when state.status != nil ->
          {:reply, {:error, state.output}, state}

        nil ->
          Process.send_after(self(), {:await_timeout, from}, 60_000)
          {:noreply, %{state | awaits: [{from, fun} | state.awaits]}}
      end
    end

    def handle_call(:exit_code, from, state) do
      if state.status, do: {:reply, state.status, state}, else: {:noreply, %{state | exits: [from | state.exits]}}
    end

    @impl true
    def handle_info({port, {:data, data}}, %{port: port} = state) do
      state = %{state | output: state.output <> data}

      awaits =
        Enum.reject(state.awaits, fn {from, fun} ->
          case fun.(state.output) do
            {:ok, value} -> GenServer.reply(from, {:ok, value})
            nil -> false
          end
        end)

      {:noreply, %{state | awaits: awaits}}
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
      for {from, _} <- state.awaits, do: GenServer.reply(from, {:error, state.output})
      for from <- state.exits, do: GenServer.reply(from, status)
      {:noreply, %{state | status: status, awaits: [], exits: []}}
    end

    def handle_info({:await_timeout, from}, state) do
      {timed_out, awaits} = Enum.split_with(state.awaits, &(elem(&1, 0) == from))
      for _ <- timed_out, do: GenServer.reply(from, {:error, "timeout; output: " <> state.output})
      {:noreply, %{state | awaits: awaits}}
    end

    @impl true
    def terminate(_reason, state) do
      # Like upstream's `process.on('exit', killProcessGroup)`: no child outlives the tests.
      if state.status == nil, do: System.cmd("kill", ["-9", "#{state.os_pid}"], stderr_to_stdout: true)
      :ok
    end
  end

  defmodule RunServer do
    @moduledoc """
    `run-server` started with the pinned driver (as `PlaywrightEx.Driver` runs `run-driver`).

    Deviation: `close/1` kills the process with `kill -9`: `run-server` ignores SIGTERM, and
    an Erlang port can only close stdin. It exits when its stdin closes, see
    `PlaywrightEx.RemoteServer.ChildProcess`: when the test BEAM dies, or the test process that
    owns the port exits (before the `on_exit` callbacks).
    """
    alias PlaywrightEx.RemoteServer.ChildProcess

    defstruct [:port, :os_pid, :_wsEndpoint]

    def start(options \\ %{}) do
      {program, args} = PlaywrightEx.Driver.ensure_installed()
      command = args ++ ["run-server"]
      command = if options[:mode] == "extension", do: command ++ ["--mode=extension"], else: command

      command =
        if options[:artifactsDir], do: command ++ ["--artifacts-dir=#{options.artifactsDir}"], else: command

      command = if options[:unsafe], do: command ++ ["--unsafe"], else: command

      {program, command, watchdog_env} = ChildProcess.exit_on_stdin_eof({program, command})

      # Upstream inherits the test runner's environment (PWTEST_UNDER_TEST=1); `nil` unsets.
      env =
        for {name, value} <-
              %{"PWTEST_UNDER_TEST" => "1"} |> Map.merge(watchdog_env) |> Map.merge(options[:env] || %{}),
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
