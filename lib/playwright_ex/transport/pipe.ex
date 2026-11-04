defmodule PlaywrightEx.Transport.Pipe do
  @upstream "packages/utils/pipeTransport.ts"
  @moduledoc """
  Port of `#{@upstream}`: little-endian length-prefixed messages over the driver's
  stdin/stdout. The process also spawns the driver, as `outofprocess.ts` does with
  `childProcess.fork(cli.js, ['run-driver'])`.

  Deviations:

    * JSON encoding and decoding happen in this process, off the baton (upstream:
      `JSON.stringify`/`JSON.parse` on the JS thread). `send_message/2` takes a term,
      `on_message` receives one. Like `JSON.stringify`, `nil` (`undefined`) properties are
      dropped and `:null` is sent as `null`. Object keys of incoming messages stay strings:
      the protocol validators turn known keys into atoms.
    * Frames are accumulated as iodata, so a large message costs one copy instead of one
      concatenation per chunk.
  """
  use GenServer

  @doc """
  Options: `:executable` (`{program, args}`, see `PlaywrightEx.Driver.executable/1`),
  `:env`, `:on_message` (1-arity, called in this process), `:on_close` (0-arity, called
  once when the driver exits or `close/1` is called).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  def send_message(pid, message), do: GenServer.cast(pid, {:send, message})

  def close(pid), do: GenServer.call(pid, :close)

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
       size: 0
     }}
  end

  @impl true
  def handle_cast({:send, _message}, %{closed: true} = state), do: {:noreply, state}

  def handle_cast({:send, message}, state) do
    data = message |> to_json() |> JSON.encode_to_iodata!()
    Port.command(state.port, [<<IO.iodata_length(data)::little-unsigned-32>>, data])
    {:noreply, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    if !state.closed, do: Port.close(state.port)
    {:stop, :normal, :ok, on_close(state)}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state), do: {:noreply, dispatch(state, data)}

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state), do: {:stop, :normal, on_close(state)}

  defp on_close(%{closed: true} = state), do: state

  defp on_close(state) do
    state.on_close.()
    %{state | closed: true}
  end

  # Reading the 4-byte length.
  defp dispatch(%{bytes_left: 0} = state, data) do
    case state.header <> data do
      <<length::little-unsigned-32, rest::binary>> -> dispatch(%{state | header: "", bytes_left: length}, rest)
      header -> %{state | header: header}
    end
  end

  # Reading the message body.
  defp dispatch(state, data) do
    need = state.bytes_left - state.size

    case data do
      <<part::binary-size(^need), rest::binary>> ->
        message = IO.iodata_to_binary(Enum.reverse([part | state.chunks]))
        state.on_message.(JSON.decode!(message))
        dispatch(%{state | bytes_left: 0, chunks: [], size: 0}, rest)

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
