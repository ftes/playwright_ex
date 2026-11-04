# upstream: playwright/_impl/_transport.py (adapted from PlaywrightEx.PortTransport;
# transport is not counted towards equivalence)
defmodule Playwright.Impl.Transport.PipeTransport do
  @moduledoc """
  PipeTransport. The object (heap attrs: on_message, on_error_future, pid) is
  Python-shaped; the GenServer below owns the Port and *is the event loop*:
  every inbound frame is handed to `on_message` (Connection.dispatch) in this
  process, so protocol events and object mutations are serialized here just as
  on Python's asyncio loop.
  """
  use Py
  alias Asyncio.Future
  alias Playwright.Impl.Driver
  alias Playwright.Impl.Errors.TargetClosedError

  def init(loop) do
    self = Py.new(__MODULE__)
    Py.set(self, :_loop, loop)
    Py.set(self, :on_error_future, Future.new())
    Py.set(self, :on_message, fn _ -> :ok end)
    self
  end

  def connect(self) do
    {:ok, pid} = GenServer.start(__MODULE__.Server, self)
    Py.set(self, :pid, pid)
  end

  def run(_self), do: :ok

  def send(self, message), do: GenServer.cast(self[:pid], {:send, message})

  def request_stop(self), do: GenServer.cast(self[:pid], :stop)

  def wait_until_stopped(self) do
    ref = Process.monitor(self[:pid])

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      10_000 -> :ok
    end
  end

  def dispose(self), do: request_stop(self)

  defmodule Server do
    @moduledoc false
    use GenServer

    @impl true
    def init(transport) do
      {node, cli} = Driver.compute_driver_executable()
      env = for {k, v} <- Driver.get_driver_env(), do: {to_charlist(k), to_charlist(v)}

      port =
        Port.open({:spawn_executable, node}, [
          :binary,
          :exit_status,
          args: [cli, "run-driver"],
          env: env
        ])

      {:ok, %{port: port, buffer: "", transport: transport}}
    end

    @impl true
    def handle_cast({:send, msg}, state) do
      frame = JSON.encode!(msg)
      Port.command(state.port, <<byte_size(frame)::little-32>> <> frame)
      {:noreply, state}
    end

    def handle_cast(:stop, state) do
      Port.close(state.port)
      {:stop, :normal, state}
    end

    @impl true
    def handle_info({port, {:data, data}}, %{port: port} = state) do
      {buffer, frames} = parse_frames(state.buffer <> data, [])
      on_message = state.transport[:on_message]

      for frame <- frames do
        try do
          on_message.(JSON.decode!(frame))
        rescue
          e -> IO.puts(:stderr, "dispatch error: " <> Exception.format(:error, e, __STACKTRACE__))
        end
      end

      {:noreply, %{state | buffer: buffer}}
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
      f = state.transport[:on_error_future]

      unless Future.done(f),
        do: Future.set_exception(f, TargetClosedError.new("Driver exited with status #{status}"))

      {:stop, :normal, state}
    end

    defp parse_frames(<<length::little-32, payload::binary>> = buffer, frames) do
      if byte_size(payload) < length do
        {buffer, Enum.reverse(frames)}
      else
        <<frame::binary-size(^length), tail::binary>> = payload
        parse_frames(tail, [frame | frames])
      end
    end

    defp parse_frames(buffer, frames), do: {buffer, Enum.reverse(frames)}
  end
end
