defmodule PlaywrightJS.Runtime.Loop do
  @moduledoc """
  Runtime support (not ported from upstream): the JavaScript event loop.

  One `Loop` process exists per connection. It owns the heap (ETS table holding all
  mutable JS object fields) and is the only process that runs "synchronous JS":
  protocol dispatch, event listeners, promise reactions, timers. Ported `async`
  functions run in the caller's process and block on `Promise.await/1`, which is a
  `GenServer.call` into the loop that is replied to when the promise settles.
  """
  use GenServer
  require Logger

  defstruct [:pid, :table]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def get(pid), do: GenServer.call(pid, :loop)

  def in_loop?(%__MODULE__{pid: pid}), do: self() == pid

  @doc "Run `fun` on the loop and return its result (re-raises in the caller)."
  def exec(%__MODULE__{pid: pid} = loop, fun) do
    if self() == pid do
      fun.()
    else
      case GenServer.call(loop.pid, {:exec, fun}, :infinity) do
        {:ok, value} -> value
        {:error, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      end
    end
  end

  @doc "Queue `fun` as a macrotask on the loop."
  def post(%__MODULE__{pid: pid}, fun), do: send(pid, {:run, fun})

  # setTimeout / clearTimeout
  def set_timeout(%__MODULE__{pid: pid}, fun, ms), do: Process.send_after(pid, {:run, fun}, ms)
  def clear_timeout(nil), do: :ok
  def clear_timeout(ref), do: Process.cancel_timer(ref) && :ok

  @impl true
  def init(_opts) do
    table = :ets.new(:playwright_js_heap, [:set, :protected, read_concurrency: true])
    {:ok, %__MODULE__{pid: self(), table: table}}
  end

  @impl true
  def handle_call(:loop, _from, loop), do: {:reply, loop, loop}

  def handle_call({:exec, fun}, _from, loop) do
    reply =
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:error, kind, reason, __STACKTRACE__}
      end

    {:reply, reply, loop}
  end

  def handle_call({:await, promise}, from, loop) do
    PlaywrightJS.Runtime.Promise.on_settled(promise, fn result -> GenServer.reply(from, result) end)
    {:noreply, loop}
  end

  @impl true
  def handle_info({:run, fun}, loop) do
    run_task(fun)
    {:noreply, loop}
  end

  def handle_info(_other, loop), do: {:noreply, loop}

  @doc false
  def run_task(fun) do
    fun.()
  catch
    kind, reason -> Logger.error("Uncaught in event loop: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
