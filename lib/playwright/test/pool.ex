defmodule Playwright.Test.Pool do
  @moduledoc false
  # The dispatcher of `Playwright.Test.BrowserPool` (whose moduledoc is the contract), after
  # upstream's `Dispatcher` (`packages/playwright/src/runner/dispatcher.ts`): its seats are the
  # `_workerSlots`, each a `Playwright.Test.Pool.Slot`, and a scope is a job. It runs the test
  # registry (`Playwright.Test.Results`) in the same process, so a test's end reaches it before
  # its scope's release (one mailbox).
  #
  # The state:
  #
  #   * `seats`: `%{pid => %{key, scope, used}}`, linked. `scope` `nil` is idle; `key` is the
  #     options of its last lease (`Slot.key/1`), `nil` after a failed scope's (its driver
  #     reset); `used` orders the idle ones, the longest idle first.
  #   * At most `workers` seats, but for those a scope that holds one takes over it (so no scope
  #     waits while it holds a seat others wait for); a release trims idle seats back to
  #     `workers`. A trimmed seat stays linked until it exited, so `after_suite/1`, which stops the
  #     linked ones, waits for it.
  #   * `scopes`: `%{scope => %{runner, failed?, down}}` of the scopes that hold seats: `runner` is
  #     a `setup_all` scope's ExUnit runner (whose tests' results are the scope's), else `nil`;
  #     `down` the monitor of a registered `setup_all`'s process until its `DOWN` (`module_down/3`).
  #   * `workers`: `{env, workers}`, config `workers` and the config it was read from.
  #   * `waiting`: callers whose scope held no seat while `workers` were held, monitored, first come
  #     first served (`serve_waiting/1`). A waiter that exits, or whose scope was released, is
  #     dropped.
  #   * `held`: the lines `print_after_suite/1` holds for `after_suite/1`, newest first, printed by
  #     `terminate/2` if the pool stops before; `nil` without the `ExUnit.after_suite/1` callback.
  #
  # Started unlinked on first use (`ensure_started/0`), never with the application (a release
  # has no ExUnit): its lifetime is the run. It registers the `ExUnit.after_suite/1` that stops
  # the drivers.
  use GenServer

  alias Playwright.Client.ClientStackTrace
  alias Playwright.Test.Options
  alias Playwright.Test.Pool.Slot
  alias Playwright.Test.Results
  alias Playwright.Test.SetupAllTimeout

  @doc "Starts the pool unless it runs, its table created. Two callers racing is fine."
  def ensure_started do
    if !Results.started?() do
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, _pid} -> :ok
        # The name is registered before `init/1` runs: a call waits for it.
        {:error, {:already_started, pid}} -> GenServer.call(pid, :started, :infinity)
      end
    end

    :ok
  end

  @doc """
  `%{playwright: _, browser: _}` of the seat of `opts` leased by `scope`: a registered test
  (`{:test, pid}`, its result is the lease's, unless its module holds a lease), or another
  process (`{:process, pid}`, a `setup_all`'s: the results of its runner's tests are). A seat
  of another key restarts its driver here, in the caller.
  """
  def browser(opts, {kind, pid}) do
    ensure_started()

    # Not in a `setup_all`'s time: the wait for a seat is the dispatcher's queue, which has no
    # timeout upstream, and the driver's start and launch are worker fixtures', with a timeout of
    # their own upstream, none here (a test's count, as ExUnit's timeout does).
    SetupAllTimeout.paused(fn ->
      case GenServer.call(__MODULE__, {:lease, Slot.key(opts), {kind, pid}, parent(pid)}, :infinity) do
        {seat, key} -> Slot.browser(seat, key, opts)
        :stopped -> raise "Playwright.Test's drivers were stopped (after the suite)"
        :released -> raise ArgumentError, "BrowserPool.browser/1 waited past the end of its test or module"
      end
    end)
  end

  @doc "Ends the leases of `scope`: its seats idle and warm unless it failed, else reset."
  def release(scope) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:release, scope}, :infinity)
    :ok
  end

  @doc """
  Fails the leases of the ended test `test_pid`, as its failure does: its own and its module's
  (its runner's), whose seats reset at their release.
  """
  def fail(test_pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:fail, test_pid}, :infinity)
    :ok
  end

  @doc """
  Fails the leases of the calling `setup_all`, whose callbacks raised (ExUnit catches it, so its
  process exits normally): its seats reset at its release, as upstream stops a worker whose job
  failed. Before its `DOWN`; never fails (a pool that is gone or stuck leaves the error as it is).
  """
  def setup_all_failed do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:setup_all_failed, self()}, :infinity)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "The ExUnit runner process that spawned `pid` (OTP 25+), `nil` if unknown."
  def parent(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> parent
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  # The `ExUnit.after_suite/1` callback: stops every driver, in parallel (`mix test` halts the VM
  # without stopping applications, and a driver that outlives the VM resets the terminal, #191).
  # The next call starts them anew.
  def after_suite(_stats) do
    if Process.whereis(__MODULE__) do
      print_held(GenServer.call(__MODULE__, :take_held, :infinity))

      __MODULE__
      |> GenServer.call(:take_all, :infinity)
      |> Task.async_stream(&Slot.stop/1, timeout: :infinity, max_concurrency: 64)
      |> Stream.run()
    end

    :ok
  end

  @doc """
  Prints `text` after ExUnit's output (`after_suite/1`), once its formatter printed the run's
  failures: a line written while a test ends comes before its failure, which ExUnit prints only
  after the test's `on_exit` callbacks. Without the callback (no ExUnit run), at once.
  """
  def print_after_suite(text) do
    if !(Process.whereis(__MODULE__) && GenServer.call(__MODULE__, {:hold, text}, :infinity)), do: IO.puts(text)
    :ok
  catch
    # The pool stopped meanwhile.
    :exit, _ -> IO.puts(text)
  end

  # The held lines, in the order they came, after a blank line.
  defp print_held([]), do: :ok
  defp print_held(held), do: IO.puts(["\n" | Enum.intersperse(Enum.reverse(held), "\n")])

  # ExUnit's modules, the runner here, and this layer's (`Playwright.Test`, `Playwright.Case`),
  # Playwright Test's fixtures and artifacts.
  defp runner_modules do
    own =
      for module <- Application.spec(:playwright, :modules) || [],
          name = Atom.to_string(module),
          name in ["Elixir.Playwright.Test", "Elixir.Playwright.Case"] or
            String.starts_with?(name, "Elixir.Playwright.Test."),
          do: module

    (Application.spec(:ex_unit, :modules) || []) ++ own
  end

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    results = Results.new()
    # The runner's frames stay out of the client's stacks, as upstream's process sets
    # `setBoxedStackPrefixes([packageRoot])` (`packages/playwright/src/common/process.ts`).
    ClientStackTrace.set_boxed_stack_prefixes(runner_modules())

    held =
      if Code.ensure_loaded?(ExUnit) and is_list(Application.get_env(:ex_unit, :after_suite)) do
        ExUnit.after_suite(&__MODULE__.after_suite/1)
        []
      end

    {:ok, %{seats: %{}, scopes: %{}, waiting: [], results: results, workers: nil, held: held}}
  end

  @impl true
  def handle_call({:lease, key, {kind, pid}, parent}, {caller, _} = from, state) do
    state = workers(state)
    scope = scope(state, pid, parent)
    runner = if scope == pid and kind == :process, do: parent
    # A module's registered `setup_all` (`use Playwright.Test`): its failure is the lease's.
    module? = scope == pid and kind == :process and match?({:module, _}, Results.scope(pid))
    request = %{key: key, scope: scope, runner: runner, module?: module?, from: from}

    case lease(state, request) do
      {:ok, seat, state} ->
        {:reply, {seat, key}, state}

      :full ->
        waiter = Map.put(request, :ref, Process.monitor(caller))
        {:noreply, %{state | waiting: state.waiting ++ [waiter]}}
    end
  end

  def handle_call({:release, scope}, _from, state), do: {:reply, :ok, release(workers(state), scope)}

  def handle_call({:fail, test_pid}, _from, state),
    do: {:reply, :ok, fail_scopes(state, test_pid, Results.runner(state.results, test_pid))}

  def handle_call({:setup_all_failed, scope}, _from, state), do: {:reply, :ok, fail_module(state, scope)}

  def handle_call(:started, _from, state), do: {:reply, :ok, state}

  def handle_call({:hold, text}, _from, %{held: held} = state) when is_list(held),
    do: {:reply, true, %{state | held: [text | held]}}

  def handle_call({:hold, _text}, _from, state), do: {:reply, false, state}
  def handle_call(:take_held, _from, state), do: {:reply, state.held || [], %{state | held: state.held && []}}

  def handle_call(:take_all, _from, state) do
    for waiter <- state.waiting, do: GenServer.reply(waiter.from, :stopped)
    {:links, links} = Process.info(self(), :links)
    slots = Enum.filter(links, &is_pid/1)
    Enum.each(slots, &Process.unlink/1)
    {:reply, slots, %{state | seats: %{}, scopes: %{}, waiting: []}}
  end

  def handle_call(request, from, state) do
    case Results.handle_call(request, from, state.results) do
      {:reply, reply, results} -> {:reply, reply, %{state | results: results}}
      {:noreply, results} -> {:noreply, %{state | results: results}}
    end
  end

  @impl true
  # A module's `setup_all` registered (`Results.register_module/2`): also after its first lease
  # (a case template's own `setup_all` with the `use` only in its `using`), which then starts
  # counting its failure. Its own cast: after that lease, before its `DOWN`.
  def handle_cast({:module_registered, pid}, state) do
    state = %{state | results: Results.handle_cast({:monitor, pid}, state.results)}

    case state.scopes[pid] do
      %{down: nil} -> {:noreply, put_in(state.scopes[pid].down, Process.monitor(pid))}
      _lease -> {:noreply, state}
    end
  end

  def handle_cast(request, state), do: {:noreply, %{state | results: Results.handle_cast(request, state.results)}}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    state = %{state | waiting: Enum.reject(state.waiting, &match?(%{from: {^pid, _}}, &1))}

    case state.scopes[pid] do
      %{down: ^ref} -> {:noreply, module_down(state, pid, reason)}
      _lease -> results_down(state, pid, reason)
    end
  end

  # A seat that crashed (its holder's next call gets another). A trimmed seat left `seats` already.
  def handle_info({:EXIT, pid, _reason}, state) do
    case Map.pop(state.seats, pid) do
      {nil, _seats} -> {:noreply, state}
      {_seat, seats} -> {:noreply, serve_waiting(workers(%{state | seats: seats}))}
    end
  end

  def handle_info(message, state), do: {:noreply, %{state | results: Results.handle_info(message, state.results)}}

  defp results_down(state, pid, reason) do
    case Results.down(state.results, pid, reason) do
      # A failed test fails its own scope, and its module's (its runner's).
      {{runner, :failed}, results} ->
        {:noreply, fail_scopes(%{state | results: results}, pid, runner)}

      # The test's finish was killed before its release: its seats reset, as a failed test's
      # (its contexts may be left open). After a release, nothing to do.
      {{:finished, tests}, results} ->
        state =
          Enum.reduce(tests, %{state | results: results}, fn {test_pid, runner}, state ->
            fail_scopes(state, test_pid, runner)
          end)

        {:noreply, Enum.reduce(tests, workers(state), fn {test_pid, _runner}, state -> release(state, test_pid) end)}

      {_ended, results} ->
        {:noreply, %{state | results: results}}
    end
  end

  # A module's `setup_all` scope (monitored at its first lease) exited: past its timeout, killed,
  # taken down by a linked process (`{:shutdown, _}` too), fails its leases, as upstream stops a
  # worker whose job failed. Only `:normal` is a clean end (ExUnit's `exit_setup_all`). Its
  # callbacks raising (ExUnit catches it, the process then exits `:normal`) came first
  # (`setup_all_failed/0`).
  defp module_down(state, scope, reason) do
    state = put_in(state.scopes[scope].down, nil)
    if reason == :normal, do: state, else: fail_module(state, scope)
  end

  defp fail_module(state, scope) do
    if Map.has_key?(state.scopes, scope), do: put_in(state.scopes[scope].failed?, true), else: state
  end

  # The `DOWN` of a module scope that a release (its `on_exit`, in another process) may overtake:
  # awaited once the scope exited.
  defp await_down(state, scope) do
    case state.scopes[scope] do
      %{down: ref} when is_reference(ref) ->
        if Process.alive?(scope) do
          Process.demonitor(ref, [:flush])
          put_in(state.scopes[scope].down, nil)
        else
          receive do
            {:DOWN, ^ref, :process, _pid, reason} -> module_down(state, scope, reason)
          end
        end

      _lease ->
        state
    end
  end

  # Stopped or crashed before the suite's end: the held lines print now, not never.
  @impl true
  def terminate(_reason, state), do: print_held(state.held || [])

  # Ends the leases of `scope`: its waiters get `:released`, its seats go back idle (reset when it
  # failed).
  defp release(state, scope) do
    state = await_down(state, scope)
    {waiters, waiting} = Enum.split_with(state.waiting, &(&1.scope == scope))

    for waiter <- waiters do
      Process.demonitor(waiter.ref, [:flush])
      GenServer.reply(waiter.from, :released)
    end

    case Map.pop(state.scopes, scope) do
      {nil, _scopes} ->
        %{state | waiting: waiting}

      {lease, scopes} ->
        seats = Map.new(state.seats, &release_seat(&1, scope, lease.failed?))
        %{state | waiting: waiting, scopes: scopes, seats: seats} |> trim() |> serve_waiting()
    end
  end

  defp release_seat({pid, %{scope: scope} = seat}, scope, failed?) do
    # Upstream's `void worker.stop(true)`: the next holder's `Slot.browser/3` awaits it.
    if failed?, do: Slot.reset(pid)
    {pid, %{seat | key: if(!failed?, do: seat.key), scope: nil, used: used()}}
  end

  defp release_seat(other, _scope, _failed?), do: other

  defp fail_scopes(state, pid, runner), do: %{state | scopes: Map.new(state.scopes, &fail_scope(&1, pid, runner))}

  defp fail_scope({scope, lease}, pid, runner) do
    if scope == pid or (lease.runner != nil and lease.runner == runner),
      do: {scope, %{lease | failed?: true}},
      else: {scope, lease}
  end

  # A test's calls (registered or not) go to its module's lease, if the module holds one: the
  # `setup_all` scope its runner spawned.
  defp scope(_state, pid, nil), do: pid

  defp scope(state, pid, parent) do
    Enum.find_value(state.scopes, pid, fn {scope, lease} -> if lease.runner == parent, do: scope end)
  end

  # The scope's seat of the key (a repeated call), else `_scheduleJob`'s match: an idle seat of
  # the key, else a new seat under `workers`, else an idle seat of another key (the longest
  # idle), whose driver restarts for the key. A scope that holds a seat takes one over `workers`
  # rather than wait.
  defp lease(state, request) do
    held = for {pid, %{scope: scope} = seat} <- state.seats, scope == request.scope, do: {pid, seat}

    case Enum.find(held, &match?({_pid, %{key: key}} when key == request.key, &1)) do
      {pid, _seat} -> {:ok, pid, state}
      nil -> claim(state, request, held != [])
    end
  end

  defp claim(state, request, over?) do
    {_env, workers} = state.workers
    idle = for {_pid, %{scope: nil}} = seat <- state.seats, do: seat

    cond do
      not over? and map_size(state.seats) - length(idle) >= workers ->
        :full

      seat = Enum.find(idle, &(elem(&1, 1).key == request.key)) ->
        {:ok, elem(seat, 0), take(state, seat, request)}

      # Under `workers`, or over it for a scope that holds one, when no seat is idle.
      idle == [] or map_size(state.seats) < workers ->
        {:ok, pid} = Slot.start_link()
        {:ok, pid, take(state, {pid, %{key: nil, scope: nil, used: nil}}, request)}

      true ->
        seat = Enum.min_by(idle, &restart_order/1)
        {:ok, elem(seat, 0), take(state, seat, request)}
    end
  end

  defp take(state, {pid, seat}, request) do
    seats = Map.put(state.seats, pid, %{seat | key: request.key, scope: request.scope})

    scopes =
      Map.put_new_lazy(state.scopes, request.scope, fn ->
        # A module's `setup_all` scope: monitored, for its failure (`module_down/3`).
        down = if request.module?, do: Process.monitor(request.scope)
        %{runner: request.runner, failed?: false, down: down}
      end)

    %{state | seats: seats, scopes: scopes}
  end

  # `workers` of the config, validated when the config changed (a test may put it): `{env, workers}`.
  defp workers(state) do
    env = Application.get_env(:playwright, :test)

    case state.workers do
      {^env, _workers} -> state
      _ -> %{state | workers: {env, Options.workers()}}
    end
  end

  # Reset seats first (their drivers stopped already), then the longest idle.
  defp restart_order({_pid, seat}), do: {seat.key != nil, seat.used}

  defp used, do: System.unique_integer([:monotonic])

  # Idle seats over `workers` (taken over it by a scope, or `workers` lowered) are stopped.
  defp trim(state) do
    idle = for {_pid, %{scope: nil}} = seat <- state.seats, do: seat
    {_env, workers} = state.workers
    excess = min(map_size(state.seats) - workers, length(idle))

    if excess > 0 do
      trimmed = idle |> Enum.sort_by(&restart_order/1) |> Enum.take(excess) |> Enum.map(&elem(&1, 0))
      # A driver's stop waits for it to exit: not in the pool's process.
      Enum.each(trimmed, &Task.start(Slot, :stop, [&1]))
      %{state | seats: Map.drop(state.seats, trimmed)}
    else
      state
    end
  end

  # The waiting callers, first come first served, as `_findFirstJobToRun` picks the first job that
  # can run: every one `lease/2` serves, the others wait on in order. One whose scope got a seat
  # here (its scope's earlier caller) is served, past those that wait. A scope with no seat is
  # `:full` while `workers` are held, of any key, and serving only takes seats: once one waits,
  # the later ones do, so their order holds.
  defp serve_waiting(state) do
    {waiting, state} =
      Enum.flat_map_reduce(state.waiting, state, fn waiter, state ->
        case lease(state, waiter) do
          {:ok, seat, state} ->
            Process.demonitor(waiter.ref, [:flush])
            GenServer.reply(waiter.from, {seat, waiter.key})
            {[], state}

          :full ->
            {[waiter], state}
        end
      end)

    %{state | waiting: waiting}
  end
end
