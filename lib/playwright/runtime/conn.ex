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
  listener in another process (a process per listener invocation, or an async function started
  here) holds dispatch until the listener returns or first awaits
  (`Playwright.Runtime.Invocation.yield/0`), as JS runs listeners synchronously until their first
  `await`. Calls from other processes (`run/2`) are served meanwhile, so a listener calling back
  into the API cannot deadlock.

  A wait outside Playwright (a `receive`) is an await only to its author. As a fallback, a
  section the top frame has waited for `Invocation.release_after/0` ms (100) is released as if
  it had yielded, with a warning (`Invocation.try_release/4`): its remaining synchronous code may
  run after later events.

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

  @doc """
  Options: `:transport` (1-arity fun called here with each batch of outgoing messages; or set
  later, `set_transport/2`), `:local_utils`, `:headers`, `:on_dispatch_error` (1-arity fun called
  here with an exception raised by dispatch; default: log it).
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
  # every process that created or anchored an object has exited, or `lifeline` (the supervisor)
  # has, whichever comes first.
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
  # In the connection: `guid` (a retained object) is freed when the last of the pids anchored
  # to it exits.
  def anchor(table, pid, guid) do
    :ets.insert(table, [{{:connection, {:anchored, pid, guid}}, true}, {{guid, {:anchor, pid}}, true}])
    if !Process.get({:pw_anchor, pid}), do: Process.put({:pw_anchor, pid}, Process.monitor(pid))
  end

  @doc false
  # In the connection: undoes `anchor/3`. The pid's monitor is shared by the guids it anchors, so
  # it goes with the last of them.
  def unanchor(table, pid, guid) do
    :ets.delete(table, {:connection, {:anchored, pid, guid}})
    :ets.delete(table, {guid, {:anchor, pid}})

    if :ets.select_count(table, [{{{:connection, {:anchored, pid, :_}}, :_}, [], [true]}]) == 0 do
      with mref when is_reference(mref) <- Process.delete({:pw_anchor, pid}), do: Process.demonitor(mref, [:flush])
    end
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
       # inv => {emitter guid, type}: listener invocations still running (`_pendingHandlers`)
       pending: %{},
       pending_waiters: [],
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
       frames: length(state.frames)
     }, state}
  end

  def handle_call({:run, fun, token}, from, state) do
    {result, steps, wakes} = collect(fn -> catch_run(fun) end)
    state = drop_unwakes(state)
    frame = frame(steps, from, result, wakes)
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
    # The processes that created a browser or context, or anchor a closed one's rows.
    creators = :ets.select(table, [{{{:_, :_creators}, :"$1"}, [], [:"$1"]}])
    anchors = :ets.select(table, [{{{:connection, {:anchored, :"$1", :_}}, :_}, [], [:"$1"]}])
    pids = Enum.uniq(List.flatten(creators) ++ anchors)
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

    frame = frame(steps, nil, nil, wakes)

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

  def handle_info({:pw_release, inv}, state), do: {:noreply, state |> release(inv) |> drain() |> flush_out()}

  def handle_info({:DOWN, mref, :process, _pid, _reason}, %{stop_when_down: mons} = state)
      when is_map_key(mons, mref) do
    mons = Map.delete(mons, mref)
    if mons == %{}, do: {:stop, :normal, state}, else: {:noreply, %{state | stop_when_down: mons}}
  end

  def handle_info({:DOWN, mref, :process, pid, _reason}, %{table: table} = state) do
    # A retention anchor exited: free what it anchored.
    if Process.get({:pw_anchor, pid}) == mref do
      Process.delete({:pw_anchor, pid})
      anchored = :ets.select(table, [{{{:connection, {:anchored, pid, :"$1"}}, :_}, [], [:"$1"]}])
      :ets.select_delete(table, [{{{:connection, {:anchored, pid, :_}}, :_}, [], [true]}])

      for guid <- anchored do
        :ets.delete(table, {guid, {:anchor, pid}})
        # The last of its anchor processes.
        if :ets.select_count(table, [{{{guid, {:anchor, :_}}, :_}, [], [true]}]) == 0, do: Heap.release(table, guid)
      end
    end

    state =
      case Map.pop(state.procs, mref) do
        {nil, _} -> state
        {inv, procs} -> done(%{state | procs: procs}, inv)
      end

    {:noreply, state |> drain() |> flush_out()}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

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

  # A call from the process the top frame waits for (or its async function), while its section
  # is live.
  defp nested?(%{frames: [%{waiting: %{inv: inv}} | _]}, {inv, flag}), do: Invocation.live?(flag)
  defp nested?(_state, _token), do: false

  # `waiting`: `%{inv, pid, flag, event, timer}` of the section a blocked frame waits for
  # (`block/5`), `nil` if none.
  defp frame(steps, from, result, wakes), do: %{steps: steps, waiting: nil, from: from, result: result, wakes: wakes}

  defp waits_for?(%{waiting: %{inv: inv}}, inv), do: true
  defp waits_for?(_frame, _inv), do: false

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
        drain(push_frame(state, frame(steps, nil, nil, wakes)))

      {{:value, {:frame, frame}}, queue} ->
        drain(push_frame(%{state | queue: queue}, frame))
    end
  end

  defp drain(%{frames: [%{waiting: %{}} | _]} = state), do: state

  defp drain(%{frames: [%{steps: [step | rest]} = frame | below]} = state) do
    state = %{state | frames: [%{frame | steps: rest} | below]}
    {state, steps, wakes} = collect(fn -> run_step(step, state) end)
    [top | below] = state.frames
    drain(hold_wakes(%{state | frames: [%{top | steps: steps ++ top.steps} | below]}, wakes))
  end

  defp drain(%{frames: [%{steps: []} = frame | below]} = state) do
    if frame.from, do: GenServer.reply(frame.from, frame.result)
    drain(%{state | frames: rearm(below)})
  end

  defp dispatch(message, state) do
    Connection.dispatch(state.connection, message)
  rescue
    e ->
      if state.on_dispatch_error,
        do: state.on_dispatch_error.(e),
        else: Logger.error("Dispatch failed: " <> Exception.format(:error, e, __STACKTRACE__))
  end

  defp block(%{frames: [top | below]} = state, inv, pid, flag, event) do
    waiting = %{inv: inv, pid: pid, flag: flag, event: event, timer: release_timer(inv)}
    %{state | frames: [%{top | waiting: waiting} | below]}
  end

  defp unblock(state, inv) do
    frames =
      Enum.map(state.frames, fn frame ->
        if waits_for?(frame, inv) do
          Process.cancel_timer(frame.waiting.timer)
          %{frame | waiting: nil}
        else
          frame
        end
      end)

    %{state | frames: frames}
  end

  ## The fallback (`Invocation.try_release/4`)

  defp release_timer(inv), do: Process.send_after(self(), {:pw_release, inv}, Invocation.release_after())

  # Only the top frame's section is released: the processes of the frames below wait for the top
  # one (a nested call), as JS's stack does; their timers start over once on top again (`rearm/1`).
  defp release(%{frames: [%{waiting: %{inv: inv} = waiting} | _]} = state, inv) do
    case Invocation.try_release(waiting.pid, waiting.flag, waiting.event) do
      # It goes on as after an await.
      :released -> unblock(state, inv)
      # Its `{:pw_yield, inv}` is on its way.
      :yielding -> state
    end
  end

  defp release(state, _inv), do: state

  # A frame on top again: its process was in a nested call, its timer starts over.
  defp rearm([%{waiting: %{inv: inv, timer: timer} = waiting} = top | below]) do
    Process.cancel_timer(timer)
    [%{top | waiting: %{waiting | timer: release_timer(inv)}} | below]
  end

  defp rearm(frames), do: frames

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

  # A listener invocation: one process each, as each JS call is its own async chain (so a later
  # event's invocation runs while an earlier one awaits, as in JS).
  defp run_step({:internal, fun, arg, emitter, type, zone}, state),
    do: invocation(state, fun, arg, emitter, type, zone, nil)

  # Elixir only: a user listener's invocation runs on behalf of its registrant (`$callers`), and
  # not once the registrant's test closes its contexts (`Callers.test_finished?/0`).
  defp run_step({:user, fun, arg, emitter, type, zone, callers}, state),
    do: invocation(state, fun, arg, emitter, type, zone, callers)

  # An async function (or `void`) called here: it starts now and holds dispatch until it yields.
  defp run_step({:start, pid, inv, flag, event}, state) do
    mref = Process.monitor(pid)
    send(pid, {:pw_go, inv})
    block(%{state | procs: Map.put(state.procs, mref, inv)}, inv, pid, flag, event)
  end

  defp invocation(state, fun, arg, emitter, type, zone, callers) do
    inv = make_ref()
    flag = Invocation.new_flag()
    conn = self()
    event = Invocation.event(emitter, type, fun)

    {pid, mref} =
      spawn_monitor(fn ->
        if callers do
          Callers.adopt(callers)
          Process.put(:pw_listener, emitter)
        end

        Zones.restore(zone)
        Process.put(:pw_event, event)
        Invocation.start(conn, inv, flag, inv)
        if !(callers && Callers.test_finished?()), do: invoke(fun, arg, emitter, type)
      end)

    state = %{
      state
      | procs: Map.put(state.procs, mref, inv),
        pending: Map.put(state.pending, inv, {emitter.guid, type})
    }

    block(state, inv, pid, flag, event)
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
