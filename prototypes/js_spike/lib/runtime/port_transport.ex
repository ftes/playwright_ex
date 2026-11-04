defmodule PlaywrightJS.Runtime.PortTransport do
  @moduledoc """
  Adapted from `PlaywrightEx.PortTransport` (equivalent of `utils/pipeTransport.ts`, not
  counted towards equivalence): length-prefixed JSON over a Port running
  `node cli.js run-driver`.

  Outgoing: channel owners become `{guid}` (what the generated validators do in JS) and
  `nil` (JS `undefined`) properties are dropped. Incoming: object keys become atoms so
  ported code can write `result.response` like JS.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  def send_message(pid, message), do: GenServer.cast(pid, {:send, message})

  def close(pid), do: GenServer.cast(pid, :close)

  @impl true
  def init(%{cli: cli, on_message: on_message, on_close: on_close} = opts) do
    node = System.find_executable("node") || raise "node not found in PATH"
    env = Enum.map(Map.get(opts, :env, %{}), fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    port = Port.open({:spawn_executable, node}, [:binary, :exit_status, args: [cli, "run-driver"], env: env])
    {:ok, %{port: port, buffer: "", on_message: on_message, on_close: on_close}}
  end

  @impl true
  def handle_cast({:send, message}, state) do
    frame = message |> to_wire() |> JSON.encode!()
    Port.command(state.port, <<byte_size(frame)::little-unsigned-32, frame::binary>>)
    {:noreply, state}
  end

  def handle_cast(:close, state) do
    Port.close(state.port)
    state.on_close.()
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {buffer, frames} = parse_frames(state.buffer <> data, [])
    Enum.each(frames, fn frame -> state.on_message.(from_json(frame)) end)
    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state) do
    state.on_close.()
    {:stop, :normal, state}
  end

  defp parse_frames(<<length::little-unsigned-32, payload::binary>> = buffer, frames) do
    case payload do
      <<frame::binary-size(^length), rest::binary>> -> parse_frames(rest, [frame | frames])
      _ -> {buffer, Enum.reverse(frames)}
    end
  end

  defp parse_frames(buffer, frames), do: {buffer, Enum.reverse(frames)}

  defp from_json(frame) do
    {value, :ok, ""} =
      :json.decode(frame, :ok, %{
        null: nil,
        object_push: fn key, value, acc -> [{String.to_atom(key), value} | acc] end
      })

    value
  end

  defp to_wire(%{__struct__: _, guid: guid, conn: _}) when is_binary(guid), do: %{guid: guid}
  defp to_wire(%Regex{} = regex), do: raise(ArgumentError, "cannot send regex over the wire: #{inspect(regex)}")
  defp to_wire(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> to_wire()
  defp to_wire(map) when is_map(map), do: for({k, v} <- map, v != nil, into: %{}, do: {k, to_wire(v)})
  defp to_wire(list) when is_list(list), do: Enum.map(list, &to_wire/1)
  defp to_wire(other), do: other
end
