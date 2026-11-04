defmodule Playwright.Impl.PipeTransport do
  @moduledoc """
  Transport (not counted toward equivalence). Adapted from PlaywrightEx.PortTransport: length-prefixed JSON
  frames over an Erlang Port running `node cli.js run-driver`.

  Java's PipeTransport runs a reader thread that fills a queue which `Connection.processOneMessage()` polls.
  Here the Port delivers `{port, {:data, binary}}` to the Connection process mailbox, which *is* the queue.
  """

  defstruct [:port, buffer: ""]

  def open([executable | args], env \\ %{}) do
    env = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args, env: env])
    %__MODULE__{port: port}
  end

  def send(%__MODULE__{port: port}, message) do
    frame = JSON.encode!(message)
    Port.command(port, <<byte_size(frame)::unsigned-little-integer-size(32)>> <> frame)
  end

  # Returns {transport, [decoded_message]}.
  def receive_data(%__MODULE__{} = transport, data) do
    {buffer, frames} = parse_frames(transport.buffer <> data, [])
    {%{transport | buffer: buffer}, Enum.map(frames, &JSON.decode!/1)}
  end

  def close(%__MODULE__{port: port}) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
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
