defmodule Playwright.Transport.StdIOTransport do
  @moduledoc """
  Replaces upstream Transport/StdIOTransport.cs (not counted toward equivalence).
  Adapted from PlaywrightEx.PortTransport: length-prefixed JSON over a Port running
  `node <cli.js> run-driver`. Delivers `{:transport_message, map}` / `{:transport_closed, reason}`
  to the owning connection process.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def send_async(pid, message), do: GenServer.cast(pid, {:send, message})

  def close(pid), do: GenServer.stop(pid, :normal)

  @impl GenServer
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver_cli)
    node = System.find_executable("node")
    port = Port.open({:spawn_executable, node}, [:binary, :exit_status, args: [driver, "run-driver"]])
    {:ok, %{port: port, buffer: "", owner: Keyword.fetch!(opts, :owner)}}
  end

  @impl GenServer
  def handle_cast({:send, message}, state) do
    frame = JSON.encode!(message)
    Port.command(state.port, <<byte_size(frame)::unsigned-little-integer-size(32), frame::binary>>)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {buffer, frames} = parse_frames(state.buffer <> data, [])
    for frame <- frames, do: send(state.owner, {:transport_message, JSON.decode!(frame)})
    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:transport_closed, "Driver exited with status #{status}"})
    {:stop, :normal, state}
  end

  defp parse_frames(buffer, frames) when byte_size(buffer) < 4, do: {buffer, Enum.reverse(frames)}

  defp parse_frames(<<length::unsigned-little-integer-size(32), payload::binary>> = buffer, frames) do
    if byte_size(payload) < length do
      {buffer, Enum.reverse(frames)}
    else
      <<frame::binary-size(^length), tail::binary>> = payload
      parse_frames(tail, [frame | frames])
    end
  end
end
