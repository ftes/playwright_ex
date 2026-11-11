defmodule PlaywrightEx.Test.Pool do
  @moduledoc false
  # The drivers and browsers of `PlaywrightEx.Test.browser/1`, keyed by the module options
  # (`browser_name`, `launch_options`, `driver`, `on_start`). Each driver lives in a
  # `PlaywrightEx.Test.Pool.Slot`, which starts it, launches its browser and anchors it. A slot
  # is `{pid, key}`.
  #
  # Shared (after Fluffy's `BrowserRuntime`): one slot per key, used by modules at once.
  #
  # Exclusive (`isolate: true`, upstream's worker model, `test/support/test_workers.ex` before
  # it): a module checks a slot out in `setup_all` and `PlaywrightEx.Test.Formatter` checks it
  # in at `module_finished`, discarded after a failure. At most `max_isolated` exclusive slots
  # run at once, the rest wait.
  #
  # Started on first use in a test run (`ensure_started/0`), never with the application (a
  # release has no ExUnit). Unlinked, as the first caller is a module's `setup_all` process: its
  # lifetime is the run. The first slot registers the `ExUnit.after_suite/1` that stops the
  # drivers. The other entry points (the formatter's, `after_suite`) do nothing when it never
  # started. It owns the table of the recorders and retained files.
  use GenServer

  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool.Slot

  # A module whose `module_finished` never comes (ExUnit's `max_failures`) would hold its slot
  # for the rest of the run: after this a waiting module gets one above `max_isolated`.
  @wait 120_000

  @doc "The table of `PlaywrightEx.Test`'s recorders and retained files (public, owned here)."
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
  def browser(opts, module) do
    ensure_started()
    __MODULE__ |> GenServer.call({:slot, key(opts), opts, module}, :infinity) |> Slot.browser()
  end

  @doc "Checks in the exclusive slots of `module`, discarding them if it `failed?`."
  def module_finished(module, failed?), do: GenServer.cast(__MODULE__, {:module_finished, module, failed?})

  @doc "Stops every driver, in parallel. The next `browser/2` starts them anew."
  def stop_all do
    if Process.whereis(__MODULE__) do
      __MODULE__
      |> GenServer.call(:take_all, :infinity)
      |> Task.async_stream(&Slot.stop/1, timeout: :infinity, max_concurrency: 64)
      |> Stream.run()
    end

    :ok
  end

  @doc false
  # The `ExUnit.after_suite/1` callback: `mix test` halts the VM without stopping applications,
  # and a driver that outlives the VM resets the terminal (#191).
  def after_suite(_stats), do: stop_all()

  defp key(opts), do: {opts.browser_name, Enum.sort(opts.launch_options), Enum.sort(opts.driver), opts.on_start}

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    :ets.new(table(), [:named_table, :public, :set])
    {:ok, %{shared: %{}, free: [], busy: %{}, waiting: [], after_suite?: false}}
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

  def handle_call({:slot, key, opts, module}, from, state) do
    case checkout(state, key, opts, module) do
      {slot, state} ->
        {:reply, slot, state}

      :full ->
        Process.send_after(self(), {:waited, from}, @wait)
        {:noreply, %{state | waiting: state.waiting ++ [{key, opts, module, from}]}}
    end
  end

  def handle_call(:take_all, _from, state) do
    slots = Map.values(state.shared) ++ state.free ++ Enum.concat(Map.values(state.busy))
    for {_key, _opts, _module, from} <- state.waiting, do: GenServer.reply(from, :stopped)
    for {pid, _key} <- slots, do: Process.unlink(pid)
    {:reply, slots, %{state | shared: %{}, free: [], busy: %{}, waiting: []}}
  end

  @impl true
  def handle_cast({:module_finished, module, failed?}, state) do
    {slots, busy} = Map.pop(state.busy, module, [])

    free =
      if failed? do
        Enum.each(slots, &discard/1)
        state.free
      else
        Enum.each(slots, &Slot.check_in/1)
        slots ++ state.free
      end

    {:noreply, serve_waiting(%{state | busy: busy, free: free})}
  end

  @impl true
  def handle_info({:waited, from}, state) do
    case Enum.split_with(state.waiting, &match?({_, _, _, ^from}, &1)) do
      {[{key, opts, module, ^from}], waiting} ->
        {slot, state} = start_isolated(%{state | waiting: waiting}, key, opts, module)
        GenServer.reply(from, slot)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # A slot that crashed: forget it.
  def handle_info({:EXIT, pid, _reason}, state) do
    gone? = &match?({^pid, _}, &1)
    shared = Map.reject(state.shared, fn {_key, slot} -> gone?.(slot) end)
    busy = Map.new(state.busy, fn {module, slots} -> {module, Enum.reject(slots, gone?)} end)
    {:noreply, serve_waiting(%{state | shared: shared, free: Enum.reject(state.free, gone?), busy: busy})}
  end

  # A free slot of the key, else a new one while there is room, made by stopping an idle slot
  # of another key if need be.
  defp checkout(state, key, opts, module) do
    case Enum.split_with(state.free, &match?({_, ^key}, &1)) do
      {[slot | same], others} ->
        {slot, busy(%{state | free: same ++ others}, module, slot)}

      {[], _} ->
        cond do
          length(state.free) + Enum.sum(Enum.map(Map.values(state.busy), &length/1)) < Options.max_isolated() ->
            start_isolated(state, key, opts, module)

          state.free != [] ->
            {idle, free} = List.pop_at(state.free, -1)
            discard(idle)
            start_isolated(%{state | free: free}, key, opts, module)

          true ->
            :full
        end
    end
  end

  # The waiting modules, first come first served, while slots are free or there is room.
  defp serve_waiting(%{waiting: [{key, opts, module, from} | rest]} = state) do
    case checkout(%{state | waiting: rest}, key, opts, module) do
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

  defp start_isolated(state, key, opts, module) do
    {slot, state} = start_slot(state, key, opts)
    {slot, busy(state, module, slot)}
  end

  defp busy(state, module, slot), do: %{state | busy: Map.update(state.busy, module, [slot], &[slot | &1])}

  # A driver's stop waits for it to exit (up to ~31 s): not in the pool's process.
  defp discard({pid, _key} = slot) do
    Process.unlink(pid)
    Task.start(fn -> Slot.stop(slot) end)
  end

  defp register_after_suite(%{after_suite?: true} = state), do: state

  defp register_after_suite(state) do
    if Code.ensure_loaded?(ExUnit) and is_list(Application.get_env(:ex_unit, :after_suite)),
      do: ExUnit.after_suite(&__MODULE__.after_suite/1)

    %{state | after_suite?: true}
  end
end
