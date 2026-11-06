defmodule PlaywrightEx.ClientProcess do
  @moduledoc """
  The Elixir client in a child process, for `tests/library/signals.spec.ts`: its
  `startRemoteServer('launchServer')` fixture for the Elixir client, as Python's
  `tests/helpers/client_process.py` does it for the Python client.

  Upstream's `RemoteServer` runs a Node.js process that launches the browser, and the tests send
  it signals. Here the child is a BEAM that runs `client_process_impl.exs` (next to this file),
  which launches the browser with the client: the BEAM starts the driver, the driver launches the
  browser. `+Bd`: SIGINT ends the BEAM (no BREAK menu).

  The child halts when its stdin closes (`halt_on_stdin_eof/0`): the test BEAM went away, see
  `PlaywrightEx.RemoteServer.ChildProcess`.

  `out/2` returns what the child reported, like `RemoteServer.out()`. The script prints
  `tempDir`, `ready` and `closed`; the rest comes from the driver's `pw:browser` log (the child
  runs with `DEBUG=pw:browser`): `pid` of the browser process, `exitCode` and `signal` of its
  exit, which upstream gets from the `close` event of `BrowserServer`.
  """
  alias PlaywrightEx.RemoteServer.ChildProcess

  defstruct [:_process, :_temp_dir]

  defp regex("pid"), do: ~r/<launched> pid=(\d+)/
  defp regex("exitCode"), do: ~r/<process did exit: exitCode=([^,]+), signal=[^>]+>/
  defp regex("signal"), do: ~r/<process did exit: exitCode=[^,]+, signal=([^>]+)>/
  defp regex(key), do: ~r/\(#{Regex.escape(key)}=>([^()]+)\)/

  def start(browser_name, options \\ %{}) do
    # A short path: the browser's user data dir goes there, and the socket of Chrome's
    # ProcessSingleton inside it has at most 104 characters.
    temp_dir = Path.join("/tmp", "pw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    options = Map.merge(%{browserTypeName: browser_name}, Map.new(options))
    ebin = Path.dirname(:code.which(PlaywrightEx))
    script = Path.join(__DIR__, "client_process_impl.exs")

    process =
      ChildProcess.start(
        System.find_executable("elixir"),
        ["--erl", "+Bd", "-pa", ebin, script, JSON.encode!(options)],
        %{"DEBUG" => "pw:browser", "TMPDIR" => temp_dir}
      )

    this = %__MODULE__{_process: process, _temp_dir: temp_dir}
    # Upstream waits until the page of `url` is open in the browser.
    if !options[:startStopAndRunHttp], do: out(this, "ready")
    this
  end

  def out(this, key) do
    regex = regex(key)

    ChildProcess.await(this._process, fn output ->
      case Regex.run(regex, output) do
        [_, value] -> {:ok, value}
        nil -> nil
      end
    end)
  end

  def child(this), do: ChildProcess.pid(this._process)

  @doc "`process.kill(pid, signal)`: sends the signal to the BEAM only."
  def kill(this, signal), do: ChildProcess.kill(this._process, signal)

  @doc """
  Waits until the BEAM exits and the driver closes its output (the port's exit status comes
  after both). A signal `N` that ends the BEAM gives `128 + N`.
  """
  def child_exit_code(this), do: ChildProcess.exit_code(this._process)

  @doc """
  For the child: halts the BEAM when its stdin, the parent's end of the port's pipe, closes (the
  parent went away, however it died). The driver then exits with its own stdin and closes the
  browser.
  """
  def halt_on_stdin_eof do
    spawn(fn -> read_stdin_until_eof() end)
  end

  defp read_stdin_until_eof do
    case IO.binread(:stdio, 1024) do
      :eof -> System.halt(0)
      data when is_binary(data) -> read_stdin_until_eof()
      _error -> :ok
    end
  end

  @doc "Kills what is left: the BEAM (the driver exits with its stdin)."
  def close(this) do
    if Process.alive?(this._process) do
      ChildProcess.kill(this._process, "SIGKILL")
      ChildProcess.exit_code(this._process, 30_000)
      ChildProcess.stop(this._process)
    end

    File.rm_rf(this._temp_dir)
    :ok
  end
end
