defmodule PlaywrightEx.Runtime.Baton do
  @moduledoc """
  Runtime support (not ported from upstream): the JavaScript thread as a token.

  One baton exists per driver (nested `connect()` connections share it). Only the process
  holding it runs client code ("synchronous JS"): ported functions, protocol dispatch,
  listeners, promise reactions, timers. `await` releases it and re-acquires it once the
  awaited promise settles, so callers overlap while they await, as async calls do on
  Node's single thread.

  The server process only schedules; it never runs client code:

    * microtasks: processes whose awaited promise settled (resume first, like JS
      continuations that run before the next macrotask),
    * macrotasks: callers entering the API (`acquire`), incoming protocol messages and
      timers (`post`, run by the executor process).

  Handoff: `spawn_handoff/1` runs a function in a fresh process that holds the baton on
  behalf of the caller until the function returns or awaits; then the caller continues
  (listener invocation, `bindingCall`, route handlers, async functions called without
  `await`). Promises settled by the holder are passed along with the token
  (`ready/1`), so wake-ups are causally ordered without shared state.

  Process dictionary:
    * `:pw_baton` - `nil` (not holding), `{:server, server}` (granted by the server),
      `{:delegated, parent, ref, server}` (handed over by `parent`, yield back to it)
    * `:pw_ready` - processes made ready while holding (reversed)
    * `:pw_scope` - inside a public API call (keep the baton until it returns)

  Failures: the server monitors every holder; if one dies, the baton is reclaimed and the
  next task is granted. A handoff parent monitors the child and continues when it dies.
  Exceptions in listeners/tasks are logged (Node: uncaught exception). Heap state written
  before the crash is kept, like a JS exception thrown halfway through a function.
  """
  use GenServer

  alias PlaywrightEx.Runtime.Zones

  require Logger

  ## Client API

  defstruct [:pid, :table]

  @key :pw_baton
  @ready :pw_ready
  @scope :pw_scope

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "The baton struct (token server + heap table) of a running baton server."
  def get(server), do: GenServer.call(server, :baton)

  @doc "A baton struct for another connection on the same driver: same token, own heap table."
  def new_heap(%__MODULE__{pid: pid}), do: GenServer.call(pid, :new_heap)

  def held?, do: Process.get(@key) != nil

  @doc "Run `fun` holding the baton (reentrant). Inside an API scope the baton is kept until the scope ends."
  def with_baton(%__MODULE__{} = baton, fun) do
    cond do
      held?() ->
        fun.()

      Process.get(@scope) ->
        acquire(baton)
        fun.()

      true ->
        acquire(baton)

        try do
          fun.()
        after
          release()
        end
    end
  end

  @doc """
  Public API entry (see `PlaywrightEx.Runtime.Api`): acquire eagerly when the receiver
  carries a baton, otherwise on first use; release when the outermost API call returns.
  """
  def api_scope(receiver, fun) do
    if held?() or Process.get(@scope) do
      fun.()
    else
      Process.put(@scope, true)

      try do
        if baton = find(receiver), do: acquire(baton)
        fun.()
      after
        Process.delete(@scope)
        if held?(), do: release()
      end
    end
  end

  # Channel owners carry the baton; value objects (Locator, FrameLocator) reach it through their frame/page.
  defp find(%{baton: %__MODULE__{} = baton}), do: baton
  defp find(%{_frame: frame}), do: find(frame)
  defp find(%{_page: page}), do: find(page)
  defp find(_), do: nil

  def acquire(%__MODULE__{pid: pid}) do
    :ok = GenServer.call(pid, :acquire, :infinity)
    Process.put(@key, {:server, pid})
    :ok
  end

  @doc "Give the baton back: to the server, or to the process that handed it over."
  def release do
    case Process.delete(@key) do
      {:server, server} -> GenServer.cast(server, {:release, self(), take_ready()})
      {:delegated, parent, ref, _server} -> send(parent, {:pw_yield, ref, take_ready()})
      nil -> :ok
    end
  end

  @doc "Schedule `pid` (suspended in `suspend/0`) to resume once the holder releases."
  def ready(pid) do
    if !held?(), do: raise("Baton.ready/1 outside the baton")
    Process.put(@ready, [pid | Process.get(@ready, [])])
  end

  defp take_ready, do: Enum.reverse(Process.delete(@ready) || [])

  @doc """
  `await`: the caller registered itself as a waiter (see `ready/1`) while holding the
  baton; release it and block until the server grants it again.
  """
  def suspend do
    if Process.get(:pw_executor), do: raise("await is not allowed while dispatching (listener code must be handed off)")
    server = server!()
    mon = Process.monitor(server)
    notify_async_parent()
    release()

    receive do
      {:pw_grant, ^server} ->
        Process.demonitor(mon, [:flush])
        Process.put(@key, {:server, server})

      {:DOWN, ^mon, :process, _, reason} ->
        exit({:baton_down, reason})
    end

    :ok
  end

  defp server! do
    case Process.get(@key) do
      nil -> raise "not holding the baton"
      state -> elem(state, tuple_size(state) - 1)
    end
  end

  @doc "Block on non-baton work (e.g. a Task) without holding the baton; re-acquire afterwards."
  def blocking(fun) do
    case Process.get(@key) do
      nil ->
        fun.()

      state ->
        server = elem(state, tuple_size(state) - 1)
        notify_async_parent()
        release()

        try do
          fun.()
        after
          :ok = GenServer.call(server, :acquire, :infinity)
          Process.put(@key, {:server, server})
        end
    end
  end

  @doc """
  Run `fun` in a fresh process that holds the baton until `fun` returns or awaits; then
  return to the caller (who must hold the baton). Zones travel with the process.
  """
  def spawn_handoff(fun) do
    server = server!()

    parent = self()
    ref = make_ref()
    zone = Zones.current()

    {pid, mon} =
      spawn_monitor(fn ->
        Zones.restore(zone)
        Process.put(@key, {:delegated, parent, ref, server})

        try do
          fun.()
        catch
          kind, reason ->
            Logger.error("Uncaught in handed-off callback: " <> Exception.format(kind, reason, __STACKTRACE__))
        end

        ## Server

        release()
      end)

    receive do
      {:pw_yield, ^ref, ready} ->
        Process.demonitor(mon, [:flush])
        Process.put(@ready, Enum.reverse(ready, Process.get(@ready, [])))

      {:DOWN, ^mon, :process, _, reason} ->
        Logger.error("Handed-off callback died holding the baton: #{inspect(reason)}")
    end

    pid
  end

  # Promise.async/1 (no baton): the parent waits for the first suspension point.
  def notify_async_parent do
    case Process.delete(:pw_async_parent) do
      {parent, ref} -> send(parent, {ref, :suspended})
      nil -> :ok
    end
  end

  @doc "Queue `fun` as a macrotask (run by the executor under the baton)."
  def post(%__MODULE__{pid: pid}, fun), do: GenServer.cast(pid, {:post, fun})

  # setTimeout / clearTimeout
  def set_timeout(%__MODULE__{pid: pid}, fun, ms), do: Process.send_after(pid, {:post, fun}, ms)
  def clear_timeout(nil), do: :ok
  def clear_timeout(ref), do: Process.cancel_timer(ref) && :ok

  @doc "Hold-time statistics per grant kind: %{kind => %{count, total_us, max_us}}."
  def stats(%__MODULE__{pid: pid}), do: GenServer.call(pid, :stats)
  def reset_stats(%__MODULE__{pid: pid}), do: GenServer.call(pid, :reset_stats)

  @impl true
  def init(_opts) do
    table = new_table()
    server = self()
    executor = spawn_link(fn -> executor_loop(server) end)

    {:ok,
     %{
       baton: %__MODULE__{pid: self(), table: table},
       holder: nil,
       mon: nil,
       since: nil,
       kind: nil,
       micro: :queue.new(),
       macro: :queue.new(),
       executor: executor,
       stats: %{}
     }}
  end

  defp new_table, do: :ets.new(:playwright_ex_heap, [:set, :public, read_concurrency: true, write_concurrency: true])

  @impl true
  def handle_call(:baton, _from, s), do: {:reply, s.baton, s}
  def handle_call(:new_heap, _from, s), do: {:reply, %__MODULE__{pid: self(), table: new_table()}, s}
  def handle_call(:stats, _from, s), do: {:reply, s.stats, s}
  def handle_call(:reset_stats, _from, s), do: {:reply, :ok, %{s | stats: %{}}}
  def handle_call(:acquire, from, s), do: {:noreply, s |> enqueue({:call, from}) |> schedule()}

  @impl true
  def handle_cast({:release, pid, ready}, %{holder: pid} = s) do
    Process.demonitor(s.mon, [:flush])
    s = record(s)
    s = %{s | holder: nil, mon: nil, micro: Enum.reduce(ready, s.micro, &:queue.in/2)}
    {:noreply, schedule(s)}
  end

  def handle_cast({:release, pid, _ready}, s) do
    Logger.error("Baton released by #{inspect(pid)}, but held by #{inspect(s.holder)}")
    {:noreply, s}
  end

  def handle_cast({:post, fun}, s), do: {:noreply, s |> enqueue({:task, fun}) |> schedule()}

  @impl true
  def handle_info({:post, fun}, s), do: {:noreply, s |> enqueue({:task, fun}) |> schedule()}

  def handle_info({:DOWN, mon, :process, pid, reason}, %{mon: mon} = s) do
    Logger.error("Baton holder #{inspect(pid)} died: #{inspect(reason)}; reclaiming")
    {:noreply, schedule(%{record(s) | holder: nil, mon: nil})}
  end

  def handle_info(_other, s), do: {:noreply, s}

  defp enqueue(s, item), do: %{s | macro: :queue.in(item, s.macro)}

  defp schedule(%{holder: nil} = s) do
    case :queue.out(s.micro) do
      {{:value, pid}, micro} ->
        send(pid, {:pw_grant, self()})
        grant(%{s | micro: micro}, pid, :resume)

      {:empty, _} ->
        case :queue.out(s.macro) do
          {{:value, {:call, {pid, _} = from}}, macro} ->
            GenServer.reply(from, :ok)
            grant(%{s | macro: macro}, pid, :call)

          {{:value, {:task, fun}}, macro} ->
            send(s.executor, {:pw_run, fun})
            grant(%{s | macro: macro}, s.executor, :task)

          {:empty, _} ->
            s
        end
    end
  end

  defp schedule(s), do: s

  defp grant(s, pid, kind),
    do: %{s | holder: pid, mon: Process.monitor(pid), since: System.monotonic_time(:microsecond), kind: kind}

  defp record(%{since: nil} = s), do: s

  defp record(s) do
    us = System.monotonic_time(:microsecond) - s.since

    stats =
      Map.update(s.stats, s.kind, %{count: 1, total_us: us, max_us: us}, fn st ->
        %{count: st.count + 1, total_us: st.total_us + us, max_us: max(st.max_us, us)}
      end)

    %{s | stats: stats, since: nil}
  end

  defp executor_loop(server) do
    Process.put(:pw_executor, true)

    receive do
      {:pw_run, fun} ->
        Process.put(@key, {:server, server})

        try do
          fun.()
        catch
          kind, reason ->
            Logger.error("Uncaught in event loop task: " <> Exception.format(kind, reason, __STACKTRACE__))
        end

        release()
    end

    executor_loop(server)
  end
end
