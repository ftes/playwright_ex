defmodule PlaywrightEx.Transport.Pipe do
  @upstream "packages/utils/pipeTransport.ts"
  @moduledoc """
  Port of `#{@upstream}`: little-endian length-prefixed messages over the driver's
  stdin/stdout. The process also spawns the driver, as `outofprocess.ts` does with
  `childProcess.fork(cli.js, ['run-driver'])`.

  Deviations:

    * JSON encoding and decoding happen in this process, off the connection (upstream:
      `JSON.stringify`/`JSON.parse` on the JS thread). `send_message/2` takes a term,
      `on_message` receives one. Like `JSON.stringify`, `nil` (`undefined`) properties are
      dropped and `:null` is sent as `null`; like `JSON.parse`, an incoming `null` is `:null`.
      Object keys of incoming messages stay strings: the protocol validators turn known keys
      into atoms.
    * Frames are accumulated as iodata, so a large message costs one copy instead of one
      concatenation per chunk.
    * The connection process (`PlaywrightEx.Runtime.Conn`) hands over the messages of one of its
      turns together (`send_messages/2`), written with one port command.
    * `on_close` gets the driver's exit status (`nil` after `close/1`), for the log of a lost
      driver (`PlaywrightEx.OutOfProcess`); upstream's `onclose` takes none.
    * A message that cannot be encoded (a string that is not UTF-8, a term JSON has no form for)
      is not written, and this process lives on: a call is answered with an error through
      `on_message`, so only it fails; another message is logged. Upstream, `JSON.stringify`
      throws in the caller.
    * The driver inherits the VM's stderr, as a port can't pipe it separately; upstream pipes it
      and forwards it. Node restores the terminal's settings when it exits, which resets the
      shell's line editor (↑ prints `OA`) if the driver outlives the VM. So `close/1` waits until
      the driver has exited, at most 30 s (its force-exit limit), while the caller still owns the
      terminal; upstream's `stop()` waits for the pipe's close only.
  """
  use GenServer

  require Logger

  # gracefullyProcessExitDoNotHang (processLauncher.ts): the driver force-exits 30 s after its
  # stdin closes.
  @exit_timeout 30_000

  @doc """
  Options: `:executable` (`{program, args}`, see `PlaywrightEx.Driver.executable/1`),
  `:env`, `:on_message` (1-arity, called in this process), `:on_close` (1-arity, called
  once when the driver exits, with its exit status, or `close/1` is called, with `nil`).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  # send  -- ported as send_message/2 (Kernel.send/2)
  def send_message(pid, message), do: send_messages(pid, [message])

  @doc "Writes `messages` in order, with one port command."
  def send_messages(pid, messages), do: GenServer.cast(pid, {:send, messages})

  @doc "Closes the pipe and waits until the driver has exited, at most 30 s (see the moduledoc)."
  def close(pid), do: GenServer.call(pid, :close, :infinity)

  @impl true
  def init(%{executable: {program, args}, on_message: on_message, on_close: on_close} = opts) do
    env = Enum.map(Map.get(opts, :env, []), fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    port = Port.open({:spawn_executable, program}, [:binary, :exit_status, args: args ++ ["run-driver"], env: env])

    {:ok,
     %{
       port: port,
       on_message: on_message,
       on_close: on_close,
       closed: false,
       header: "",
       bytes_left: 0,
       chunks: [],
       size: 0,
       queue: []
     }}
  end

  @impl true
  def handle_cast({_send, _message}, %{closed: true} = state), do: {:noreply, state}
  def handle_cast({:send, messages}, state), do: {:noreply, messages |> Enum.reduce(state, &queue(&2, &1)) |> flush()}

  @impl true
  def handle_call(:close, _from, state) do
    state = flush(state)
    if !state.closed, do: close_port(state.port)
    {:stop, :normal, :ok, on_close(state, nil)}
  end

  # No os pid: the driver has exited, its exit status is not handled yet.
  defp close_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        Port.close(port)
        if match?({:unix, _}, :os.type()), do: await_exit(os_pid, System.monotonic_time(:millisecond) + @exit_timeout)

      nil ->
        :ok
    end
  end

  # A port can't close the driver's stdin alone and reports no exit status after Port.close/1, so
  # this polls the os pid (`kill` is a shell builtin).
  defp await_exit(os_pid, deadline) do
    {_, status} = System.cmd("/bin/sh", ["-c", ~s(kill -0 "$1" 2>/dev/null), "sh", to_string(os_pid)])

    if status == 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_exit(os_pid, deadline)
    end
  end

  defp queue(state, message) do
    data = message |> to_json() |> JSON.encode_to_iodata!()
    %{state | queue: [state.queue, <<IO.iodata_length(data)::little-unsigned-32>>, data]}
  rescue
    e ->
      unencodable(state, message, Exception.message(e))
      state
  end

  # The driver never answers `__waitInfo__`.
  defp unencodable(state, %{id: id, method: method}, reason) when id != nil and method != "__waitInfo__" do
    error = %{"message" => "Message cannot be encoded as JSON: #{reason}", "name" => "Error", "stack" => ""}
    state.on_message.(%{"id" => id, "error" => %{"error" => error}})
  end

  defp unencodable(_state, message, reason),
    do:
      Logger.error(
        "Playwright message dropped, it cannot be encoded as JSON (#{reason}): #{inspect(message, limit: 20, printable_limit: 200)}"
      )

  defp flush(%{queue: []} = state), do: state

  defp flush(state) do
    if !state.closed, do: Port.command(state.port, state.queue)
    %{state | queue: []}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state), do: {:noreply, _dispatch(state, data)}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state), do: {:stop, :normal, on_close(state, status)}

  defp on_close(%{closed: true} = state, _status), do: state

  defp on_close(state, status) do
    state.on_close.(status)
    %{state | closed: true}
  end

  # Reading the 4-byte length.
  defp _dispatch(%{bytes_left: 0} = state, data) do
    case state.header <> data do
      <<length::little-unsigned-32, rest::binary>> -> _dispatch(%{state | header: "", bytes_left: length}, rest)
      header -> %{state | header: header}
    end
  end

  # Reading the message body.
  defp _dispatch(state, data) do
    need = state.bytes_left - state.size

    case data do
      <<part::binary-size(^need), rest::binary>> ->
        message = IO.iodata_to_binary(Enum.reverse([part | state.chunks]))
        state.on_message.(PlaywrightEx.Client.ClientHelper.json_parse(message))
        _dispatch(%{state | bytes_left: 0, chunks: [], size: 0}, rest)

      _ when data == "" ->
        state

      _ ->
        %{state | chunks: [data | state.chunks], size: state.size + byte_size(data)}
    end
  end

  defp to_json(nil), do: nil
  defp to_json(:null), do: nil

  defp to_json(map) when is_map(map) and not is_struct(map),
    do: for({k, v} <- map, v != nil, into: %{}, do: {k, to_json(v)})

  defp to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)
  defp to_json(other), do: other
end
