defmodule PlaywrightEx.Runtime.EventLoop do
  @moduledoc """
  Runtime support (not ported from upstream): the JavaScript event loop, with its thread as a
  token (the baton).

  One loop exists per driver (nested `connect()` connections share it). Only the process
  holding its baton runs client code ("synchronous JS"): ported functions, protocol dispatch,
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

  The `%EventLoop{}` struct names the server and its own heap, for runtime objects that belong
  to no connection (promises, emitters, timeout settings); each connection gets its own heap
  table (`new_heap/1`). Ported code reaches the loop implicitly (`current!/0`), as JS has one.

  Process dictionary:
    * `:pw_baton` - `nil` (not holding), `{:server, loop}` (granted by the server),
      `{:delegated, parent, ref, loop}` (handed over by `parent`, yield back to it)
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

  defstruct [:pid, :heap]

  @key :pw_baton
  @ready :pw_ready
  @scope :pw_scope

  ## Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "The loop struct of a running loop server."
  def get(server), do: GenServer.call(server, :loop)

  @doc "A heap table for a connection on this loop (owned by the loop server)."
  def new_heap(%__MODULE__{pid: pid}), do: GenServer.call(pid, :new_heap)

  def held?, do: Process.get(@key) != nil

  @doc "The loop of the baton holder (JS: the one event loop)."
  def current! do
    case Process.get(@key) do
      nil -> raise "not holding the baton"
      state -> elem(state, tuple_size(state) - 1)
    end
  end

  @doc "Run `fun` holding the baton (reentrant). Inside an API scope the baton is kept until the scope ends."
  def with_baton(%__MODULE__{} = loop, fun) do
    cond do
      held?() ->
        fun.()

      Process.get(@scope) ->
        acquire(loop)
        fun.()

      true ->
        acquire(loop)

        try do
          fun.()
        after
          release()
        end
    end
  end

  @doc """
  Public API entry (see `PlaywrightEx.Runtime.Api`): acquire eagerly when the receiver
  carries a loop, otherwise on first use; release when the outermost API call returns.
  """
  def api_scope(receiver, fun) do
    if held?() or Process.get(@scope) do
      fun.()
    else
      Process.put(@scope, true)

      try do
        if loop = find(receiver), do: acquire(loop)
        fun.()
      after
        Process.delete(@scope)
        if held?(), do: release()
      end
    end
  end

  # Channel owners carry the loop; value objects (Locator, FrameLocator, APIResponse, Video) reach it through their
  # frame/page/context/artifact.
  defp find(%{loop: %__MODULE__{} = loop}), do: loop
  defp find(%{_frame: frame}), do: find(frame)
  defp find(%{_page: page}), do: find(page)
  defp find(%{_request: request}), do: find(request)
  defp find(%{_artifact: artifact}), do: find(artifact)
  defp find(%{_browserContext: context}), do: find(context)
  defp find(%{_channel: channel}), do: find(channel)
  defp find(_), do: nil

  def acquire(%__MODULE__{pid: pid} = loop) do
    :ok = GenServer.call(pid, :acquire, :infinity)
    Process.put(@key, {:server, loop})
    :ok
  end

  @doc "Give the baton back: to the server, or to the process that handed it over."
  def release do
    case Process.delete(@key) do
      {:server, loop} -> GenServer.cast(loop.pid, {:release, self(), take_ready()})
      {:delegated, parent, ref, _loop} -> send(parent, {:pw_yield, ref, take_ready()})
      nil -> :ok
    end
  end

  @doc "Schedule `pid` (suspended in `suspend/0`) to resume once the holder releases."
  def ready(pid) do
    if !held?(), do: raise("EventLoop.ready/1 outside the baton")
    Process.put(@ready, [pid | Process.get(@ready, [])])
  end

  defp take_ready, do: Enum.reverse(Process.delete(@ready) || [])

  @doc """
  `await`: the caller registered itself as a waiter (see `ready/1`) while holding the
  baton; release it and block until the server grants it again.
  """
  def suspend do
    if Process.get(:pw_executor), do: raise("await is not allowed while dispatching (listener code must be handed off)")
    %__MODULE__{pid: server} = loop = current!()
    mon = Process.monitor(server)
    notify_async_parent()
    release()

    receive do
      {:pw_grant, ^server} ->
        Process.demonitor(mon, [:flush])
        Process.put(@key, {:server, loop})

      {:DOWN, ^mon, :process, _, reason} ->
        exit({:baton_down, reason})
    end

    :ok
  end

  @doc "Block on non-baton work (e.g. a Task) without holding the baton; re-acquire afterwards."
  def blocking(fun) do
    if held?() do
      loop = current!()
      notify_async_parent()
      release()

      try do
        fun.()
      after
        acquire(loop)
      end
    else
      fun.()
    end
  end

  @doc """
  Run `fun` in a fresh process that holds the baton until `fun` returns or awaits; then
  return to the caller (who must hold the baton). Zones travel with the process.
  """
  def spawn_handoff(fun) do
    loop = current!()

    parent = self()
    ref = make_ref()
    zone = Zones.current_zone()

    {pid, mon} =
      spawn_monitor(fn ->
        Zones.restore(zone)
        Process.put(@key, {:delegated, parent, ref, loop})

        try do
          fun.()
        catch
          kind, reason ->
            Logger.error("Uncaught in handed-off callback: " <> Exception.format(kind, reason, __STACKTRACE__))
        end

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

  # Promise.async/1 outside the baton: the parent waits for the first suspension point.
  def notify_async_parent do
    case Process.delete(:pw_async_parent) do
      {parent, ref} -> send(parent, {ref, :suspended})
      nil -> :ok
    end
  end

  @doc "Queue `fun` as a macrotask (run by the executor under the baton)."
  def post(%__MODULE__{pid: pid}, fun), do: GenServer.cast(pid, {:post, fun})

  # setTimeout / clearTimeout
  def set_timeout(fun, ms), do: Process.send_after(current!().pid, {:post, fun}, ms)
  def clear_timeout(nil), do: :ok
  def clear_timeout(ref), do: Process.cancel_timer(ref) && :ok

  @doc "Hold-time statistics per grant kind: %{kind => %{count, total_us, max_us}}."
  def stats(%__MODULE__{pid: pid}), do: GenServer.call(pid, :stats)
  def reset_stats(%__MODULE__{pid: pid}), do: GenServer.call(pid, :reset_stats)

  ## Server

  @impl true
  def init(_opts) do
    loop = %__MODULE__{pid: self(), heap: new_table()}
    executor = spawn_link(fn -> executor_loop(loop) end)

    {:ok,
     %{
       loop: loop,
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
  def handle_call(:loop, _from, s), do: {:reply, s.loop, s}
  def handle_call(:new_heap, _from, s), do: {:reply, new_table(), s}
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

  defp executor_loop(loop) do
    Process.put(:pw_executor, true)

    receive do
      {:pw_run, fun} ->
        Process.put(@key, {:server, loop})

        try do
          fun.()
        catch
          kind, reason ->
            Logger.error("Uncaught in event loop task: " <> Exception.format(kind, reason, __STACKTRACE__))
        end

        release()
    end

    executor_loop(loop)
  end
end
