defmodule PlaywrightEx.Test.Pool do
  @moduledoc false
  # The drivers of `PlaywrightEx.Test.browser/1`, each in a `PlaywrightEx.Test.Pool.Slot`. A slot
  # is `{pid, driver_key}`, the key its `driver` options and `on_start`.
  #
  # Shared (after Fluffy's `BrowserRuntime`): one slot per key, used by modules at once.
  # Exclusive (`isolate: true`, upstream's worker model): an owner (`{module, parameters}`)
  # checks a slot out in `setup_all`, its further `browser/2` calls get the same slot, and
  # `PlaywrightEx.Test.Formatter` checks it in at `module_finished`, discarded after a failure.
  # At most `max_isolated` exclusive slots run at once, the rest wait.
  #
  # Started unlinked on first use (`ensure_started/0`), never with the application (a release
  # has no ExUnit): its lifetime is the run. The first slot registers the `ExUnit.after_suite/1`
  # that stops the drivers.
  use GenServer

  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool.Slot

  require Logger

  # A module whose `module_finished` never comes (ExUnit's `max_failures`, or an owner whose
  # parameters were guessed wrong) would hold its slot for the rest of the run: after this long
  # without a check-in, the first waiting module gets one above `max_isolated`.
  @wait 120_000

  @doc "`PlaywrightEx.Test`'s table (public, owned here): recorder, context and retained-files rows."
  def table, do: __MODULE__

  @doc "Starts the pool unless it runs. Two callers racing is fine."
  def ensure_started do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc "Whether the pool runs (its table exists)."
  def started?, do: :ets.whereis(table()) != :undefined

  @doc "`%{playwright: _, browser: _}` for `opts` (see `PlaywrightEx.Test.Options.browser/1`)."
  def browser(opts, owner) do
    ensure_started()
    __MODULE__ |> GenServer.call({:slot, driver_key(opts), opts, owner}, :infinity) |> Slot.browser(opts)
  end

  @doc "Checks in the exclusive slots of `owner` (`{module, parameters}`), discarding them if it `failed?`."
  def module_finished(owner, failed?), do: GenServer.cast(__MODULE__, {:module_finished, owner, failed?})

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
    # `busy` by owner (`{module, parameters}`); `discarding`: slots stopping, still linked.
    {:ok, %{shared: %{}, free: [], busy: %{}, discarding: [], waiting: [], timer: nil, after_suite?: false}}
  end

  @impl true
  def handle_call({:slot, key, %{isolate: false} = opts, _module}, _from, state) do
    case state.shared do
      %{^key => slot} ->
        {:reply, slot, state}

      _ ->
        {slot, state} = start_slot(state, key, opts)
        {:reply, slot, %{state | shared: Map.put(state.shared, key, slot)}}
    end
  end

  def handle_call({:slot, key, opts, owner}, from, state) do
    # The owner's next call (another browser): the same driver.
    if slot = Enum.find(Map.get(state.busy, owner, []), &match?({_, ^key}, &1)) do
      {:reply, slot, state}
    else
      case checkout(state, key, opts, owner) do
        {slot, state} ->
          {:reply, slot, state}

        :full ->
          state = %{state | waiting: state.waiting ++ [{key, opts, owner, from}]}
          {:noreply, if(state.timer, do: state, else: arm(state))}
      end
    end
  end

  # The discarding slots too: `Slot.stop/1` of a stopping slot waits for it to exit.
  def handle_call(:take_all, _from, state) do
    slots = Map.values(state.shared) ++ state.free ++ Enum.concat(Map.values(state.busy)) ++ state.discarding
    for {_key, _opts, _owner, from} <- state.waiting, do: GenServer.reply(from, :stopped)
    for {pid, _key} <- slots, do: Process.unlink(pid)
    {:reply, slots, arm(%{state | shared: %{}, free: [], busy: %{}, discarding: [], waiting: []})}
  end

  @impl true
  # Every module finishes here, shared or not.
  def handle_cast({:module_finished, owner, failed?}, state) do
    case Map.pop(state.busy, owner) do
      {nil, _busy} ->
        {:noreply, state}

      {slots, busy} ->
        state = %{state | busy: busy}

        state =
          if failed? do
            Enum.reduce(slots, state, &discard(&2, &1))
          else
            Enum.each(slots, &Slot.check_in/1)
            %{state | free: slots ++ state.free}
          end

        # A check-in is progress: the wait starts anew.
        {:noreply, state |> serve_waiting() |> arm()}
    end
  end

  @impl true
  def handle_info({:waited, ref}, %{timer: {ref, _}, waiting: [{key, opts, owner, from} | waiting]} = state) do
    Logger.warning(
      "PlaywrightEx.Test could not get #{inspect(elem(owner, 0))} an isolated driver: none was " <>
        "checked in for #{div(@wait, 1000)} s, it gets one above max_isolated"
    )

    {slot, state} = start_isolated(%{state | waiting: waiting}, key, opts, owner)
    GenServer.reply(from, slot)
    {:noreply, arm(state)}
  end

  # A timer cancelled too late.
  def handle_info({:waited, _ref}, state), do: {:noreply, state}

  # A slot that stopped (discarded) or crashed: forget it.
  def handle_info({:EXIT, pid, _reason}, state) do
    gone? = &match?({^pid, _}, &1)
    shared = Map.reject(state.shared, fn {_key, slot} -> gone?.(slot) end)
    busy = Map.new(state.busy, fn {owner, slots} -> {owner, Enum.reject(slots, gone?)} end)
    free = Enum.reject(state.free, gone?)
    discarding = Enum.reject(state.discarding, gone?)
    {:noreply, serve_waiting(%{state | shared: shared, free: free, busy: busy, discarding: discarding})}
  end

  # A free slot of the key, else a new one while there is room, made by stopping an idle slot
  # of another key if need be.
  defp checkout(state, key, opts, owner) do
    case Enum.split_with(state.free, &match?({_, ^key}, &1)) do
      {[slot | same], others} ->
        {slot, busy(%{state | free: same ++ others}, owner, slot)}

      {[], _} ->
        cond do
          length(state.free) + Enum.sum(Enum.map(Map.values(state.busy), &length/1)) < Options.max_isolated() ->
            start_isolated(state, key, opts, owner)

          state.free != [] ->
            {idle, free} = List.pop_at(state.free, -1)
            state |> Map.put(:free, free) |> discard(idle) |> start_isolated(key, opts, owner)

          true ->
            :full
        end
    end
  end

  # The waiting modules, first come first served, while slots are free or there is room.
  defp serve_waiting(%{waiting: [{key, opts, owner, from} | rest]} = state) do
    case checkout(%{state | waiting: rest}, key, opts, owner) do
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

  defp start_isolated(state, key, opts, owner) do
    {slot, state} = start_slot(state, key, opts)
    {slot, busy(state, owner, slot)}
  end

  defp busy(state, owner, slot), do: %{state | busy: Map.update(state.busy, owner, [slot], &[slot | &1])}

  # A driver's stop waits for it to exit (up to ~31 s): not in the pool's process. The slot
  # stays linked until its exit, so `after_suite/1` waits for it too.
  defp discard(state, slot) do
    Task.start(fn -> Slot.stop(slot) end)
    %{state | discarding: [slot | state.discarding]}
  end

  # The one timer of the waiting modules, (re)started while any wait.
  defp arm(state) do
    with {_ref, timer} <- state.timer, do: Process.cancel_timer(timer)
    ref = make_ref()

    if state.waiting == [],
      do: %{state | timer: nil},
      else: %{state | timer: {ref, Process.send_after(self(), {:waited, ref}, @wait)}}
  end

  defp register_after_suite(%{after_suite?: true} = state), do: state

  defp register_after_suite(state) do
    if Code.ensure_loaded?(ExUnit) and is_list(Application.get_env(:ex_unit, :after_suite)),
      do: ExUnit.after_suite(&__MODULE__.after_suite/1)

    %{state | after_suite?: true}
  end
end
