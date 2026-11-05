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
  `roots` and `gc` belong to the collector (`PlaywrightEx.Runtime.GC`).

  Units: a unit is one run of client code with its own locals (variables the heap cannot see): a
  public API call or outermost `with_baton/2` (until it returns), a handed-off callback (until it
  returns) and a macrotask. Units in flight are listed in `roots`, so the collector frees nothing
  a suspended unit may still hold; at the end of a unit the collector may run.

  Process dictionary:
    * `:pw_baton` - `nil` (not holding), `{:server, loop}` (granted by the server),
      `{:delegated, parent, ref, loop}` (handed over by `parent`, yield back to it)
    * `:pw_ready` - processes made ready while holding (reversed)
    * `:pw_scope` - inside a public API call (keep the baton until it returns)
    * `:pw_unit` - the unit in flight (a ref, listed in `roots`)

  Failures: the server monitors every holder; if one dies, the baton is reclaimed and the
  next task is granted. A handoff parent monitors the child and continues when it dies.
  Exceptions in listeners/tasks are logged (Node: uncaught exception). Heap state written
  before the crash is kept, like a JS exception thrown halfway through a function.

  Abandoned work is dropped without a log, as pending JS work ends with its process: a process
  that died while queued or suspended is not granted the baton (a caller's `Task` killed with
  its test), and a callback or task still running when the server stops (its heaps, ETS tables
  owned by the server, are gone) is not reported as uncaught. Acquiring or awaiting on a stopped
  loop raises `PlaywrightEx.Client.Errors.TargetClosedError` ("Playwright driver closed"), as a
  call after the connection closed fails (the driver connection closes before the loop stops).
  """
  use GenServer

  alias PlaywrightEx.Runtime.GC
  alias PlaywrightEx.Runtime.Zones

  require Logger

  defstruct [:pid, :heap, :roots, :gc]

  @key :pw_baton
  @ready :pw_ready
  @scope :pw_scope
  @unit :pw_unit

  ## Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "The loop struct of a running loop server."
  def get(server), do: GenServer.call(server, :loop)

  @doc """
  A heap table for a connection on this loop (owned by the loop server). While open, its
  `:connection` object is a root of the collector; see `PlaywrightEx.Runtime.GC.close_heap/1`.
  """
  def new_heap(%__MODULE__{pid: pid}), do: GenServer.call(pid, :new_heap)

  @doc false
  def heaps(%__MODULE__{pid: pid}), do: GenServer.call(pid, :heaps)

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
        unit_scope(loop, fun)
    end
  end

  # The outermost run of client code in a caller: its result goes to code outside the baton.
  defp unit_scope(loop, fun) do
    result = fun.()
    end_unit(loop, {:returned, result})
    result
  after
    end_unit(loop, :raised)
    release()
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
        result = fun.()
        if held?(), do: end_unit(current!(), {:returned, result})
        result
      after
        Process.delete(@scope)

        if held?() do
          end_unit(current!(), :raised)
          release()
        end
      end
    end
  end

  @doc """
  The loop of a handle, `nil` for other terms. Channel owners carry the loop; value objects
  (Locator, FrameLocator, APIResponse, Video) reach it through their frame/page/context/artifact.
  """
  def find(%{loop: %__MODULE__{} = loop}), do: loop
  def find(%{_frame: frame}), do: find(frame)
  def find(%{_page: page}), do: find(page)
  def find(%{_request: request}), do: find(request)
  def find(%{_artifact: artifact}), do: find(artifact)
  def find(%{_browserContext: context}), do: find(context)
  def find(%{_channel: channel}), do: find(channel)
  def find(_), do: nil

  def acquire(%__MODULE__{pid: pid} = loop) do
    :ok = GenServer.call(pid, :acquire, :infinity)
    Process.put(@key, {:server, loop})
    if !Process.get(@unit), do: begin_unit(loop)
    :ok
  catch
    :exit, {_reason, {GenServer, :call, _}} -> raise loop_stopped()
  end

  defp begin_unit(%__MODULE__{roots: roots}) do
    unit = make_ref()
    :ets.insert(roots, {{:unit, unit}, self()})
    Process.put(@unit, unit)
  end

  # `{:returned, value}`: the value leaves the baton (rooted for this process, see `GC.root_returned/3`).
  defp end_unit(%__MODULE__{roots: roots} = loop, how) do
    case Process.delete(@unit) do
      nil ->
        :ok

      unit ->
        :ets.delete(roots, {:unit, unit})
        with {:returned, value} <- how, do: GC.root_returned(loop, self(), value)
        GC.maybe_collect(loop)
    end
  end

  defp loop_stopped, do: PlaywrightEx.Client.Errors.TargetClosedError.new("Playwright driver closed")

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

      {:DOWN, ^mon, :process, _, _reason} ->
        raise loop_stopped()
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
          begin_unit(loop)
          fun.()
        catch
          kind, reason ->
            if !abandoned?(loop),
              do: Logger.error("Uncaught in handed-off callback: " <> Exception.format(kind, reason, __STACKTRACE__))
        end

        end_unit_quietly(loop)
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

  # A failing collector must not take the callback's process down (the baton would be reclaimed).
  defp end_unit_quietly(loop) do
    end_unit(loop, :done)
  catch
    kind, reason ->
      if !abandoned?(loop), do: Logger.error("Collector failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end

  @doc """
  Queue `fun` as a macrotask (run by the executor under the baton). Until it runs, `fun` is a
  root of the collector (it may hold objects nothing else does).
  """
  def post(%__MODULE__{pid: pid} = loop, fun) do
    GenServer.cast(pid, {:post, rooted(loop, {:task, make_ref()}, fun)})
  rescue
    # The loop stopped (its tables are gone): the work is abandoned.
    ArgumentError -> :ok
  end

  # setTimeout / clearTimeout. The callback is a root until it runs or is cleared.
  def set_timeout(fun, ms) do
    %__MODULE__{pid: pid, roots: roots} = loop = current!()
    key = {:timer, make_ref()}
    {Process.send_after(pid, {:post, rooted(loop, key, fun)}, ms), roots, key}
  end

  def clear_timeout(nil), do: :ok

  def clear_timeout({timer, roots, key}) do
    :ets.delete(roots, key)
    Process.cancel_timer(timer) && :ok
  rescue
    ArgumentError -> :ok
  end

  defp rooted(%__MODULE__{roots: roots}, key, fun) do
    :ets.insert(roots, {key, fun})

    fn ->
      :ets.delete(roots, key)
      fun.()
    end
  end

  @doc "Hold-time statistics per grant kind: %{kind => %{count, total_us, max_us}}."
  def stats(%__MODULE__{pid: pid}), do: GenServer.call(pid, :stats)
  def reset_stats(%__MODULE__{pid: pid}), do: GenServer.call(pid, :reset_stats)

  ## Server

  @impl true
  def init(_opts) do
    loop = %__MODULE__{pid: self(), heap: new_table(), roots: GC.new_roots(), gc: GC.new_counters()}
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
       stats: %{},
       heaps: %{},
       watched: %{}
     }}
  end

  defp new_table,
    do: :ets.new(:playwright_ex_heap, [:ordered_set, :public, read_concurrency: true, write_concurrency: true])

  @impl true
  def handle_call(:loop, _from, s), do: {:reply, s.loop, s}

  def handle_call(:new_heap, _from, s) do
    heap = new_table()
    {:reply, heap, put_in(s.heaps[heap], :open)}
  end

  def handle_call(:heaps, _from, s), do: {:reply, Map.put(s.heaps, s.loop.heap, :loop), s}
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

  def handle_cast({:close_heap, heap}, s),
    do: {:noreply, if(Map.has_key?(s.heaps, heap), do: put_in(s.heaps[heap], :closed), else: s)}

  def handle_cast({:forget_heap, heap}, s), do: {:noreply, %{s | heaps: Map.delete(s.heaps, heap)}}

  # A process holding values returned from the baton (`GC.root_returned/3`): drop its roots when it exits.
  def handle_cast({:watch, pid}, s) do
    if Map.has_key?(s.watched, pid),
      do: {:noreply, s},
      else: {:noreply, put_in(s.watched[pid], Process.monitor(pid))}
  end

  @impl true
  def handle_info({:post, fun}, s), do: {:noreply, s |> enqueue({:task, fun}) |> schedule()}

  # `:noproc`: granted to a process that died just before (see `schedule/1`), nothing was held.
  def handle_info({:DOWN, mon, :process, pid, reason}, %{mon: mon} = s) do
    if reason != :noproc, do: Logger.error("Baton holder #{inspect(pid)} died: #{inspect(reason)}; reclaiming")
    {:noreply, schedule(%{record(s) | holder: nil, mon: nil})}
  end

  def handle_info({:DOWN, mon, :process, pid, _reason}, %{watched: watched} = s) when is_map_key(watched, pid) do
    if watched[pid] == mon, do: GC.drop_returned(s.loop, pid)
    {:noreply, %{s | watched: Map.delete(watched, pid)}}
  end

  def handle_info(_other, s), do: {:noreply, s}

  defp enqueue(s, item), do: %{s | macro: :queue.in(item, s.macro)}

  # Processes that died while suspended or queued for `acquire` are skipped: their work went with them.
  defp schedule(%{holder: nil} = s) do
    case :queue.out(s.micro) do
      {{:value, pid}, micro} ->
        if Process.alive?(pid) do
          send(pid, {:pw_grant, self()})
          grant(%{s | micro: micro}, pid, :resume)
        else
          schedule(%{s | micro: micro})
        end

      {:empty, _} ->
        case :queue.out(s.macro) do
          {{:value, {:call, {pid, _} = from}}, macro} ->
            if Process.alive?(pid) do
              GenServer.reply(from, :ok)
              grant(%{s | macro: macro}, pid, :call)
            else
              schedule(%{s | macro: macro})
            end

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
          begin_unit(loop)
          fun.()
        catch
          kind, reason ->
            if !abandoned?(loop),
              do: Logger.error("Uncaught in event loop task: " <> Exception.format(kind, reason, __STACKTRACE__))
        end

        end_unit_quietly(loop)
        release()
    end

    executor_loop(loop)
  end

  # The server stopped while a callback or task still ran: its heaps are gone, the work is abandoned.
  defp abandoned?(%__MODULE__{pid: pid}), do: not Process.alive?(pid)
end
