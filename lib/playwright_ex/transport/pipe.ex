defmodule PlaywrightEx.Transport.Pipe do
  @upstream "packages/utils/pipeTransport.ts"
  @max_hold_ms 20
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
    * Messages sent under the baton are queued and written together when the holder releases
      it (the end of the JS tick, `PlaywrightEx.Runtime.EventLoop.at_release/2`), so the driver
      reads a tick's messages at once: `const p = page.evaluate(...); page.waitForEvent('console')`
      subscribes before the console event can be dispatched. Upstream writes each message right
      away, microseconds apart; here a tick's calls run in several processes and the gap could
      exceed the driver's round trip to the browser. A holder blocked on other work has its
      messages written after #{@max_hold_ms}ms.
  """
  use GenServer

  alias PlaywrightEx.Runtime.EventLoop

  @doc """
  Options: `:executable` (`{program, args}`, see `PlaywrightEx.Driver.executable/1`),
  `:env`, `:on_message` (1-arity, called in this process), `:on_close` (0-arity, called
  once when the driver exits or `close/1` is called).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  # send  -- ported as send_message/2 (Kernel.send/2)
  def send_message(pid, message) do
    if EventLoop.held?() do
      GenServer.cast(pid, {:queue, message})
      EventLoop.at_release({__MODULE__, pid}, fn -> GenServer.cast(pid, :flush) end)
    else
      GenServer.cast(pid, {:send, message})
    end
  end

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
       size: 0,
       queue: [],
       timer: nil
     }}
  end

  @impl true
  def handle_cast({_send, _message}, %{closed: true} = state), do: {:noreply, state}
  def handle_cast({:send, message}, state), do: {:noreply, state |> queue(message) |> flush()}

  def handle_cast({:queue, message}, state) do
    state = queue(state, message)
    {:noreply, if(state.timer, do: state, else: %{state | timer: :erlang.start_timer(@max_hold_ms, self(), :flush)})}
  end

  def handle_cast(:flush, state), do: {:noreply, flush(state)}

  @impl true
  def handle_call(:close, _from, state) do
    state = flush(state)
    if !state.closed, do: Port.close(state.port)
    {:stop, :normal, :ok, on_close(state)}
  end

  defp queue(state, message) do
    data = message |> to_json() |> JSON.encode_to_iodata!()
    %{state | queue: [state.queue, <<IO.iodata_length(data)::little-unsigned-32>>, data]}
  end

  defp flush(%{queue: []} = state), do: state

  defp flush(state) do
    if state.timer, do: :erlang.cancel_timer(state.timer)
    if !state.closed, do: Port.command(state.port, state.queue)
    %{state | queue: [], timer: nil}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state), do: {:noreply, _dispatch(state, data)}
  def handle_info({:timeout, timer, :flush}, %{timer: timer} = state), do: {:noreply, flush(%{state | timer: nil})}
  # A timeout that fired while its batch was flushed.
  def handle_info({:timeout, _timer, :flush}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state), do: {:stop, :normal, on_close(state)}

  defp on_close(%{closed: true} = state), do: state

  defp on_close(state) do
    state.on_close.()
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
        state.on_message.(JSON.decode!(message))
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
