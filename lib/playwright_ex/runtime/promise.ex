defmodule PlaywrightEx.Runtime.Promise do
  @moduledoc """
  Runtime support (not ported from upstream): JS promises as messages.

  Kinds:

    * local (`new/0`, `new/1` with an executor, `timer/1`): a ref; settling it (`resolve/2`,
      `reject/2`, from any process) sends `{:pw, ref, result}` to its creator, which alone awaits
      it, once.
    * latch (`new/1`, `new/2` with an owner): a row on its owner (`PlaywrightEx.Runtime.Heap`),
      awaitable many times from any process; rejected with `PlaywrightEx.TargetClosedError` when
      the owner is disposed. For promises kept in fields (`ManualPromise`, `_closedPromise`).
    * settled (`resolved/1`, `rejected/1`): no storage.

  `async/2` (an async function called without `await`) is no kind of its own: a process runs the
  function and settles a local promise of the caller, or with `shared: true` a latch owned by the
  caller process (`PlaywrightEx.Runtime.ProcessOwner`, freed when the caller exits).

  `then_/2` and `catch_/2` are lazy: they run in the awaiting process when the result arrives.
  `race/1` and `all/1` arm their promises, then receive selectively: a losing local promise stays
  pending (its message may come later), losing latches are disarmed. `void/1` runs a
  function for its effects (`promise.catch(() => {})`).

  `await/1` first yields (`PlaywrightEx.Runtime.Invocation.yield/0`), as JS `await` returns
  to the caller. Inside the connection process it raises: dispatch must not block.

  Lifetimes: a local promise is its creator's (awaiting it from another process raises); its
  result is a message, which `free/1` flushes (with an alias for `async/2`, so a later result is
  dropped too). A latch lives as long as its owner's rows: for a protocol object until its
  retention anchor is freed (`_dispose` in `PlaywrightEx.Client.ChannelOwner`), for a
  `PlaywrightEx.Runtime.ProcessOwner` until that process exits. A pending latch is rejected when
  its owner is disposed; awaiting one whose owner is gone raises
  `PlaywrightEx.TargetClosedError`. `free/1` deletes a latch's row before then.
  """
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.Invocation
  alias PlaywrightEx.Runtime.ProcessOwner
  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.TargetClosedError

  require Logger

  defstruct [:kind, :ref, :pid, :owner, :result, :monitor, :cancel, :promises, handlers: []]

  @type t :: %__MODULE__{}

  ## Creating

  @doc """
  `new Promise(executor)` / `new ManualPromise()`: with no argument or an executor, a local
  promise of this process; with an owner (a protocol object or an object it owns), a latch.
  """
  def new(executor_or_owner \\ nil)

  def new(nil), do: %__MODULE__{kind: :local, ref: make_ref(), pid: self()}
  def new(executor) when is_function(executor, 2), do: run_executor(new(), executor)
  def new(%{conn: _, table: nil}), do: new()
  def new(%{conn: _, table: _} = owner), do: %__MODULE__{kind: :latch, ref: make_ref(), owner: owner}

  @doc "A latch on `owner` whose executor runs now (`new Promise(executor)` kept in a field)."
  def new(owner, executor) when is_function(executor, 2), do: run_executor(new(owner), executor)

  defp run_executor(promise, executor) do
    executor.(fn value -> resolve(promise, value) end, fn error -> reject(promise, error) end)
    promise
  rescue
    e ->
      reject(promise, e)
      promise
  end

  @doc false
  # A local promise settled by a message `{:pw, ref, result}`, `ref` being a monitor (of the
  # connection, for a call: its exit settles the promise with `TargetClosedError`).
  def from_monitor(ref, cancel \\ nil),
    do: %__MODULE__{kind: :local, ref: ref, pid: self(), monitor: ref, cancel: cancel}

  @doc false
  # A local promise settled by messages `{:pw, ref, payload}` that `handler` maps to a result, or
  # to `:continue` (keep waiting); `cancel` undoes the source once settled.
  def from_messages(ref, handler, cancel),
    do: %__MODULE__{kind: :local, ref: ref, pid: self(), handlers: [handler], cancel: cancel}

  @doc "`Promise.resolve(value)`"
  def resolved(value), do: %__MODULE__{kind: :settled, result: {:ok, value}}

  @doc "`Promise.reject(error)`"
  def rejected(error), do: %__MODULE__{kind: :settled, result: {:error, error}}

  @doc "`new Promise(resolve => setTimeout(resolve, ms))`, a local promise."
  def timer(ms) do
    ref = make_ref()
    timer = Process.send_after(self(), {:pw, ref, {:ok, nil}}, ms)

    %__MODULE__{
      kind: :local,
      ref: ref,
      pid: self(),
      cancel: fn ->
        Process.cancel_timer(timer)
        flush(ref)
      end
    }
  end

  ## Settling

  def resolve(promise, value), do: settle(promise, {:ok, value})
  def reject(promise, error), do: settle(promise, {:error, error})

  # Settled in the connection: the awaiter wakes after the dispatch's synchronous section (`Conn.wake/2`).
  defp settle(%__MODULE__{kind: :local, pid: pid, ref: ref}, result) do
    Conn.wake(pid, {:pw, ref, result})
    nil
  end

  defp settle(%__MODULE__{kind: :latch, owner: owner, ref: ref}, result) do
    Heap.atomic(owner, fn -> settle_latch(owner, ref, result) end)
    nil
  rescue
    # The owner's connection is gone: nothing can await the latch any more.
    TargetClosedError -> nil
  end

  defp settle_latch(owner, ref, result) do
    key = Heap.key(owner, {:latch, ref})

    case :ets.lookup(owner.table, key) do
      [{_, {:settled, _}}] ->
        :ok

      found ->
        with [{_, {:pending, waiters}}] <- found,
             do: for({pid, wref} <- waiters, do: Conn.wake(pid, {:pw, wref, result}))

        if Heap.readable?(owner), do: :ets.insert(owner.table, {key, {:settled, result}})
    end
  end

  ## Reactions

  @doc """
  `promise.then(on_fulfilled)`: lazy, runs in the awaiting process, so only when the derived
  promise is awaited (raced). A reaction run for its side effect, which nothing awaits
  (`p.then(sideEffect)`), is `void(fn -> side_effect.(await(p)) end)` (`p` a latch: another
  process awaits it); JS runs it when `p` settles.
  """
  def then_(%__MODULE__{} = promise, on_fulfilled) do
    add_handler(promise, fn
      {:ok, value} -> safe(fn -> {:ok, on_fulfilled.(value)} end)
      other -> other
    end)
  end

  @doc "`promise.catch(on_rejected)`: lazy, as `then_/2` (an un-awaited `p.catch(log)` never runs)."
  def catch_(%__MODULE__{} = promise, on_rejected) do
    add_handler(promise, fn
      {:error, error} -> safe(fn -> {:ok, on_rejected.(error)} end)
      other -> other
    end)
  end

  defp add_handler(promise, handler), do: %{promise | handlers: promise.handlers ++ [handler]}

  defp safe(fun) do
    fun.()
  catch
    kind, reason -> {:error, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  @doc "`Promise.race(promises)`"
  def race(promises), do: %__MODULE__{kind: :race, promises: promises}

  @doc "`Promise.all(promises)`"
  def all(promises), do: %__MODULE__{kind: :all, promises: promises}

  ## Async functions

  @doc """
  Calls an async function without awaiting it: `fun` runs in a process of its own (with the
  caller's zone); this returns once `fun` returned or first blocked on Playwright, so what it set
  up (subscriptions, sent messages) is in place, as in JS. Inside the connection the process
  starts at the current dispatch step, and dispatch waits for it the same way.

  The result settles a local promise of the caller (awaited by it, once), or with `shared: true`
  a latch owned by the caller process: awaitable from any process, any number of times, until
  the caller exits. With `owner: object`, a latch on that object (a promise kept in its field).
  """
  def async(fun, opts \\ []) when is_function(fun, 0) do
    promise =
      cond do
        owner = opts[:owner] -> new(owner)
        Keyword.get(opts, :shared, false) -> new(ProcessOwner.owner(self()))
        true -> local_alias()
      end

    start(fn ->
      result = run_async(fun)
      settle_async(promise, result)
      Invocation.yield()
    end)

    promise
  end

  # A local promise settled through an alias of its creator: `free/1` (unalias) drops a result
  # that comes later, so a promise nobody awaits any more leaves no message behind.
  defp local_alias do
    ref = :erlang.alias()

    %__MODULE__{
      kind: :local,
      ref: ref,
      pid: self(),
      cancel: fn ->
        :erlang.unalias(ref)
        flush(ref)
      end
    }
  end

  defp settle_async(%__MODULE__{kind: :local, ref: ref}, result), do: send(ref, {:pw, ref, result})
  defp settle_async(promise, result), do: settle(promise, result)

  @doc """
  `if (!obj.field) obj.field = (async () => fun())(); return obj.field;` with the check and the
  store in one atomic step, so concurrent callers share one run of `fun`: returns the latch (on
  `obj`) kept in `field`.
  """
  def async_once(obj, field, fun) when is_function(fun, 0) do
    latch = new(obj)

    {promise, started} =
      Heap.atomic(obj, fn ->
        case Heap.get(obj, field) do
          nil ->
            Heap.put(obj, field, latch)
            {latch, true}

          promise ->
            {promise, false}
        end
      end)

    if started, do: void(fn -> settle(latch, run_async(fun)) end)
    promise
  end

  @doc """
  Runs `fun` for its effects, as `promise.catch(() => {})` of a call nobody awaits: like
  `async/1`, but its result and errors are dropped.
  """
  def void(fun) when is_function(fun, 0) do
    start(fn ->
      run_async(fun)
      Invocation.yield()
    end)

    nil
  end

  defp run_async(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:error, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  # Starts `body` in a process that runs as the caller until its first yield.
  defp start(body) do
    caller = self()
    zone = Zones.current_zone()
    barrier = Process.get(:pw_barrier)
    in_conn = Conn.in_conn?()
    inv = make_ref()

    pid =
      spawn(fn ->
        Zones.restore(zone)
        # Inside the connection: started (and waited for) at the current dispatch step.
        barrier =
          if in_conn do
            receive do
              {:pw_go, ^inv} -> inv
            end
          else
            barrier
          end

        Invocation.start(caller, inv, barrier)
        body.()
      end)

    if in_conn do
      Conn.push_step({:start, pid, inv})
    else
      mref = Process.monitor(pid)

      receive do
        {:pw_yield, ^inv} -> Process.demonitor(mref, [:flush])
        {:DOWN, ^mref, :process, _, reason} -> exit(reason)
      end
    end

    pid
  end

  ## Awaiting

  @doc "`await promise`: its value, raising its error."
  def await(%__MODULE__{} = promise) do
    if Conn.in_conn?(), do: raise("await inside the connection process (dispatch must not block)")
    Invocation.yield()

    case wait(promise) do
      {:ok, value} -> value
      {:error, %{__exception__: true} = error} -> raise error
      {:error, other} -> raise "Promise rejected with #{inspect(other)}"
    end
  end

  @doc false
  # Waits for the promise: `{:ok, value} | {:error, error}`.
  def wait(promise) do
    armed = arm(promise)
    {result, armed} = receive_loop(armed)
    finish(armed)
    result
  end

  # Armed nodes: {:done, result, leaves_to_finish} | {:leaf, ref, promise, mon} | {:race | :all, [node], handlers}
  defp arm(%__MODULE__{kind: :settled, result: result, handlers: handlers}),
    do: done(apply_handlers(handlers, result), [])

  defp arm(%__MODULE__{kind: :local, pid: pid} = promise) do
    if pid != self(), do: raise("a local promise of #{inspect(pid)} is awaited by #{inspect(self())}")
    {:leaf, promise.ref, promise, promise.monitor}
  end

  defp arm(%__MODULE__{kind: :latch, owner: owner} = promise) do
    wref = make_ref()
    me = self()

    result =
      try do
        Heap.atomic(owner, fn -> arm_latch(promise, me, wref) end)
      rescue
        e in TargetClosedError -> {:settled, {:error, e}}
      end

    armed_leaf(promise, wref, result)
  end

  defp arm(%__MODULE__{kind: kind, promises: promises, handlers: handlers}) when kind in [:race, :all],
    do: settle_node({kind, Enum.map(promises, &arm/1), handlers})

  # In the latch's connection: registers `me` as a waiter, or returns the result.
  defp arm_latch(%__MODULE__{owner: owner, ref: ref}, me, wref) do
    key = Heap.key(owner, {:latch, ref})

    case :ets.lookup(owner.table, key) do
      [{_, {:settled, result}}] ->
        {:settled, result}

      found ->
        if Heap.alive?(owner) do
          waiters = with [{_, {:pending, waiters}}] <- found, do: waiters
          :ets.insert(owner.table, {key, {:pending, [{me, wref} | waiters || []]}})
          :armed
        else
          {:settled, {:error, TargetClosedError.new()}}
        end
    end
  end

  defp armed_leaf(promise, _wref, {:settled, result}), do: done(apply_handlers(promise.handlers, result), [])
  defp armed_leaf(promise, wref, :armed), do: {:leaf, wref, promise, nil}

  @doc """
  Elixir only: `await Promise.all(fun())` where `fun` runs in `obj`'s connection, in one atomic
  step with arming the latches it returns (latches of that connection): a latch it reads cannot
  settle and be freed (`free/1`) before it is armed. `fun` must not await.
  """
  def await_all_atomic(obj, fun) when is_function(fun, 0) do
    if Conn.in_conn?(), do: raise("await inside the connection process (dispatch must not block)")
    Invocation.yield()
    me = self()

    armed =
      Heap.atomic(obj, fn ->
        for promise <- fun.() do
          wref = make_ref()
          {promise, wref, arm_latch(promise, me, wref)}
        end
      end)

    armed =
      settle_node({:all, Enum.map(armed, fn {promise, wref, result} -> armed_leaf(promise, wref, result) end), []})

    {result, armed} = receive_loop(armed)
    finish(armed)

    case result do
      {:ok, value} -> value
      {:error, %{__exception__: true} = error} -> raise error
      {:error, other} -> raise "Promise rejected with #{inspect(other)}"
    end
  end

  defp done(:continue, _), do: raise("a settled promise cannot continue")
  defp done(result, leaves), do: {:done, result, leaves}

  defp apply_handlers(handlers, payload) do
    Enum.reduce_while(handlers, payload, fn handler, payload ->
      case handler.(payload) do
        :continue -> {:halt, :continue}
        result -> {:cont, result}
      end
    end)
  end

  defp receive_loop({:done, result, _} = armed), do: {result, armed}

  defp receive_loop(armed) do
    {refs, mons} = waiting(armed, %{}, %{})

    receive do
      {:pw, ref, payload} when is_map_key(refs, ref) ->
        receive_loop(feed(armed, ref, payload))

      {:DOWN, mon, :process, _, reason} when is_map_key(mons, mon) ->
        receive_loop(feed(armed, mons[mon], {:down, reason}))
    end
  end

  defp waiting({:leaf, ref, _promise, mon}, refs, mons),
    do: {Map.put(refs, ref, true), if(mon, do: Map.put(mons, mon, ref), else: mons)}

  defp waiting({:done, _, _}, refs, mons), do: {refs, mons}

  defp waiting({_kind, children, _handlers}, refs, mons),
    do: Enum.reduce(children, {refs, mons}, fn child, {r, m} -> waiting(child, r, m) end)

  defp feed({:leaf, ref, promise, _mon} = leaf, ref, payload) do
    case apply_handlers(promise.handlers, payload(promise, payload)) do
      :continue -> leaf
      result -> done(result, [{:won, leaf}])
    end
  end

  defp feed({kind, children, handlers}, ref, payload) when kind in [:race, :all],
    do: settle_node({kind, Enum.map(children, &feed(&1, ref, payload)), handlers})

  defp feed(node, _ref, _payload), do: node

  defp payload(_promise, {:down, _reason}), do: {:error, TargetClosedError.new()}
  defp payload(_promise, payload), do: payload

  # A race settles with its first settled child, an all with its first error or all values.
  defp settle_node({:race, children, handlers} = node) do
    case Enum.find(children, &match?({:done, _, _}, &1)) do
      {:done, result, _} -> done_composite(handlers, result, children)
      nil -> node
    end
  end

  defp settle_node({:all, children, handlers} = node) do
    cond do
      error = Enum.find(children, &match?({:done, {:error, _}, _}, &1)) ->
        done_composite(handlers, elem(error, 1), children)

      Enum.all?(children, &match?({:done, _, _}, &1)) ->
        done_composite(handlers, {:ok, Enum.map(children, fn {:done, {:ok, value}, _} -> value end)}, children)

      true ->
        node
    end
  end

  defp done_composite(handlers, result, children) do
    case apply_handlers(handlers, result) do
      :continue -> raise "a race or all cannot continue"
      result -> {:done, result, Enum.flat_map(children, &leaves/1)}
    end
  end

  # The leaves of a settled composite: those that settled (won) and those still armed (lost).
  defp leaves({:done, _, leaves}), do: leaves
  defp leaves({:leaf, _, _, _} = leaf), do: [{:lost, leaf}]
  defp leaves({_kind, children, _}), do: Enum.flat_map(children, &leaves/1)

  # Winners: cancel their source (unsubscribe, timer). Losers: a local stays pending (its
  # message may still come), a latch is disarmed.
  defp finish({:done, _result, leaves}), do: Enum.each(leaves, &finish_leaf/1)

  defp finish_leaf({:won, {:leaf, _ref, promise, mon}}) do
    if mon, do: Process.demonitor(mon, [:flush])
    if promise.cancel, do: promise.cancel.()
  end

  defp finish_leaf({:lost, {:leaf, ref, %{kind: :latch, owner: owner, ref: latch}, _}}) do
    disarm_latch(owner, latch, ref)
    flush(ref)
  end

  defp finish_leaf({:lost, _leaf}), do: :ok

  defp disarm_latch(owner, latch, wref) do
    Heap.atomic(owner, fn ->
      key = Heap.key(owner, {:latch, latch})

      with [{_, {:pending, waiters}}] <- :ets.lookup(owner.table, key),
           do: :ets.insert(owner.table, {key, {:pending, Enum.reject(waiters, &(elem(&1, 1) == wref))}})
    end)
  rescue
    TargetClosedError -> :ok
  end

  @doc """
  Elixir only: drops a promise nobody awaits any more (a latch's row, a timer, a subscription;
  late messages of a local promise).
  """
  def free(%__MODULE__{kind: :latch, owner: owner, ref: ref}) do
    Heap.atomic(owner, fn -> :ets.delete(owner.table, Heap.key(owner, {:latch, ref})) end)
    :ok
  rescue
    TargetClosedError -> :ok
  end

  def free(%__MODULE__{kind: :local, cancel: cancel, ref: ref}) do
    if cancel, do: cancel.()
    flush(ref)
  end

  def free(%__MODULE__{}), do: :ok

  @doc false
  def flush(ref) do
    receive do
      {:pw, ^ref, _} -> flush(ref)
    after
      0 -> :ok
    end
  end

  @doc false
  # Whether the promise settled (a latch or a settled promise; locals: unknown, false).
  def settled?(%__MODULE__{kind: :settled}), do: true

  def settled?(%__MODULE__{kind: :latch, owner: owner, ref: ref}) do
    match?([{_, {:settled, _}}], :ets.lookup(owner.table, Heap.key(owner, {:latch, ref})))
  rescue
    ArgumentError -> false
  end

  def settled?(_promise), do: false

  @doc false
  def log_uncaught(kind, reason, stacktrace, what \\ "promise"),
    do: Logger.error("Uncaught in #{what}: " <> Exception.format(kind, reason, stacktrace))
end
