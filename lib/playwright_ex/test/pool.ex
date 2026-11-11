defmodule PlaywrightEx.Test.Pool do
  @moduledoc false
  # The drivers of `PlaywrightEx.Test.browser/1`, each in a `PlaywrightEx.Test.Pool.Slot`, and the
  # results of the tests of modules that `use PlaywrightEx.Test`. A slot is `{pid, driver_key}`,
  # the key its `driver` options and `on_start`.
  #
  # Shared (after Fluffy's `BrowserRuntime`): one slot per key, used by modules at once.
  # Exclusive (`isolate: true`, upstream's worker model): a module (its token, one per
  # `setup_all`, so per parameter set) checks a slot out on its first `browser/2` of the key,
  # as upstream's worker-scoped `browser` fixture is lazy; its further calls get the same slot,
  # and `module_finished/1` (the module's last `on_exit`) checks it in, discarded if a test
  # failed. At most `max_isolated` exclusive slots run at once, the rest wait.
  #
  # A test's result (`watch/4`, `result/2`): passed when the `test` macro marked the end of its
  # body (`{:passed, pid}`) and its process then exited `:shutdown`, as ExUnit's runner ends it.
  # The messages a test process sends arrive before its `DOWN`.
  #
  # Started unlinked on first use (`ensure_started/0`), never with the application (a release
  # has no ExUnit): its lifetime is the run. The first slot registers the `ExUnit.after_suite/1`
  # that stops the drivers.
  use GenServer

  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool.Slot

  @doc "`PlaywrightEx.Test`'s table (public, owned here): recorder and context rows."
  def table, do: __MODULE__

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
  Checks in the module's exclusive slots, once its watched tests have ended: discarded if one
  failed. Then forgets their results.
  """
  def module_finished(token), do: GenServer.call(__MODULE__, {:module_finished, token}, :infinity)

  @doc """
  Monitors the test process `pid` of the module `token`, once. `marked`: `false`, or the failure
  of a test whose `test` macro marks the end of the body and that raised nothing in it (`"setup
  failed"`); `timeout_error`: the error of a test killed past its timeout.
  """
  def watch(pid, token, marked, timeout_error) do
    ensure_started()
    GenServer.call(__MODULE__, {:watch, pid, token, marked, timeout_error}, :infinity)
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

    # `busy` by module token; `discarding`: slots stopping, still linked. `tests`: the watched
    # test processes alive, `results` those ended (until their module finishes), `failed` the
    # tokens of modules with a failed test, `finishing` a `module_finished/1` waiting for tests.
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
       failed: MapSet.new(),
       finishing: %{}
     }}
  end

  @impl true
  def handle_call({:slot, key, %{isolate: false} = opts, _token}, _from, state) do
    case state.shared do
      %{^key => slot} ->
        {:reply, slot, state}

      _ ->
        {slot, state} = start_slot(state, key, opts)
        {:reply, slot, %{state | shared: Map.put(state.shared, key, slot)}}
    end
  end

  def handle_call({:slot, key, opts, token}, from, state) do
    # The module's next call (a test, another browser): the same driver.
    if slot = Enum.find(Map.get(state.busy, token, []), &match?({_, ^key}, &1)) do
      {:reply, slot, state}
    else
      case checkout(state, key, opts, token) do
        {slot, state} -> {:reply, slot, state}
        :full -> {:noreply, %{state | waiting: state.waiting ++ [{key, opts, token, from}]}}
      end
    end
  end

  # The discarding slots too: `Slot.stop/1` of a stopping slot waits for it to exit.
  def handle_call(:take_all, _from, state) do
    slots = Map.values(state.shared) ++ state.free ++ Enum.concat(Map.values(state.busy)) ++ state.discarding
    for {_key, _opts, _token, from} <- state.waiting, do: GenServer.reply(from, :stopped)
    for {pid, _key} <- slots, do: Process.unlink(pid)
    {:reply, slots, %{state | shared: %{}, free: [], busy: %{}, discarding: [], waiting: []}}
  end

  def handle_call({:watch, pid, token, marked, timeout_error}, _from, state) do
    if Map.has_key?(state.tests, pid) or Map.has_key?(state.results, pid) do
      {:reply, :ok, state}
    else
      Process.monitor(pid)

      test = %{
        token: token,
        marked: marked,
        timeout_error: timeout_error,
        passed?: false,
        failures: [],
        awaiting: []
      }

      {:reply, :ok, put_in(state.tests[pid], test)}
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

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{tests: tests} = state) when is_map_key(tests, pid) do
    {test, tests} = Map.pop(tests, pid)
    {verdict, failures} = verdict(test, pid, reason)
    for from <- test.awaiting, do: GenServer.reply(from, {verdict, failures})

    state = %{
      state
      | tests: tests,
        results: Map.put(state.results, pid, {test.token, verdict, failures}),
        failed: if(verdict == :failed, do: MapSet.put(state.failed, test.token), else: state.failed)
    }

    case Map.pop(state.finishing, test.token) do
      {from, finishing} when from != nil ->
        if running?(state, test.token) do
          {:noreply, state}
        else
          GenServer.reply(from, :ok)
          {:noreply, finish_module(%{state | finishing: finishing}, test.token)}
        end

      _ ->
        {:noreply, state}
    end
  end

  # A slot that stopped (discarded) or crashed: forget it.
  def handle_info({:EXIT, pid, _reason}, state) do
    gone? = &match?({^pid, _}, &1)
    shared = Map.reject(state.shared, fn {_key, slot} -> gone?.(slot) end)
    busy = Map.new(state.busy, fn {token, slots} -> {token, Enum.reject(slots, gone?)} end)
    free = Enum.reject(state.free, gone?)
    discarding = Enum.reject(state.discarding, gone?)
    {:noreply, serve_waiting(%{state | shared: shared, free: free, busy: busy, discarding: discarding})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Whether a watched test of the module is still running.
  defp running?(state, token), do: Enum.any?(state.tests, fn {_pid, test} -> test.token == token end)

  # ExUnit's runner exits a test's process `:shutdown` after the test and its setup, kills it
  # past its timeout, and a linked process's exit takes it down.
  defp verdict(%{passed?: true}, _pid, :shutdown), do: {:passed, []}
  defp verdict(%{marked: false}, _pid, :shutdown), do: {nil, []}
  defp verdict(%{failures: [_ | _] = failures}, _pid, :shutdown), do: {:failed, failures}
  defp verdict(%{marked: failure}, _pid, :shutdown), do: {:failed, [failure]}

  defp verdict(%{timeout_error: %_{} = error} = test, _pid, :killed),
    do: {:failed, test.failures ++ [{:error, error, []}]}

  defp verdict(test, pid, reason), do: {:failed, test.failures ++ [{{:EXIT, pid}, reason, []}]}

  defp finish_module(state, token) do
    failed? = MapSet.member?(state.failed, token)
    results = Map.reject(state.results, fn {_pid, {result_token, _, _}} -> result_token == token end)
    state = %{state | results: results, failed: MapSet.delete(state.failed, token)}

    case Map.pop(state.busy, token) do
      {nil, _busy} ->
        state

      {slots, busy} ->
        state = %{state | busy: busy}

        state =
          if failed? do
            Enum.reduce(slots, state, &discard(&2, &1))
          else
            Enum.each(slots, &Slot.check_in/1)
            %{state | free: slots ++ state.free}
          end

        serve_waiting(state)
    end
  end

  # A free slot of the key, else a new one while there is room, made by stopping an idle slot
  # of another key if need be.
  defp checkout(state, key, opts, token) do
    case Enum.split_with(state.free, &match?({_, ^key}, &1)) do
      {[slot | same], others} ->
        {slot, busy(%{state | free: same ++ others}, token, slot)}

      {[], _} ->
        busy = Enum.sum(Enum.map(Map.values(state.busy), &length/1))

        cond do
          length(state.free) + busy < Options.max_isolated() ->
            start_isolated(state, key, opts, token)

          # Busy slots alone may fill `max_isolated`: then the module waits.
          state.free != [] and busy < Options.max_isolated() ->
            {idle, free} = List.pop_at(state.free, -1)
            state |> Map.put(:free, free) |> discard(idle) |> start_isolated(key, opts, token)

          true ->
            :full
        end
    end
  end

  # The waiting modules, first come first served, while slots are free or there is room.
  defp serve_waiting(%{waiting: [{key, opts, token, from} | rest]} = state) do
    case checkout(%{state | waiting: rest}, key, opts, token) do
      {slot, state} ->
        GenServer.reply(from, slot)
        serve_waiting(state)

      :full ->
        state
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
