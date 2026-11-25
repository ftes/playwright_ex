defmodule Playwright.Runtime.Conn do
  @moduledoc """
  Runtime support (not ported from upstream): one process per protocol connection (`connection.ts`).

  The process owns the connection's state: an `ordered_set`, `:protected` ETS table (rows of
  `Playwright.Runtime.Heap`; lock-free reads from any process) and the connection-level state.
  Client code runs in the caller's process; writes from other processes are funs run here
  (`run/2`), so a read-modify-write is atomic, as a synchronous JS section is.

  Dispatch: driver messages are dispatched (`Playwright.Client.Connection.dispatch/2`) one at a
  time, in this process. Emitting an event turns its listeners into steps
  (`Playwright.Client.EventEmitter`), run in order behind a barrier: a step that runs a
  listener in another process (a user listener's subscription process, an internal listener's
  process per event, an async function started here) holds dispatch until the listener returns or
  first blocks on Playwright (`Playwright.Runtime.Invocation.yield/0`), as JS runs listeners
  synchronously until their first `await`. Calls from other processes (`run/2`) are served
  meanwhile, so a listener calling back into the API cannot deadlock. A step that holds dispatch
  past a threshold is logged, once, and still waited for.

  The barrier keeps a stack of frames: an `emit` from the process dispatch waits for (it holds the
  barrier token) pushes a frame and returns once its listeners returned or yielded, which keeps
  JS's order for nested emits. An emit from any other process waits for the current dispatch,
  as a JS task waits for the running one.

  Promises settled in the synchronous section of a dispatch (the dispatch, its steps, and calls
  from the processes the barrier waits for) wake their awaiters once the frame stack is empty
  (`wake/2`): JS resolves a promise inside `emit` and runs the continuation after the whole
  synchronous emit, so the emit's later listeners have run when the awaiter continues.

  Outgoing messages (`post/1`) are buffered and handed to the transport (a fun, called here with
  the list) at the end of each turn of this process.
  """
  use GenServer

  alias Playwright.Client.Connection
  alias Playwright.Client.EventEmitter
  alias Playwright.Runtime.Callers
  alias Playwright.Runtime.Heap
  alias Playwright.Runtime.Invocation
  alias Playwright.Runtime.Zones
  alias Playwright.TargetClosedError

  require Logger

  # How long the barrier waits for one step before it warns (`stall/4`): far above a listener that
  # only sends a message or calls Playwright, and well below the test timeouts (Playwright's 30 s,
  # ExUnit's 60 s), so the warning comes before the timeout it explains.
  @stall_warning 5_000

  # The rows a connection retains for disposed objects (`retain/2`) before it frees the oldest.
  # deviation: JS keeps a disposed object while referenced (GC, no cap). The nearest upstream
  # precedent is the server's dispatcher GC (`dispatcher.ts:281-295`: past 10,000 dispatchers of a
  # type it disposes the oldest); this cap counts rows, not objects, so it bounds memory directly.
  # Measured with `:ets.info(table, :memory)` over closed contexts of one page with a route and a
  # listener: 0.7 to 1.1 KB per row (handles carry their initializers); 135 rows for a blank page,
  # 500 for a small one with subresources. So about 50 MB per connection: 100 to 370 such contexts.
  # The count is approximate: off by the rows written to or freed from retained objects since they
  # were counted (few: closed objects rarely get writes, mostly settled or freed latches), as
  # `trim/2` recounts the oldest only, so the total may end a little above or below the cap.
  @max_retained_rows 50_000

  # The tombstones of objects the driver collected (`collected/2`) a connection keeps before it
  # frees the oldest. deviation: JS keeps a collected object, and its `_wasCollected`, while
  # referenced. A count of their own, outside the row cap: the driver collects in bulk (the
  # oldest tenth past 10,000 dispatchers of a type), and its tombstones would push closed contexts
  # out of the FIFO. 10,000, the driver's threshold: about 3 MB (two rows, ~330 bytes, each).
  @max_collected 10_000

  @doc """
  Options: `:transport` (1-arity fun called here with each batch of outgoing messages; or set
  later, `set_transport/2`), `:local_utils`, `:headers`, `:on_dispatch_error` (1-arity fun called
  here with an exception raised by dispatch; default: log it), `:stall_warning` (ms the barrier
  waits for one step before it logs a warning; default 5 s).
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @doc "The `Playwright.Client.Connection` of a connection process."
  def connection(conn), do: GenServer.call(conn, :connection)

  @doc false
  def set_transport(conn, transport), do: GenServer.call(conn, {:set_transport, transport})

  @doc "Whether the caller is a connection process."
  def in_conn?, do: Process.get(:pw_conn) != nil

  @doc """
  Runs `fun` in the connection process and returns its result (raising what it raises). Event
  listeners it emits to run before this returns (see the moduledoc). `fun` must not await.
  """
  def run(conn, fun) do
    if self() == conn do
      fun.()
    else
      call(conn, {:run, fun, Process.get(:pw_barrier)})
    end
  end

  @doc "Runs `fun` in the connection process without waiting (abort listeners)."
  def cast(conn, fun), do: GenServer.cast(conn, {:run, fun})

  @doc false
  # Stops the connection process once all `pids` have exited (now, if none is alive): a closed
  # remote connection, whose objects stay readable for the processes that made them until then.
  def stop_when_down(conn, pids), do: GenServer.cast(conn, {:stop_when_down, pids})

  @doc false
  # Stops the connection process, handing its table to a keeper process first (a lost local
  # driver, see `Playwright.OutOfProcess`): handles of the connection keep reading their last
  # values (calls and writes raise TargetClosedError, as the connection process is gone) until
  # every process that created or closed a browser, or created a context, has exited, or
  # `lifeline` (the supervisor) has, whichever comes first.
  def hand_off(conn, lifeline) do
    GenServer.call(conn, {:hand_off, lifeline}, :infinity)
  catch
    :exit, _ -> :ok
  end

  @doc false
  # Waits until no listener invocation of `emitter` for `type` (`nil`: any) is running.
  # An `await` (of the pending handlers): the caller continues first.
  def wait_pending(%{conn: conn, guid: guid}, type) do
    Invocation.yield()
    call(conn, {:wait_pending, guid, type})
  end

  defp call(conn, request) do
    case GenServer.call(conn, request, :infinity) do
      {:ok, value} -> value
      {:raise, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  catch
    # Any exit reason (`:killed`, `:noconnection` too), as a wait's `:DOWN` (`Playwright.Runtime.Promise`).
    :exit, {_reason, {GenServer, :call, _}} ->
      raise TargetClosedError.new("Playwright driver closed")
  end

  ## Called in this process

  @doc false
  # In the connection: `guid` was disposed and its rows (with its marker `{guid, :__retained__}`)
  # are retained, the newest entry of the connection's FIFO of disposed objects:
  # `{:connection, {:disposed, seq}} => {guid, rows}`, the marker's value `seq`. This process alone
  # enqueues, counts and trims (`trim/2`).
  def retain(table, guid) do
    seq = disposed_mark()
    Process.put(:pw_disposed_seq, seq + 1)
    :ets.insert(table, {{guid, :__retained__}, seq})
    :ets.insert(table, {{:connection, {:disposed, seq}}, {guid, 0}})
    recount(table, {:connection, {:disposed, seq}})
  end

  @doc false
  # In the connection: the `seq` of the next object `retain/2` enqueues (`trim/2`'s mark).
  def disposed_mark, do: Process.get(:pw_disposed_seq, 0)

  @doc false
  # In the connection: frees the oldest retained objects (their rows, marker and entry) while
  # more than the cap's rows are retained, but none enqueued from `mark` on (the unit whose
  # dispose this is, so it reads right after its close, whatever its size).
  def trim(table, mark) do
    with true <- retained_rows() > max_retained_rows(),
         {:connection, {:disposed, seq}} = key when seq < mark <- :ets.next(table, {:connection, {:disposed, -1}}) do
      # A retained object still gets writes, and loses rows (a latch `Promise.free/1` frees).
      recount(table, key)

      if retained_rows() > max_retained_rows() do
        [{_, {guid, _rows}}] = :ets.lookup(table, key)
        forget(table, seq)
        Heap.free_rows(%{table: table}, guid)
        trim(table, mark)
      end
    end

    :ok
  end

  @doc false
  # In the connection: drops entry `seq` of the FIFO (its object's rows stay for the caller).
  def forget(table, seq) do
    key = {:connection, {:disposed, seq}}

    with [_] <- :ets.lookup(table, key) do
      rows = recount(table, key)
      :ets.delete(table, key)
      Process.put(:pw_retained_rows, retained_rows() - rows)
    end

    :ok
  end

  # The rows of entry `key`'s object (its marker's too) and the entry's own, counted now: the
  # entry and the count of retained rows follow.
  defp recount(table, key) do
    [{_, {guid, counted}}] = :ets.lookup(table, key)
    rows = :ets.select_count(table, [{{{guid, :_}, :_}, [], [true]}]) + 1

    if rows != counted do
      :ets.insert(table, {key, {guid, rows}})
      Process.put(:pw_retained_rows, retained_rows() + rows - counted)
    end

    rows
  end

  defp retained_rows, do: Process.get(:pw_retained_rows, 0)

  @doc false
  # In the connection: the cap. A test may set another for its own connection (`Process.put/2`
  # in `run/2`).
  def max_retained_rows, do: Process.get(:pw_max_retained_rows, @max_retained_rows)

  @doc false
  # In the connection: `guid` was collected by the driver (`__dispose__` with reason "gc"), its
  # rows freed: its tombstone (`{guid, :__collected__} => seq`, `{:connection, {:collected, seq}}
  # => guid`), so calls raise upstream's "has been collected" error. Kept outside the FIFO of
  # `retain/2`, bounded by a count: past it, the oldest goes.
  def collected(table, guid) do
    seq = Process.get(:pw_collected_seq, 0)
    Process.put(:pw_collected_seq, seq + 1)
    :ets.insert(table, [{{guid, :__collected__}, seq}, {{:connection, {:collected, seq}}, guid}])
    Process.put(:pw_collected, Process.get(:pw_collected, 0) + 1)

    # A test may set another cap, as `max_retained_rows/0`'s.
    if Process.get(:pw_collected) > Process.get(:pw_max_collected, @max_collected) do
      {:connection, {:collected, oldest}} = key = :ets.next(table, {:connection, {:collected, -1}})
      [{_, oldest_guid}] = :ets.lookup(table, key)
      forget_collected(table, oldest)
      :ets.delete(table, {oldest_guid, :__collected__})
    end
  end

  @doc false
  # In the connection: drops tombstone entry `seq` (its marker stays for the caller).
  def forget_collected(table, seq) do
    with [{key, _guid}] <- :ets.lookup(table, {:connection, {:collected, seq}}) do
      :ets.delete(table, key)
      Process.put(:pw_collected, Process.get(:pw_collected) - 1)
    end

    :ok
  end

  @doc false
  # `connection.onmessage`: buffered, sent at the end of this turn.
  def post(message), do: Process.put(:pw_out, [message | Process.get(:pw_out, [])])

  @doc false
  # A promise settled here (`{:pw, ref, result}` to its awaiter): inside the synchronous section
  # of a dispatch, sent once the frame stack is empty (JS: a microtask, after the whole emit).
  def wake(pid, message) do
    case Process.get(:pw_wakes) do
      nil -> send(pid, message)
      wakes -> Process.put(:pw_wakes, [{pid, message} | wakes])
    end
  end

  @doc false
  # In the connection, in a `run/2` call: drops a held wake-up `{:pw, ref, _}` to `pid` (a
  # disarmed latch waiter), so a wake-up held past the call's reply cannot arrive after the
  # caller flushed `ref`. A wake-up already sent arrived before the reply.
  def unwake(pid, ref) do
    if in_conn?(), do: Process.put(:pw_unwake, [{pid, ref} | Process.get(:pw_unwake, [])])
    :ok
  end

  @doc false
  # A dispatch step (listener invocation), run after the step that produced it (depth first).
  def push_step(step) do
    if !in_conn?(), do: raise("Conn.push_step/1 outside the connection process")
    Process.put(:pw_steps, [step | Process.get(:pw_steps) || []])
  end

  @doc false
  # Test and diagnostics: rows, running listener processes, pending callbacks.
  def stats(conn), do: GenServer.call(conn, :stats)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.put(:pw_conn, true)
    Process.put(:pw_stall_after, Map.get(opts, :stall_warning, @stall_warning))
    table = :ets.new(:playwright_conn, [:ordered_set, :protected, read_concurrency: true])
    handle = struct(Connection, guid: :connection, conn: self(), table: table)

    {connection, _steps, wakes} =
      collect(fn -> Connection.new(handle, opts[:local_utils], opts[:instrumentation], Map.get(opts, :headers, [])) end)

    {:ok,
     %{
       connection: connection,
       table: table,
       transport: opts[:transport],
       on_dispatch_error: opts[:on_dispatch_error],
       queue: :queue.new(),
       frames: [],
       # wake-ups held back until the frame stack is empty (`wake/2`), newest first
       wakes: [],
       # monitor ref => inv of a listener or async process the barrier may wait for
       procs: %{},
       # subscription pid => invocations sent and not done (oldest first)
       busy: %{},
       # inv => {emitter guid, type}: listener invocations still running (`_pendingHandlers`)
       pending: %{},
       pending_waiters: [],
       # the running stall timer's tag (`arm_stall/2`)
       stall: nil,
       # monitor ref => pid: the processes whose exit stops this one (`stop_when_down/2`)
       stop_when_down: nil
     }
     |> send_wakes(wakes)}
  end

  @impl true
  def handle_call(:connection, _from, state), do: {:reply, state.connection, state}

  def handle_call({:set_transport, transport}, _from, state),
    do: {:reply, :ok, flush_out(%{state | transport: transport})}

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       rows: :ets.info(state.table, :size),
       callbacks: length(Connection.callbacks(state.connection)),
       processes: map_size(state.procs),
       subscriptions: map_size(state.busy),
       frames: length(state.frames)
     }, state}
  end

  def handle_call({:run, fun, token}, from, state) do
    {result, steps, wakes} = collect(fn -> catch_run(fun) end)
    state = drop_unwakes(state)
    frame = %{steps: steps, blocked: nil, from: from, result: result, wakes: wakes}
    nested = nested?(state, token)

    state =
      cond do
        steps == [] ->
          GenServer.reply(from, result)
          # Part of the running dispatch (a listener the barrier waits for): held back.
          if nested, do: hold_wakes(state, wakes), else: send_wakes(state, wakes)

        nested or state.frames == [] ->
          push_frame(state, frame)

        true ->
          %{state | queue: :queue.in({:frame, frame}, state.queue)}
      end

    {:noreply, state |> drain() |> flush_out()}
  end

  def handle_call({:hand_off, lifeline}, _from, %{table: table} = state) do
    # The processes that created or closed a browser, or created a context (`_set_creator/1`).
    pids = Enum.uniq(List.flatten(:ets.select(table, [{{{:_, :_creators}, :"$1"}, [], [:"$1"]}])))
    conn = self()
    keeper = spawn(fn -> keep(conn, lifeline, pids) end)
    :ets.give_away(table, keeper, nil)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:wait_pending, guid, type}, from, state) do
    state = %{state | pending_waiters: [{from, guid, type} | state.pending_waiters]}
    {:noreply, notify_pending(state)}
  end

  @impl true
  def handle_cast({:stop_when_down, pids}, state) do
    mons = for pid <- pids, Process.alive?(pid), into: %{}, do: {Process.monitor(pid), pid}
    if mons == %{}, do: {:stop, :normal, state}, else: {:noreply, %{state | stop_when_down: mons}}
  end

  def handle_cast({:run, fun}, state) do
    {result, steps, wakes} = collect(fn -> catch_run(fun) end)

    with {:raise, kind, reason, stacktrace} <- result,
         do: Logger.error("Uncaught in connection: " <> Exception.format(kind, reason, stacktrace))

    frame = %{steps: steps, blocked: nil, from: nil, result: nil, wakes: wakes}

    state =
      cond do
        steps == [] -> send_wakes(state, wakes)
        state.frames == [] -> push_frame(state, frame)
        true -> %{state | queue: :queue.in({:frame, frame}, state.queue)}
      end

    {:noreply, state |> drain() |> flush_out()}
  end

  @impl true
  def handle_info({:pw_msg, message}, state),
    do: {:noreply, %{state | queue: :queue.in({:msg, message}, state.queue)} |> drain() |> flush_out()}

  def handle_info({:pw_yield, inv}, state), do: {:noreply, state |> unblock(inv) |> drain() |> flush_out()}

  def handle_info({:pw_done, inv, pid}, state) do
    busy = if state.busy[pid], do: Map.update!(state.busy, pid, &List.delete(&1, inv)), else: state.busy
    {:noreply, %{state | busy: busy} |> done(inv) |> drain() |> flush_out()}
  end

  def handle_info({:DOWN, mref, :process, _pid, _reason}, %{stop_when_down: mons} = state)
      when is_map_key(mons, mref) do
    mons = Map.delete(mons, mref)
    if mons == %{}, do: {:stop, :normal, state}, else: {:noreply, %{state | stop_when_down: mons}}
  end

  def handle_info({:DOWN, mref, :process, pid, _reason}, state) do
    state =
      case Map.pop(state.procs, mref) do
        # A subscription process exited (killed, or a linked process crashed) with invocations
        # sent to it: they are done, else dispatch would wait for them forever.
        {nil, _} ->
          {invs, busy} = Map.pop(state.busy, pid, [])
          Enum.reduce(invs, %{state | busy: busy}, &done(&2, &1))

        {inv, procs} ->
          done(%{state | procs: procs}, inv)
      end

    {:noreply, state |> drain() |> flush_out()}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The stall timer: the step the barrier waits for now has waited past the threshold (warned once:
  # the waiting steps' `since` goes), or the timer is re-armed for the rest of its threshold.
  def handle_info({:pw_stall, tag}, %{stall: tag} = state) do
    state = %{state | stall: nil}

    case state.frames do
      [%{blocked: {inv, pid, since}} | _] when since != nil ->
        waited = System.monotonic_time(:millisecond) - since

        if waited >= Process.get(:pw_stall_after) do
          stall(state, inv, pid, waited)
          frames = Enum.map(state.frames, &with(%{blocked: {i, p, _}} <- &1, do: %{&1 | blocked: {i, p, nil}}))
          {:noreply, %{state | frames: frames}}
        else
          {:noreply, arm_stall(state, Process.get(:pw_stall_after) - waited)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {pid, _} <- state.busy, do: send(pid, :pw_stop)
    :ok
  end

  # The owner of a handed-off table (`hand_off/2`): the table goes when this process exits. It
  # exits without the table if the connection is killed before handing it over, and it never
  # outlives `lifeline` (monitored, so a brutal kill of the supervisor counts too).
  defp keep(conn, lifeline, pids) do
    conn_ref = Process.monitor(conn)

    receive do
      {:"ETS-TRANSFER", _table, _from, _} ->
        Process.demonitor(conn_ref, [:flush])
        lifeline = Process.monitor(lifeline)
        mons = for pid <- pids, Process.alive?(pid), into: MapSet.new(), do: Process.monitor(pid)
        keep_loop(mons, lifeline)

      {:DOWN, ^conn_ref, :process, _, _} ->
        :ok
    end
  end

  defp keep_loop(mons, lifeline) do
    if MapSet.size(mons) > 0 do
      receive do
        {:DOWN, ^lifeline, :process, _, _} -> :ok
        {:DOWN, mref, :process, _, _} -> keep_loop(MapSet.delete(mons, mref), lifeline)
      end
    end
  end

  defp catch_run(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:raise, kind, reason, __STACKTRACE__}
  end

  # Runs `fun` collecting the steps it produces and the wake-ups it holds back (`wake/2`).
  defp collect(fun) do
    previous = Process.put(:pw_steps, [])
    previous_wakes = Process.put(:pw_wakes, [])
    result = fun.()
    steps = Process.get(:pw_steps)
    wakes = Process.get(:pw_wakes)
    Process.put(:pw_steps, previous)
    Process.put(:pw_wakes, previous_wakes)
    {result, Enum.reverse(steps), wakes}
  end

  defp nested?(%{frames: [%{blocked: {inv, _, _}} | _]}, inv), do: true
  defp nested?(_state, _token), do: false

  # A frame's wake-ups are held until the stack is empty.
  defp push_frame(state, frame),
    do: hold_wakes(%{state | frames: [Map.delete(frame, :wakes) | state.frames]}, frame.wakes)

  defp hold_wakes(state, wakes), do: %{state | wakes: wakes ++ state.wakes}

  # Held wake-ups dropped by `unwake/2`: those of the frame stack and of queued frames.
  defp drop_unwakes(state) do
    case Process.delete(:pw_unwake) do
      nil ->
        state

      drop ->
        drop = Map.from_keys(drop, true)
        keep = fn wakes -> Enum.reject(wakes, &match?({pid, {:pw, ref, _}} when is_map_key(drop, {pid, ref}), &1)) end

        queue =
          :queue.filter(
            fn
              {:frame, frame} -> [{:frame, %{frame | wakes: keep.(frame.wakes)}}]
              _msg -> true
            end,
            state.queue
          )

        %{state | wakes: keep.(state.wakes), queue: queue}
    end
  end

  defp send_wakes(state, wakes) do
    for {pid, message} <- Enum.reverse(wakes), do: send(pid, message)
    state
  end

  ## Dispatch with the barrier

  # The frame stack is empty: the synchronous section is over, its wake-ups go out (JS: the
  # microtasks run), then the next message or queued frame.
  defp drain(%{frames: [], wakes: [_ | _] = wakes} = state), do: drain(send_wakes(%{state | wakes: []}, wakes))

  defp drain(%{frames: []} = state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {:msg, message}}, queue} ->
        {_, steps, wakes} = collect(fn -> dispatch(message, state) end)
        state = %{state | queue: queue}
        drain(push_frame(state, %{steps: steps, blocked: nil, from: nil, result: nil, wakes: wakes}))

      {{:value, {:frame, frame}}, queue} ->
        drain(push_frame(%{state | queue: queue}, frame))
    end
  end

  defp drain(%{frames: [%{blocked: inv} | _]} = state) when inv != nil, do: state

  defp drain(%{frames: [%{steps: [step | rest]} = frame | below]} = state) do
    state = %{state | frames: [%{frame | steps: rest} | below]}
    {state, steps, wakes} = collect(fn -> run_step(step, state) end)
    [top | below] = state.frames
    drain(hold_wakes(%{state | frames: [%{top | steps: steps ++ top.steps} | below]}, wakes))
  end

  defp drain(%{frames: [%{steps: []} = frame | below]} = state) do
    if frame.from, do: GenServer.reply(frame.from, frame.result)
    drain(%{state | frames: below})
  end

  defp dispatch(message, state) do
    Connection.dispatch(state.connection, message)
  rescue
    e ->
      if state.on_dispatch_error,
        do: state.on_dispatch_error.(e),
        else: Logger.error("Dispatch failed: " <> Exception.format(:error, e, __STACKTRACE__))
  end

  # Dispatch waits for `inv`, run by `pid`, since now.
  defp block(%{frames: [top | below]} = state, inv, pid) do
    state = %{state | frames: [%{top | blocked: {inv, pid, System.monotonic_time(:millisecond)}} | below]}
    if state.stall, do: state, else: arm_stall(state, Process.get(:pw_stall_after))
  end

  defp unblock(state, inv) do
    %{state | frames: Enum.map(state.frames, &if(match?({^inv, _, _}, &1.blocked), do: %{&1 | blocked: nil}, else: &1))}
  end

  # One timer for the barrier: armed when it blocks with none running, re-armed when it fires early
  # for the step it waits for then.
  defp arm_stall(state, ms) do
    tag = make_ref()
    Process.send_after(self(), {:pw_stall, tag}, ms)
    %{state | stall: tag}
  end

  defp stall(state, inv, pid, waited) do
    what =
      case state.pending[inv] do
        {guid, "route"} -> "a route handler of #{object(guid)}"
        {guid, type} -> ~s(a "#{type}" listener of #{object(guid)})
        nil -> "an async function"
      end

    # None if it is gone (its `:DOWN` still queued).
    with {_, stacktrace} <- Process.info(holder(pid), :current_stacktrace) do
      Logger.warning("""
      Dispatch has waited #{waited} ms for #{what}, which \
      stalls every page on this connection: the connection waits until a listener or route handler \
      returns or awaits a Playwright call. Hand blocking work (receive, Process.sleep/1, HTTP) to \
      another process with send/2 or Task.start/1 and return: \
      https://hexdocs.pm/playwright_ex/concurrency.html#no-blocking-work-in-listeners. It waits at:
      #{Exception.format_stacktrace(stacktrace)}\
      """)
    end
  end

  # A channel's guid (`{guid, :channel}`) or a local object's (`{owner, ref}`) names its object.
  defp object({guid, _}), do: guid
  defp object(guid), do: guid

  # The process that holds the barrier: `pid`, or the async function it waits for to yield
  # (`Playwright.Runtime.Promise.async/2` monitors it, its `:pw_inv` names `pid`), as a route handler.
  defp holder(pid) do
    {_, monitors} = Process.info(pid, :monitors) || {nil, []}
    waits_for? = &match?({_, {^pid, _}}, Process.info(&1, {:dictionary, :pw_inv}))
    child = Enum.find(for({:process, p} when node(p) == node() <- monitors, do: p), waits_for?)
    if child, do: holder(child), else: pid
  end

  defp done(state, inv) do
    state = unblock(state, inv)

    case Map.pop(state.pending, inv) do
      {nil, _} -> state
      {_, pending} -> notify_pending(%{state | pending: pending})
    end
  end

  defp notify_pending(state) do
    {ready, waiting} =
      Enum.split_with(state.pending_waiters, fn {_from, guid, type} ->
        not Enum.any?(state.pending, fn {_inv, {g, t}} -> g == guid and (type == nil or t == type) end)
      end)

    for {from, _, _} <- ready, do: GenServer.reply(from, {:ok, nil})
    %{state | pending_waiters: waiting}
  end

  # A listener run here (`EventEmitter.on_sync/3`): synchronously.
  defp run_step({:sync, fun, arg, emitter, type}, state) do
    invoke(fun, arg, emitter, type)
    state
  end

  defp run_step({:mailbox, pid, ref, arg}, state) do
    send(pid, {:pw, ref, {:event, arg}})
    state
  end

  # An internal listener: one process per event, as each JS call is its own async chain.
  defp run_step({:internal, fun, arg, emitter, type, zone}, state) do
    inv = make_ref()
    conn = self()

    {pid, mref} =
      spawn_monitor(fn ->
        Zones.restore(zone)
        Playwright.Runtime.Invocation.start(conn, inv, inv)
        invoke(fun, arg, emitter, type)
      end)

    state = %{
      state
      | procs: Map.put(state.procs, mref, inv),
        pending: Map.put(state.pending, inv, {emitter.guid, type})
    }

    block(state, inv, pid)
  end

  # A user listener runs in its subscription process, one invocation at a time (FIFO). If it is
  # busy with an earlier one (that yielded), the barrier does not wait: JS would interleave both.
  defp run_step({:user, pid, fun, arg, emitter, type, zone}, state) do
    inv = make_ref()
    send(pid, {:pw_invoke, inv, fun, arg, emitter, type, zone})
    was_busy = Map.get(state.busy, pid, []) != []
    if !Map.has_key?(state.busy, pid), do: Process.monitor(pid)

    state = %{
      state
      | busy: Map.update(state.busy, pid, [inv], &(&1 ++ [inv])),
        pending: Map.put(state.pending, inv, {emitter.guid, type})
    }

    if was_busy, do: state, else: block(state, inv, pid)
  end

  defp run_step({:stop, pid}, state) do
    send(pid, :pw_stop)
    state
  end

  # An async function (or `void`) called here: it starts now and holds dispatch until it yields.
  defp run_step({:start, pid, inv}, state) do
    mref = Process.monitor(pid)
    send(pid, {:pw_go, inv})
    block(%{state | procs: Map.put(state.procs, mref, inv)}, inv, pid)
  end

  @doc false
  # Runs a listener of `type` (`EventEmitter._callHandler`); an exception goes to the emitter's
  # rejection handler (`removeAllListeners` with a behavior), else to its `error` listeners
  # (`EventEmitter._handle_listener_error/5`); what that throws is logged (JS: an uncaught exception).
  def invoke(fun, arg, emitter, type) do
    fun.(arg)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      handler =
        try do
          Heap.get(emitter, :_rejectionHandler)
        rescue
          _ -> nil
        end

      if handler,
        do: handler.(Exception.normalize(kind, reason, stacktrace)),
        else: uncaught(fn -> EventEmitter._handle_listener_error(emitter, type, kind, reason, stacktrace) end)
  end

  # Elixir only: in a `Playwright.Test` test (the listener's `$callers`) it fails the test.
  defp uncaught(fun) do
    fun.()
  catch
    kind, reason -> Callers.unhandled("Uncaught in event listener: ", kind, reason, __STACKTRACE__)
  end

  @doc false
  # The process of a user listener (`EventEmitter.on/3` under `Playwright.Runtime.Facade.listen/1`).
  # Elixir only: it runs on behalf of the registering process (`Runtime.Callers`).
  def subscription(conn) do
    callers = Callers.capture()

    spawn(fn ->
      Callers.adopt(callers)
      mon = Process.monitor(conn)
      Process.put(:pw_listener, true)
      subscription_loop(conn, mon)
    end)
  end

  defp subscription_loop(conn, mon) do
    receive do
      {:pw_invoke, inv, fun, arg, emitter, type, zone} ->
        Zones.restore(zone)
        Playwright.Runtime.Invocation.start(conn, inv, inv)
        # Elixir only: not once its test closes its contexts (`Callers.test_finished?/0`).
        if !Callers.test_finished?(), do: invoke(fun, arg, emitter, type)
        Process.delete(:pw_inv)
        Process.delete(:pw_barrier)
        send(conn, {:pw_done, inv, self()})
        subscription_loop(conn, mon)

      :pw_stop ->
        :ok

      {:DOWN, ^mon, :process, _, _} ->
        :ok
    end
  end

  defp flush_out(state) do
    case Process.get(:pw_out, []) do
      [] ->
        state

      out when state.transport != nil ->
        Process.put(:pw_out, [])
        out = Enum.reverse(out)
        # Test hook: a 1-arity fun called with each message sent (`:persistent_term`).
        if hook = :persistent_term.get({__MODULE__, :on_send}, nil), do: Enum.each(out, hook)
        state.transport.(out)
        state

      _ ->
        state
    end
  end
end
