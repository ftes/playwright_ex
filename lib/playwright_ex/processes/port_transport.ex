defmodule PlaywrightEx.PortTransport do
  @moduledoc """
  GenServer that owns the Erlang Port to Playwright node.js server and handles message framing.

  A single `Port` response can contain multiple Playwright messages and/or a fraction of a message.
  The remaining fraction is stored in `buffer` and continued in the next `Port` response.

  This process:
  - Opens and owns the Erlang Port
  - Receives `{port, {:data, binary}}` messages automatically
  - Parses and assembles complete messages from potentially fragmented Port data
  - Forwards complete messages to the Connection process as `{:playwright_msg, msg}`
  - Handles sending messages to Playwright via `Port.command/2`
  - Serializes message terms <-> JSON (underscore_case <-> camelCase, atom <-> string)
  """
  @behaviour PlaywrightEx.Transport

  use GenServer

  alias PlaywrightEx.Connection
  alias PlaywrightEx.Serialization

  defstruct port: nil,
            remaining: 0,
            buffer: "",
            connection_name: Connection

  @default_name __MODULE__

  @doc """
  Start the PortTransport and link it to the connection process.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:executable, :name, :connection_name, env: %{}])
    name = Keyword.get(opts, :name, @default_name)
    check_version(opts[:executable])
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @impl PlaywrightEx.Transport
  def post(name \\ @default_name, msg) do
    GenServer.cast(name, {:post, msg})
  end

  @impl GenServer
  def init(%{executable: executable, env: env} = opts) do
    env = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    port = Port.open({:spawn_executable, executable}, [:binary, :stderr_to_stdout, args: ["run-driver"], env: env])
    connection_name = Map.get(opts, :connection_name, Connection)
    {:ok, %__MODULE__{port: port, connection_name: connection_name}}
  end

  @impl GenServer
  def handle_cast({:post, msg}, state) do
    frame = to_json(msg)
    length = byte_size(frame)
    padding = <<length::utf32-little>>
    Port.command(state.port, padding <> frame)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {remaining, buffer, frames} = parse(data, state.remaining, state.buffer, [])

    for frame <- frames do
      Connection.handle_playwright_msg(state.connection_name, from_json(frame))
    end

    {:noreply, %{state | buffer: buffer, remaining: remaining}}
  end

  defp parse(data, remaining, buffer, frames)

  defp parse(<<head::unsigned-little-integer-size(32)>>, 0, "", frames) do
    {head, "", frames}
  end

  defp parse(<<head::unsigned-little-integer-size(32), data::binary>>, 0, "", frames) do
    parse(data, head, "", frames)
  end

  defp parse(<<data::binary>>, remaining, buffer, frames) when byte_size(data) == remaining do
    {0, "", frames ++ [buffer <> data]}
  end

  defp parse(<<data::binary>>, remaining, buffer, frames) when byte_size(data) > remaining do
    <<frame::size(^remaining)-binary, tail::binary>> = data
    parse(tail, 0, "", frames ++ [buffer <> frame])
  end

  defp parse(<<data::binary>>, remaining, buffer, frames) when byte_size(data) < remaining do
    {remaining - byte_size(data), buffer <> data, frames}
  end

  defp to_json(msg) do
    msg
    |> Map.update(:method, nil, &Serialization.camelize/1)
    |> Serialization.deep_key_camelize()
    |> JSON.encode!()
  end

  defp from_json(frame) do
    frame
    |> JSON.decode!()
    |> Serialization.deep_key_underscore()
    |> Map.update(:method, nil, &Serialization.underscore/1)
  end

  defp check_version(executable) do
    {"Version " <> version, 0} = executable |> Path.expand() |> System.cmd(~w(--version))
    version = version |> String.trim() |> Version.parse!()
    recommended = PlaywrightEx.recommended_min_version()

    if Version.compare(version, recommended) == :lt do
      IO.warn("Playwright version #{version} is below recommended #{recommended}")
    end
  end
end
