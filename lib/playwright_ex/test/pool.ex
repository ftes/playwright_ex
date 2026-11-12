defmodule PlaywrightEx.Test.Pool do
  @moduledoc false
  # The drivers of `PlaywrightEx.Test.BrowserPool`, each in a `PlaywrightEx.Test.Pool.Slot`, the
  # results of the registered tests (`use PlaywrightEx.Test`), and their recorders. A slot is
  # `{pid, driver_key}`, the key its `driver` options and `on_start`.
  #
  # Upstream's worker model: a scope (a registered test, found through the caller or its
  # `$callers`, else the calling process, `setup_all`'s) leases a slot per key; its further calls
  # of the key get the same slot, and its `release/1`, the last step of its `on_exit`, puts it on
  # the free list, warm, if the scope passed, else stops it. A test whose module (`setup_all`)
  # holds a lease calls on its module's, as upstream's tests share their worker's `browser`. A
  # test scope passed when the test did; another scope when a test of its module ran and all of
  # them passed: the tests of the ExUnit runner process that spawned the scope (`:parent`; the
  # runner spawns a module's `setup_all` and its tests, one module after another). At most
  # `workers` slots run, as upstream's worker processes (stopping ones count): room is made by
  # stopping free ones of other keys, the longest idle first, and the new one starts once they
  # exited; with none, the caller waits (first come first served, a warning after
  # `@wait_warning` ms), unless its scope holds a slot already (its further driver keys go over
  # `workers`, so no scope waits while it holds a slot others wait for). A waiter that exits, or
  # whose scope was released, is dropped.
  #
  # A test's result (`watch/2`, `result/2`): passed when the `test` macro marked the end of its
  # body (`{:passed, pid}`) and its process then exited `:shutdown`, as ExUnit's runner ends it.
  # The messages a test process sends arrive before its `DOWN`.
  #
  # Started unlinked on first use (`ensure_started/0`), never with the application (a release
  # has no ExUnit): its lifetime is the run. The first slot registers the `ExUnit.after_suite/1`
  # that stops the drivers.
  use GenServer

  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool.Slot
  alias PlaywrightEx.Test.TestInfo

  require Logger

  # ExUnit kills a test's process past its timeout; so can a test. No stacktrace either way.
  @killed "The test process was killed (ExUnit's timeout, or an explicit kill)."
  # A marked test that raised nothing in its body and did not pass.
  @outside "The test failed outside its body (setup, context pattern or a linked process); see ExUnit's output."
  @wait_warning 10_000

  @doc "`PlaywrightEx.Test`'s table (public, owned here): test, recorder, context and test info rows."
  def table, do: __MODULE__

  @doc "The failure of a test whose process was killed."
  def killed, do: @killed

  @doc "The failure of a marked test that failed outside its body."
  def outside, do: @outside

  @doc "Starts the pool unless it runs. Two callers racing is fine."
  def ensure_started do
    if !Process.whereis(__MODULE__) do
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  @doc "Whether the pool runs (its table exists)."
  def started?, do: :ets.whereis(table()) != :undefined

  @doc """
  `%{playwright: _, browser: _}` of the slot of `opts` leased by `scope`: a registered test
  (`{:test, pid}`, its result is the lease's, unless its module holds a lease), or another
  process (`{:process, pid}`, a `setup_all`'s: the results of its runner's tests are). `holder`
  names it in the wait warning.
  """
  def browser(opts, {kind, pid}, holder) do
    ensure_started()

    __MODULE__
    |> GenServer.call({:lease, driver_key(opts), opts, {kind, pid}, parent(pid), holder}, :infinity)
    |> Slot.browser(opts)
  end

  @doc "Ends the leases of `scope`: free and warm if it passed, else stopped."
  def release(scope) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:release, scope}, :infinity)
    :ok
  end

  @doc """
  Monitors the test process `pid`, once. `marked`: `false`, or the failure of a test whose `test`
  macro marks the end of the body and that raised nothing in it.
  """
  def watch(pid, marked) do
    ensure_started()
    GenServer.call(__MODULE__, {:watch, pid, parent(pid), marked}, :infinity)
  end

  @doc "Sends `message` (`{:passed, pid}`, `{:failed, pid, failure}`) if the pool runs."
  def notify(message) do
    if pid = Process.whereis(__MODULE__), do: send(pid, message)
    :ok
  end

  @doc """
  The result of the test `pid` once its process ended, waiting up to `timeout` ms:
  `{:passed, []}`, `{:failed, failures}` (`{kind, reason, stacktrace}` as ExUnit's, or a
  message), or `{nil, []}` when unknown (not watched, not marked, or past the wait).
  """
  def result(pid, timeout) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:result, pid}, timeout), else: {nil, []}
  catch
    :exit, _ -> {nil, []}
  end

  @doc "How long the ended test `pid` ran, in ms, from its `watch/2` to its exit; `nil` if unknown."
  def duration(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:duration, pid}, :infinity)
  end

  @doc """
  Keeps `info` (`PlaywrightEx.Test.info/1`'s, of the ended test `test_pid`) until the calling
  process, ExUnit's `on_exit` runner, exits: for the test's `on_exit` callbacks that run after
  its registration's.
  """
  def keep_info(test_pid, info) do
    :ets.insert(table(), {{:info, test_pid}, info})
    GenServer.cast(__MODULE__, {:keep_info, test_pid, self()})
  end

  @doc "Forgets the result of the test `pid`."
  def forget(pid) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:forget, pid})
    :ok
  end

  @doc """
  The recorder of the registered test `test_pid` (`PlaywrightEx.Test.Recorder`), started on the
  first call; `nil` once the test's `take/1` ran.
  """
  def recorder(test_pid) do
    case :ets.lookup(table(), {:recorder, test_pid}) do
      [{_key, pid}] -> pid
      [] -> GenServer.call(__MODULE__, {:recorder, test_pid}, :infinity)
    end
  end

  @doc "Unregisters the test `test_pid`: its registration row and its recorder (or `nil`)."
  def take(test_pid), do: GenServer.call(__MODULE__, {:take, test_pid}, :infinity)

  @doc "Notes `pid` as a process that created a context before it was registered, until it exits."
  def note_unregistered(pid) do
    if :ets.insert_new(table(), {{:unregistered, pid}, true}), do: GenServer.cast(__MODULE__, {:monitor, pid})
    :ok
  end

  @doc false
  # The `ExUnit.after_suite/1` callback: stops every driver, in parallel (`mix test` halts the VM
  # without stopping applications, and a driver that outlives the VM resets the terminal, #191).
  # The next call starts them anew.
  def after_suite(_stats) do
    if Process.whereis(__MODULE__) do
      __MODULE__
      |> GenServer.call(:take_all, :infinity)
      |> Task.async_stream(&Slot.stop/1, timeout: :infinity, max_concurrency: 64)
      |> Stream.run()
    end

    :ok
  end

  # Without `browser_name` and `launch_options`: one driver hosts every browser of its options.
  defp driver_key(opts), do: {Enum.sort(opts.driver), opts.on_start}

  # The ExUnit runner process that spawned `pid` (OTP 25+), `nil` if unknown.
  defp parent(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> parent
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    :ets.new(table(), [:named_table, :public, :set])

    # `free` newest first; `leases` by scope: `%{slots, runner, outcome, holder}` (`runner` a
    # `setup_all` scope's, else `nil`; `outcome` `nil` while no test of it ended, `:passed` while
    # all passed, else `:failed`); `stopping`: slots stopping, still linked; `waiting`: callers
    # waiting for room, monitored. `tests`: the watched test processes alive; `results` those
    # ended, until forgotten.
    {:ok,
     %{
       free: [],
       leases: %{},
       stopping: [],
       waiting: [],
       after_suite?: false,
       tests: %{},
       results: %{},
       durations: %{},
       kept: %{}
     }}
  end

  @impl true
  def handle_call({:lease, key, opts, {kind, pid}, parent, holder}, {caller, _} = from, state) do
    scope = scope(state, pid, parent)
    runner = if scope == pid and kind == :process, do: parent
    request = %{key: key, opts: opts, scope: scope, runner: runner, holder: holder}

    case lease(state, request) do
      {{_pid, _key} = slot, state} ->
        {:reply, slot, state}

      {:full, state} ->
        ref = Process.monitor(caller)
        Process.send_after(self(), {:waiting, ref}, @wait_warning)
        waiter = Map.merge(request, %{from: from, ref: ref})
        {:noreply, %{state | waiting: state.waiting ++ [waiter]}}
    end
  end

  def handle_call({:release, scope}, _from, state) do
    {waiters, waiting} = Enum.split_with(state.waiting, &(&1.scope == scope))

    for waiter <- waiters do
      Process.demonitor(waiter.ref, [:flush])
      GenServer.reply(waiter.from, :released)
    end

    state = %{state | waiting: waiting}

    case Map.pop(state.leases, scope) do
      {nil, _leases} ->
        {:reply, :ok, state}

      {lease, leases} ->
        state = %{state | leases: leases}

        state =
          if lease.outcome == :passed do
            Enum.each(lease.slots, &Slot.check_in/1)
            %{state | free: lease.slots ++ state.free}
          else
            Enum.reduce(lease.slots, state, &stop_slot(&2, &1))
          end

        {:reply, :ok, serve_waiting(state)}
    end
  end

  # The discarding slots too: `Slot.stop/1` of a stopping slot waits for it to exit.
  def handle_call(:take_all, _from, state) do
    leased = Enum.flat_map(Map.values(state.leases), & &1.slots)
    slots = state.free ++ leased ++ state.stopping
    for waiter <- state.waiting, do: GenServer.reply(waiter.from, :stopped)
    for {pid, _key} <- slots, do: Process.unlink(pid)
    {:reply, slots, %{state | free: [], leases: %{}, stopping: [], waiting: []}}
  end

  def handle_call({:watch, pid, runner, marked}, _from, state) do
    if Map.has_key?(state.tests, pid) or Map.has_key?(state.results, pid) do
      {:reply, :ok, state}
    else
      Process.monitor(pid)
      started = System.monotonic_time(:millisecond)
      test = %{runner: runner, marked: marked, passed?: false, failures: [], awaiting: [], started: started}
      {:reply, :ok, %{state | tests: Map.put(state.tests, pid, test)}}
    end
  end

  def handle_call({:result, pid}, from, state) do
    case state do
      %{results: %{^pid => result}} -> {:reply, result, state}
      %{tests: %{^pid => _}} -> {:noreply, update_in(state.tests[pid].awaiting, &[from | &1])}
      _ -> {:reply, {nil, []}, state}
    end
  end

  def handle_call({:duration, pid}, _from, state), do: {:reply, state.durations[pid], state}

  # One recorder per test, started here so that two processes of the test can't start two, and
  # none starts after the test's `take/1`.
  def handle_call({:recorder, test_pid}, _from, state) do
    reply =
      case :ets.lookup(table(), {:recorder, test_pid}) do
        [{_key, pid}] ->
          pid

        [] ->
          case :ets.lookup(table(), {:test, test_pid}) do
            [{_key, test}] ->
              {:ok, pid} = GenServer.start(PlaywrightEx.Test.Recorder, test)
              :ets.insert(table(), {{:recorder, test_pid}, pid})
              pid

            [] ->
              nil
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:take, test_pid}, _from, state) do
    [test] = for {_key, test} <- :ets.take(table(), {:test, test_pid}), do: test
    recorder = for {_key, pid} <- :ets.take(table(), {:recorder, test_pid}), do: pid
    {:reply, {test, List.first(recorder)}, state}
  end

  @impl true
  def handle_cast({:forget, pid}, state),
    do: {:noreply, %{state | results: Map.delete(state.results, pid), durations: Map.delete(state.durations, pid)}}

  def handle_cast({:keep_info, test_pid, keeper}, state) do
    Process.monitor(keeper)
    {:noreply, %{state | kept: Map.update(state.kept, keeper, [test_pid], &[test_pid | &1])}}
  end

  def handle_cast({:monitor, pid}, state) do
    Process.monitor(pid)
    {:noreply, state}
  end

  @impl true
  def handle_info({:passed, pid}, state) do
    case state.tests do
      %{^pid => _} -> {:noreply, put_in(state.tests[pid].passed?, true)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:failed, pid, failure}, state) do
    case state.tests do
      %{^pid => _} -> {:noreply, update_in(state.tests[pid].failures, &(&1 ++ [failure]))}
      _ -> {:noreply, state}
    end
  end

  # A waiter for over `@wait_warning` ms: the current holders, and the usual cause.
  def handle_info({:waiting, ref}, state) do
    with %{} = waiter <- Enum.find(state.waiting, &(&1.ref == ref)) do
      holders =
        for {_scope, lease} <- state.leases do
          "  #{lease.holder}: #{length(lease.slots)} driver(s)"
        end

      Logger.warning("""
      PlaywrightEx.Test.BrowserPool.browser/1 has waited #{div(@wait_warning, 1000)} s for one of \
      `workers` (#{Options.workers()}) drivers, for #{waiter.holder}. The holders:
      #{Enum.join(holders, "\n")}\
      """)
    end

    {:noreply, state}
  end

  # A test process (watched), a waiting caller or an unregistered creator of contexts exited: a
  # test process that waits has two monitors, and the first `DOWN` does both.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    :ets.delete(table(), {:unregistered, pid})
    {kept, state} = pop_in(state.kept[pid])
    for test_pid <- kept || [], do: :ets.delete(table(), {:info, test_pid})
    state = %{state | waiting: Enum.reject(state.waiting, &match?(%{from: {^pid, _}}, &1))}

    case Map.pop(state.tests, pid) do
      {nil, _tests} -> {:noreply, state}
      {test, tests} -> {:noreply, test_ended(%{state | tests: tests}, pid, test, reason)}
    end
  end

  # A slot that stopped or crashed: forget it, and serve the waiters its room.
  def handle_info({:EXIT, pid, _reason}, state) do
    gone? = &match?({^pid, _}, &1)
    leases = Map.new(state.leases, fn {scope, lease} -> {scope, %{lease | slots: Enum.reject(lease.slots, gone?)}} end)
    free = Enum.reject(state.free, gone?)
    stopping = Enum.reject(state.stopping, gone?)
    {:noreply, serve_waiting(%{state | free: free, leases: leases, stopping: stopping})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp test_ended(state, pid, test, reason) do
    # Its `PlaywrightEx.Test.TestInfo` rows, and the errors its matchers recorded that the end of
    # its body did not take: killed past its timeout, taken down by a linked process, a later
    # `setup` failed, or `--breakpoints` and an error. Upstream reports all of `testInfo.errors`
    # at the test's end: they fail it here, for `error-context.md` and the driver's release.
    # ExUnit reported the test already, without them: its output can't change once the process
    # died.
    {verdict, failures} =
      case {TestInfo.ended(pid), verdict(test, pid, reason)} do
        {[], result} -> result
        {errors, {_verdict, failures}} -> {:failed, Enum.map(errors, &normalize/1) ++ failures}
      end

    for from <- test.awaiting, do: GenServer.reply(from, {verdict, failures})
    outcome = fn previous -> if verdict == :passed and previous != :failed, do: :passed, else: :failed end

    # The test's own leases, and those of its module's scope (its runner's).
    leases =
      Map.new(state.leases, fn {scope, lease} ->
        if scope == pid or (lease.runner != nil and lease.runner == test.runner),
          do: {scope, %{lease | outcome: outcome.(lease.outcome)}},
          else: {scope, lease}
      end)

    duration = System.monotonic_time(:millisecond) - test.started

    %{
      state
      | results: Map.put(state.results, pid, {verdict, failures}),
        durations: Map.put(state.durations, pid, duration),
        leases: leases
    }
  end

  # ExUnit's runner exits a test's process `:shutdown` after the test and its setup, kills it
  # past its timeout, and a linked process's exit takes it down.
  defp verdict(%{passed?: true}, _pid, :shutdown), do: {:passed, []}
  defp verdict(%{marked: false}, _pid, :shutdown), do: {nil, []}
  defp verdict(%{failures: [_ | _] = failures}, _pid, :shutdown), do: {:failed, failures}
  defp verdict(%{marked: failure}, _pid, :shutdown), do: {:failed, [failure]}
  defp verdict(test, _pid, :killed), do: {:failed, test.failures ++ [@killed]}
  defp verdict(test, pid, reason), do: {:failed, test.failures ++ [{{:EXIT, pid}, reason, []}]}

  defp normalize({kind, reason, stacktrace}), do: {kind, Exception.normalize(kind, reason, stacktrace), stacktrace}

  # A test's calls (registered or not) go to its module's lease, if the module holds one: the
  # `setup_all` scope its runner spawned.
  defp scope(_state, pid, nil), do: pid

  defp scope(state, pid, parent) do
    Enum.find_value(state.leases, pid, fn {scope, lease} -> if lease.runner == parent, do: scope end)
  end

  # The scope's slot of the key (a repeated call), else a free one of the key or a new one.
  defp lease(state, request) do
    held = state.leases[request.scope][:slots] || []

    case Enum.find(held, &match?({_, key} when key == request.key, &1)) do
      nil -> checkout(state, request, held != [])
      slot -> {slot, state}
    end
  end

  defp checkout(state, request, held?) do
    key = request.key

    case Enum.split_with(state.free, &match?({_, ^key}, &1)) do
      {[slot | same], others} ->
        {slot, add_lease(%{state | free: same ++ others}, request, slot)}

      {[], _} ->
        case make_room(state, held?) do
          {:ok, state} ->
            {slot, state} = start_slot(state, key, request.opts)
            {slot, add_lease(state, request, slot)}

          full ->
            full
        end
    end
  end

  # `{:ok, state}` with room for a new slot under `workers`, else `{:full, state}`.
  # Slots leased, free and stopping count; room is made by stopping free slots (the longest idle
  # first), and the new slot starts once they exited, as upstream awaits `worker.stop()`. A scope
  # that holds a slot already does not wait: it goes over `workers`.
  defp make_room(state, held?) do
    leased = Enum.sum_by(Map.values(state.leases), &length(&1.slots))
    excess = leased + length(state.stopping) + length(state.free) + 1 - Options.workers()

    cond do
      excess <= 0 ->
        {:ok, state}

      excess <= length(state.free) ->
        {free, idle} = Enum.split(state.free, -excess)
        state = Enum.reduce(idle, %{state | free: free}, &stop_slot(&2, &1))
        if held?, do: {:ok, state}, else: {:full, state}

      held? ->
        {:ok, state}

      true ->
        {:full, state}
    end
  end

  defp add_lease(state, request, slot) do
    lease =
      Map.get(state.leases, request.scope, %{slots: [], runner: request.runner, outcome: nil, holder: request.holder})

    %{state | leases: Map.put(state.leases, request.scope, %{lease | slots: [slot | lease.slots]})}
  end

  # The waiting callers, first come first served, while there is room; one that finds none
  # keeps its place, and those after it are still served (a free slot of their key). A caller
  # that exited meanwhile gets none.
  defp serve_waiting(state), do: serve_waiting(%{state | waiting: []}, state.waiting)

  defp serve_waiting(state, []), do: state

  defp serve_waiting(state, [waiter | rest]) do
    {pid, _} = waiter.from

    with true <- Process.alive?(pid),
         {{_pid, _key} = slot, state} <- lease(state, waiter) do
      Process.demonitor(waiter.ref, [:flush])
      GenServer.reply(waiter.from, slot)
      serve_waiting(state, rest)
    else
      false -> serve_waiting(state, rest)
      {:full, state} -> serve_waiting(%{state | waiting: state.waiting ++ [waiter]}, rest)
    end
  end

  defp start_slot(state, key, opts) do
    {:ok, pid} = Slot.start_link(opts)
    {{pid, key}, register_after_suite(state)}
  end

  # A driver's stop waits for it to exit (up to ~31 s): not in the pool's process. The slot
  # stays linked until its exit, so `after_suite/1` waits for it too.
  defp stop_slot(state, slot) do
    Task.start(fn -> Slot.stop(slot) end)
    %{state | stopping: [slot | state.stopping]}
  end

  defp register_after_suite(%{after_suite?: true} = state), do: state

  defp register_after_suite(state) do
    if Code.ensure_loaded?(ExUnit) and is_list(Application.get_env(:ex_unit, :after_suite)),
      do: ExUnit.after_suite(&__MODULE__.after_suite/1)

    %{state | after_suite?: true}
  end
end
