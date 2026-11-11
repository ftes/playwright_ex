defmodule PlaywrightEx.Test.Pool do
  @moduledoc false
  # The drivers of `PlaywrightEx.Test.browser/1`, each in a `PlaywrightEx.Test.Pool.Slot`, and the
  # results of the tests of modules that `use PlaywrightEx.Test`. A slot is `{pid, driver_key}`,
  # the key its `driver` options and `on_start`.
  #
  # At most `workers` slots run, as upstream's worker processes; a module (its token, one per
  # `setup_all`, so per parameter set) takes them on its first `browser/2` of a key, as
  # upstream's worker-scoped `browser` fixture is lazy, and `module_finished/1` (the module's
  # last `on_exit`) gives them back.
  #
  # Shared (after Fluffy's `BrowserRuntime`): modules of a key at once on its slots. A module
  # joins the one fewest modules hold; another starts while each would hold more than its share
  # of the modules ExUnit runs at once (`ceil(max_cases / workers)`) and there is room. A call
  # with no token (a hand-made context map) uses that slot without joining it.
  #
  # Exclusive (`isolate: true`, upstream's worker model): a module checks a slot out; its
  # further calls get the same slot, and at its end the slot is checked in if a test of it ran
  # and all passed, else discarded.
  #
  # Room for a new slot is made by stopping idle ones (checked in, or shared and held by none);
  # with none, the caller waits, unless its module holds a slot already: a module's further
  # driver keys go over `workers`, so no module waits while it holds a slot others wait for. A
  # waiter that exits, or whose module ended, is dropped.
  #
  # A test's result (`watch/3`, `result/2`): passed when the `test` macro marked the end of its
  # body (`{:passed, pid}`) and its process then exited `:shutdown`, as ExUnit's runner ends it.
  # The messages a test process sends arrive before its `DOWN`.
  #
  # Started unlinked on first use (`ensure_started/0`), never with the application (a release
  # has no ExUnit): its lifetime is the run. The first slot registers the `ExUnit.after_suite/1`
  # that stops the drivers.
  use GenServer

  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool.Slot

  # ExUnit kills a test's process past its timeout; so can a test. No stacktrace either way.
  @killed "The test process was killed (ExUnit's timeout, or an explicit kill)."
  # A marked test that raised nothing in its body and did not pass.
  @outside "The test failed outside its body (setup, context pattern or a linked process); see ExUnit's output."

  @doc "`PlaywrightEx.Test`'s table (public, owned here): recorder and context rows."
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

  @doc "`%{playwright: _, browser: _}` for `opts` (see `PlaywrightEx.Test.Options.browser/1`) and the module `token`."
  def browser(opts, token) do
    ensure_started()
    __MODULE__ |> GenServer.call({:slot, driver_key(opts), opts, token}, :infinity) |> Slot.browser(opts)
  end

  @doc "A new module's token."
  def start_module do
    ensure_started()
    make_ref()
  end

  @doc """
  Once the module's watched tests have ended: leaves its shared slots and checks in its
  exclusive ones if a test ran and all passed, else discards them. Then forgets their results.
  """
  def module_finished(token), do: GenServer.call(__MODULE__, {:module_finished, token}, :infinity)

  @doc """
  Monitors the test process `pid` of the module `token`, once. `marked`: `false`, or the failure
  of a test whose `test` macro marks the end of the body and that raised nothing in it.
  """
  def watch(pid, token, marked) do
    ensure_started()
    GenServer.call(__MODULE__, {:watch, pid, token, marked}, :infinity)
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

  @doc false
  # The `ExUnit.after_suite/1` callback: stops every driver, in parallel (`mix test` halts the VM
  # without stopping applications, and a driver that outlives the VM resets the terminal, #191).
  # The next `browser/2` starts them anew.
  def after_suite(_stats) do
    if Process.whereis(__MODULE__) do
      __MODULE__
      |> GenServer.call(:take_all, :infinity)
      |> Task.async_stream(&Slot.stop/1, timeout: :infinity, max_concurrency: 64)
      |> Stream.run()
    end

    :ok
  end

  defp driver_key(opts), do: {Enum.sort(opts.driver), opts.on_start}

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    :ets.new(table(), [:named_table, :public, :set])

    # `shared` by key, each slot with the tokens holding it; `busy` by module token;
    # `discarding`: slots stopping, still linked; `waiting`: callers waiting for room, monitored.
    # `tests`: the watched test processes alive; `results` those ended, until their module
    # finishes; `modules` by token: its tests alive and ended, and `outcome` (`nil` while no
    # test ended, `:passed` while all passed, else `:failed`); `finishing` a `module_finished/1`
    # waiting for tests; `finished` the tokens of the modules that ended.
    {:ok,
     %{
       shared: %{},
       free: [],
       busy: %{},
       discarding: [],
       waiting: [],
       after_suite?: false,
       tests: %{},
       results: %{},
       modules: %{},
       finishing: %{},
       finished: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:slot, key, opts, token}, {pid, _} = from, state) do
    with false <- MapSet.member?(state.finished, token),
         {slot, state} <- request(state, key, opts, token) do
      {:reply, slot, state}
    else
      true ->
        {:reply, :finished, state}

      :full ->
        waiter = %{key: key, opts: opts, token: token, from: from, ref: Process.monitor(pid)}
        {:noreply, %{state | waiting: state.waiting ++ [waiter]}}
    end
  end

  # The discarding slots too: `Slot.stop/1` of a stopping slot waits for it to exit.
  def handle_call(:take_all, _from, state) do
    slots = shared_slots(state) ++ state.free ++ Enum.concat(Map.values(state.busy)) ++ state.discarding
    for waiter <- state.waiting, do: GenServer.reply(waiter.from, :stopped)
    for {pid, _key} <- slots, do: Process.unlink(pid)
    {:reply, slots, %{state | shared: %{}, free: [], busy: %{}, discarding: [], waiting: []}}
  end

  def handle_call({:watch, pid, token, marked}, _from, state) do
    if Map.has_key?(state.tests, pid) or Map.has_key?(state.results, pid) do
      {:reply, :ok, state}
    else
      Process.monitor(pid)
      test = %{token: token, marked: marked, passed?: false, failures: [], awaiting: []}

      state =
        update_module(%{state | tests: Map.put(state.tests, pid, test)}, token, &%{&1 | live: MapSet.put(&1.live, pid)})

      {:reply, :ok, state}
    end
  end

  def handle_call({:result, pid}, from, state) do
    case state do
      %{results: %{^pid => {_token, verdict, failures}}} -> {:reply, {verdict, failures}, state}
      %{tests: %{^pid => _}} -> {:noreply, update_in(state.tests[pid].awaiting, &[from | &1])}
      _ -> {:reply, {nil, []}, state}
    end
  end

  def handle_call({:module_finished, token}, from, state) do
    if running?(state, token),
      do: {:noreply, put_in(state.finishing[token], from)},
      else: {:reply, :ok, finish_module(state, token)}
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

  # A test process (watched), or a waiting caller, exited: a test process that waits has two
  # monitors, and the first `DOWN` does both.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    state = %{state | waiting: Enum.reject(state.waiting, &match?(%{from: {^pid, _}}, &1))}

    case Map.pop(state.tests, pid) do
      {nil, _tests} -> {:noreply, state}
      {test, tests} -> {:noreply, test_ended(%{state | tests: tests}, pid, test, reason)}
    end
  end

  # A slot that stopped (discarded) or crashed: forget it.
  def handle_info({:EXIT, pid, _reason}, state) do
    gone? = &match?({^pid, _}, &1)
    shared = Map.new(state.shared, fn {key, slots} -> {key, Map.reject(slots, fn {slot, _} -> gone?.(slot) end)} end)
    busy = Map.new(state.busy, fn {token, slots} -> {token, Enum.reject(slots, gone?)} end)
    free = Enum.reject(state.free, gone?)
    discarding = Enum.reject(state.discarding, gone?)
    {:noreply, serve_waiting(%{state | shared: shared, free: free, busy: busy, discarding: discarding})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp test_ended(state, pid, test, reason) do
    {verdict, failures} = verdict(test, pid, reason)
    for from <- test.awaiting, do: GenServer.reply(from, {verdict, failures})
    outcome = fn previous -> if verdict == :passed and previous != :failed, do: :passed, else: :failed end

    state =
      update_module(
        %{state | results: Map.put(state.results, pid, {test.token, verdict, failures})},
        test.token,
        &%{&1 | live: MapSet.delete(&1.live, pid), ended: [pid | &1.ended], outcome: outcome.(&1.outcome)}
      )

    case Map.pop(state.finishing, test.token) do
      {from, finishing} when from != nil ->
        if running?(state, test.token) do
          state
        else
          GenServer.reply(from, :ok)
          finish_module(%{state | finishing: finishing}, test.token)
        end

      _ ->
        state
    end
  end

  # ExUnit's runner exits a test's process `:shutdown` after the test and its setup, kills it
  # past its timeout, and a linked process's exit takes it down.
  defp verdict(%{passed?: true}, _pid, :shutdown), do: {:passed, []}
  defp verdict(%{marked: false}, _pid, :shutdown), do: {nil, []}
  defp verdict(%{failures: [_ | _] = failures}, _pid, :shutdown), do: {:failed, failures}
  defp verdict(%{marked: failure}, _pid, :shutdown), do: {:failed, [failure]}
  defp verdict(test, _pid, :killed), do: {:failed, test.failures ++ [@killed]}
  defp verdict(test, pid, reason), do: {:failed, test.failures ++ [{{:EXIT, pid}, reason, []}]}

  defp update_module(state, token, fun) do
    module = Map.get(state.modules, token, %{live: MapSet.new(), ended: [], outcome: nil})
    %{state | modules: Map.put(state.modules, token, fun.(module))}
  end

  # Whether a watched test of the module is still running.
  defp running?(state, token) do
    case state.modules do
      %{^token => %{live: live}} -> MapSet.size(live) > 0
      _ -> false
    end
  end

  # Leaves the module's shared slots; checks in its exclusive ones if a test ran and all passed,
  # else discards them; drops its waiters.
  defp finish_module(state, token) do
    {module, modules} = Map.pop(state.modules, token, %{ended: [], outcome: nil})
    {waiters, waiting} = Enum.split_with(state.waiting, &(&1.token == token))

    for waiter <- waiters do
      Process.demonitor(waiter.ref, [:flush])
      GenServer.reply(waiter.from, :finished)
    end

    {slots, busy} = Map.pop(state.busy, token, [])
    leave = fn slots -> Map.new(slots, fn {slot, tokens} -> {slot, MapSet.delete(tokens, token)} end) end

    state = %{
      state
      | results: Map.drop(state.results, module.ended),
        modules: modules,
        shared: Map.new(state.shared, fn {key, slots} -> {key, leave.(slots)} end),
        busy: busy,
        waiting: waiting,
        finished: MapSet.put(state.finished, token)
    }

    state =
      if module.outcome == :passed do
        Enum.each(slots, &Slot.check_in/1)
        %{state | free: slots ++ state.free}
      else
        Enum.reduce(slots, state, &discard(&2, &1))
      end

    serve_waiting(state)
  end

  # Exclusive: the module's slot of the key (a test's call, another browser), else a free one of
  # the key or a new one.
  defp request(state, key, %{isolate: true} = opts, token) do
    case Enum.find(Map.get(state.busy, token, []), &match?({_, ^key}, &1)) do
      nil -> checkout(state, key, opts, token)
      slot -> {slot, state}
    end
  end

  # Shared: the slot the module joined, else the one fewest modules hold while under its share,
  # else a new one, else (no room) the fewest-held anyway.
  defp request(state, key, opts, token) do
    slots = Map.get(state.shared, key, %{})
    {least, modules} = Enum.min_by(slots, fn {_slot, ms} -> MapSet.size(ms) end, &<=/2, fn -> {nil, nil} end)

    cond do
      joined = joined(slots, token) -> {joined, state}
      least && under_share?(modules, token) -> {least, join(state, key, least, token)}
      room = make_room(state, token) -> start_shared(room, key, opts, token)
      least -> {least, join(state, key, least, token)}
      true -> :full
    end
  end

  defp joined(_slots, nil), do: nil
  defp joined(slots, token), do: Enum.find_value(slots, fn {slot, ms} -> if MapSet.member?(ms, token), do: slot end)

  # A call without a token takes any slot of the key.
  defp under_share?(_modules, nil), do: true
  defp under_share?(modules, _token), do: MapSet.size(modules) < per_worker()

  defp start_shared(state, key, opts, token) do
    {slot, state} = start_slot(state, key, opts)
    {slot, join(state, key, slot, token)}
  end

  defp join(state, key, slot, token) do
    slots = Map.get(state.shared, key, %{})
    modules = Map.get(slots, slot, MapSet.new())
    modules = if token, do: MapSet.put(modules, token), else: modules
    %{state | shared: Map.put(state.shared, key, Map.put(slots, slot, modules))}
  end

  # How many of the modules ExUnit runs at once a shared slot holds before another starts.
  defp per_worker do
    workers = Options.workers()
    div(ExUnit.configuration()[:max_cases] + workers - 1, workers)
  end

  # A free slot of the key, else a new one.
  defp checkout(state, key, opts, token) do
    case Enum.split_with(state.free, &match?({_, ^key}, &1)) do
      {[slot | same], others} ->
        {slot, busy(%{state | free: same ++ others}, token, slot)}

      {[], _} ->
        if room = make_room(state, token), do: start_isolated(room, key, opts, token), else: :full
    end
  end

  # The state with room for a new slot under `workers`, made by stopping idle slots (checked-in
  # ones first, the longest idle first). Else nil when the slots in use fill it, unless the
  # module holds a slot already: then the state as is, over `workers`.
  defp make_room(state, token) do
    shared_idle = for {key, slots} <- state.shared, {slot, ms} <- slots, MapSet.size(ms) == 0, do: {key, slot}
    idle = Enum.map(Enum.reverse(state.free), &{nil, &1}) ++ shared_idle
    in_use = length(shared_slots(state)) + length(state.free) + Enum.sum_by(Map.values(state.busy), &length/1)
    excess = in_use + 1 - Options.workers()

    cond do
      excess <= 0 -> state
      excess <= length(idle) -> idle |> Enum.take(excess) |> Enum.reduce(state, &stop_idle(&2, &1))
      holds?(state, token) -> state
      true -> nil
    end
  end

  defp holds?(_state, nil), do: false

  defp holds?(state, token),
    do: Map.get(state.busy, token, []) != [] or Enum.any?(state.shared, fn {_key, slots} -> joined(slots, token) end)

  defp stop_idle(state, {nil, slot}), do: discard(%{state | free: List.delete(state.free, slot)}, slot)

  defp stop_idle(state, {key, slot}),
    do: discard(%{state | shared: Map.update!(state.shared, key, &Map.delete(&1, slot))}, slot)

  defp shared_slots(state), do: Enum.flat_map(Map.values(state.shared), &Map.keys/1)

  # The waiting callers, first come first served, while there is room. A caller that exited
  # meanwhile gets none: its slot would stay with a module that may have ended.
  defp serve_waiting(%{waiting: [waiter | rest]} = state) do
    {pid, _} = waiter.from
    state = %{state | waiting: rest}

    with true <- Process.alive?(pid),
         {slot, state} <- request(state, waiter.key, waiter.opts, waiter.token) do
      Process.demonitor(waiter.ref, [:flush])
      GenServer.reply(waiter.from, slot)
      serve_waiting(state)
    else
      false -> serve_waiting(state)
      :full -> %{state | waiting: [waiter | rest]}
    end
  end

  defp serve_waiting(state), do: state

  defp start_slot(state, key, opts) do
    {:ok, pid} = Slot.start_link(opts)
    {{pid, key}, register_after_suite(state)}
  end

  defp start_isolated(state, key, opts, token) do
    {slot, state} = start_slot(state, key, opts)
    {slot, busy(state, token, slot)}
  end

  defp busy(state, token, slot), do: %{state | busy: Map.update(state.busy, token, [slot], &[slot | &1])}

  # A driver's stop waits for it to exit (up to ~31 s): not in the pool's process. The slot
  # stays linked until its exit, so `after_suite/1` waits for it too.
  defp discard(state, slot) do
    Task.start(fn -> Slot.stop(slot) end)
    %{state | discarding: [slot | state.discarding]}
  end

  defp register_after_suite(%{after_suite?: true} = state), do: state

  defp register_after_suite(state) do
    if Code.ensure_loaded?(ExUnit) and is_list(Application.get_env(:ex_unit, :after_suite)),
      do: ExUnit.after_suite(&__MODULE__.after_suite/1)

    %{state | after_suite?: true}
  end
end
