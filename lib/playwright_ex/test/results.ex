defmodule PlaywrightEx.Test.Results do
  @moduledoc false
  # The registered tests (`use PlaywrightEx.Test`): their results, recorders and rows of
  # `PlaywrightEx.Test`'s table. In the pool's process (`PlaywrightEx.Test.Pool`, which hands it
  # these requests), so a test's end reaches the pool before its scope's release: one mailbox.
  #
  # A test's result (`watch/2`, `result/2`): passed when the `test` macro marked the end of its
  # body (`{:passed, pid}`) and its process then exited `:shutdown`, as ExUnit's runner ends it.
  # The messages a test process sends arrive before its `DOWN`.

  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.TestInfo

  # ExUnit kills a test's process past its timeout; so can a test. No stacktrace either way.
  @killed "The test process was killed (ExUnit's timeout, or an explicit kill)."
  # A marked test that raised nothing in its body and did not pass.
  @outside "The test failed outside its body (setup, context pattern or a linked process); see ExUnit's output."

  @doc "`PlaywrightEx.Test`'s table (public, owned by the pool): test, recorder, context, driver and test info rows."
  def table, do: __MODULE__

  @doc "Whether the pool runs (its table exists)."
  def started?, do: :ets.whereis(table()) != :undefined

  @doc "The failure of a test whose process was killed."
  def killed, do: @killed

  @doc "The failure of a marked test that failed outside its body."
  def outside, do: @outside

  @doc """
  Monitors the test process `pid`, once. `marked`: `false`, or the failure of a test whose `test`
  macro marks the end of the body and that raised nothing in it.
  """
  def watch(pid, marked) do
    Pool.ensure_started()
    GenServer.call(Pool, {:watch, pid, Pool.parent(pid), marked}, :infinity)
  end

  @doc "Sends `message` (`{:passed, pid}`, `{:failed, pid, failure}`) if the pool runs."
  def notify(message) do
    if pid = Process.whereis(Pool), do: send(pid, message)
    :ok
  end

  @doc """
  The result of the test `pid` once its process ended, waiting up to `timeout` ms:
  `{:passed, []}`, `{:failed, failures}` (`{kind, reason, stacktrace}` as ExUnit's, or a
  message), or `{nil, []}` when unknown (not watched, not marked, or past the wait).
  """
  def result(pid, timeout) do
    if Process.whereis(Pool), do: GenServer.call(Pool, {:result, pid}, timeout), else: {nil, []}
  catch
    :exit, _ -> {nil, []}
  end

  @doc "How long the ended test `pid` ran, in ms, from its `watch/2` to its exit; `nil` if unknown."
  def duration(pid) do
    if Process.whereis(Pool), do: GenServer.call(Pool, {:duration, pid}, :infinity)
  end

  @doc """
  Notes the calling process, ExUnit's `on_exit` runner, as the one that finishes the test
  `test_pid` (`PlaywrightEx.Test.__finish__/2`): when it exits, the pool drops the test's
  `keep_info/2` row and result, and releases the test's leases if the finish did not (ExUnit
  killed it past the timeout), as a failed scope's.
  """
  def finishing(test_pid) do
    if Process.whereis(Pool), do: GenServer.cast(Pool, {:finishing, test_pid, self()})
    :ok
  end

  @doc """
  Keeps `info` (`PlaywrightEx.Test.info/1`'s, of the ended test `test_pid`) until the process
  that finishes it (`finishing/1`) exits: for the test's `on_exit` callbacks that run after its
  registration's.
  """
  def keep_info(test_pid, info) do
    :ets.insert(table(), {{:info, test_pid}, info})
    :ok
  end

  @doc "Whether one of `pids` is a test at its registration's `on_exit` (`keep_info/2`), which closes its contexts."
  def finished?(pids), do: started?() and Enum.any?(pids, &:ets.member(table(), {:info, &1}))

  @doc "Forgets the result of the test `pid`."
  def forget(pid) do
    if Process.whereis(Pool), do: GenServer.cast(Pool, {:forget, pid})
    :ok
  end

  @doc """
  The recorder of the registered test `test_pid` (`PlaywrightEx.Test.Recorder`), started on the
  first call; `nil` once the test's `take/1` ran.
  """
  def recorder(test_pid) do
    case :ets.lookup(table(), {:recorder, test_pid}) do
      [{_key, pid}] -> pid
      [] -> GenServer.call(Pool, {:recorder, test_pid}, :infinity)
    end
  end

  @doc "Unregisters the test `test_pid`: its registration row and its recorder (or `nil`)."
  def take(test_pid), do: GenServer.call(Pool, {:take, test_pid}, :infinity)

  @doc "Notes `pid` as a process that created a context before it was registered, until it exits."
  def note_unregistered(pid) do
    if :ets.insert_new(table(), {{:unregistered, pid}, true}), do: GenServer.cast(Pool, {:monitor, pid})
    :ok
  end

  # The pool's process from here on.

  @doc """
  The registry's state, its table created: `tests`, the watched test processes alive; `results`,
  those ended (`{verdict, failures, duration, runner}`), until forgotten; `kept`, the tests by the
  process that finishes them (`finishing/1`).
  """
  def new do
    :ets.new(table(), [:named_table, :public, :set])
    %{tests: %{}, results: %{}, kept: %{}}
  end

  @doc "A request of this module's functions: `{:reply, reply, state}` or `{:noreply, state}`."
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
      %{results: %{^pid => {verdict, failures, _duration, _runner}}} -> {:reply, {verdict, failures}, state}
      %{tests: %{^pid => _}} -> {:noreply, update_in(state.tests[pid].awaiting, &[from | &1])}
      _ -> {:reply, {nil, []}, state}
    end
  end

  def handle_call({:duration, pid}, _from, state) do
    case state.results do
      %{^pid => {_verdict, _failures, duration, _runner}} -> {:reply, duration, state}
      _ -> {:reply, nil, state}
    end
  end

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

  @doc "The ExUnit runner of the ended test `pid` (`watch/2`'s), `nil` if unknown."
  def runner(state, pid) do
    case state.results do
      %{^pid => {_verdict, _failures, _duration, runner}} -> runner
      _ -> nil
    end
  end

  @doc "A cast of this module's functions: the state."
  def handle_cast({:forget, pid}, state), do: %{state | results: Map.delete(state.results, pid)}

  def handle_cast({:finishing, test_pid, keeper}, state) do
    Process.monitor(keeper)
    %{state | kept: Map.update(state.kept, keeper, [test_pid], &[test_pid | &1])}
  end

  def handle_cast({:monitor, pid}, state) do
    Process.monitor(pid)
    state
  end

  @doc "`notify/1`'s messages (others are ignored): the state."
  def handle_info({:passed, pid}, state) do
    case state.tests do
      %{^pid => _} -> put_in(state.tests[pid].passed?, true)
      _ -> state
    end
  end

  def handle_info({:failed, pid, failure}, state) do
    case state.tests do
      %{^pid => _} -> update_in(state.tests[pid].failures, &(&1 ++ [failure]))
      _ -> state
    end
  end

  def handle_info(_message, state), do: state

  @doc """
  A monitored process exited (a test, a finisher or an unregistered creator of contexts):
  `{ended, state}`, `ended` the `{runner, verdict}` of a watched test, `{:finished, [{test_pid,
  runner}]}` of a finisher (`finishing/1`), else `nil`.
  """
  def down(state, pid, reason) do
    :ets.delete(table(), {:unregistered, pid})

    case pop_in(state.kept[pid]) do
      {nil, state} ->
        case Map.pop(state.tests, pid) do
          {nil, _tests} -> {nil, state}
          {test, tests} -> test_ended(%{state | tests: tests}, pid, test, reason)
        end

      {kept, state} ->
        for test_pid <- kept, do: :ets.delete(table(), {:info, test_pid})
        tests = for test_pid <- kept, do: {test_pid, runner(state, test_pid)}
        {{:finished, tests}, %{state | results: Map.drop(state.results, kept)}}
    end
  end

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
    duration = System.monotonic_time(:millisecond) - test.started

    {{test.runner, verdict},
     %{state | results: Map.put(state.results, pid, {verdict, failures, duration, test.runner})}}
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
end
