defmodule Playwright.Runtime.Invocation do
  @moduledoc """
  Runtime support (not ported from upstream): the dispatch barrier from the invoked side.

  JS runs a listener (or an async function called without `await`) synchronously until its first
  `await`; only then does the caller (`emit`, the async call) continue. Here a listener runs in a
  process of its own while the connection waits (`Playwright.Runtime.Conn`), and an async
  function in a process of its own while its caller waits (`Playwright.Runtime.Promise.async/2`):
  a synchronous section.

  A section ends when its process yields (`yield/0`: a Playwright await, or
  `Playwright.Promise.yield/0`), returns, dies, or is released by its waiter (`judge/3`). Its
  flag (`new_flag/0`, an `:atomics` cell) goes from 1 to 0 once (`end_section/1`): whoever flips
  it ends the section, so a released process never sends a yield and a waiter never waits for
  one that won't come.

  Process dictionary of the invoked process:

    * `:pw_inv` - `{waiting_pid, inv, flag}`: whom to tell at the first yield.
    * `:pw_barrier` - `{inv, flag}`: the connection's barrier token while the process runs on its
      behalf (the `inv` the connection waits for, also inherited by an async function it starts,
      with that function's own flag): a `Conn.run/2` with a live token nests, the connection runs
      its listeners before the call returns.
    * `:pw_event` - `{conn, emitter guid, type}` of the listener the section runs for (inherited
      by its async functions), for the release warning.
  """
  require Logger

  # The fallback: a section process that waits at this many consecutive samples, this many ms
  # apart, doing fewer reductions than this between them, is released as if it had yielded.
  @samples 3
  @interval 10
  @reductions 2_000

  @doc "The sampling interval of `judge/3`, in ms."
  def interval, do: @interval

  @doc """
  A section's flag: cell 1 is 1 while the section is live; cell 2 is 1 while its process waits on
  the runtime itself (a call its connection serves, or the start of its own async function, whose
  waiter judges that one instead), so it is not judged meanwhile.
  """
  def new_flag do
    flag = :atomics.new(2, [])
    :atomics.put(flag, 1, 1)
    flag
  end

  @doc "Ends the section of `flag`: true for the one caller that ends it (its process or its waiter)."
  def end_section(flag), do: :atomics.compare_exchange(flag, 1, 1, 0) == :ok

  @doc "Whether the section of `flag` is live."
  def live?(flag), do: :atomics.get(flag, 1) == 1

  @doc "The first blocking operation (an `await`): the waiting caller continues."
  def yield do
    Process.delete(:pw_barrier)

    case Process.delete(:pw_inv) do
      # Released already (lost the flag): nothing to tell.
      {pid, inv, flag} -> if end_section(flag), do: send(pid, {:pw_yield, inv})
      nil -> :ok
    end

    :ok
  end

  @doc false
  def start(waiting, inv, flag, barrier) do
    Process.put(:pw_inv, {waiting, inv, flag})
    if barrier, do: Process.put(:pw_barrier, {barrier, flag})
    :ok
  end

  @doc false
  # The calling process's live section flag, if it runs one. A released one's entries go: what it
  # starts or calls from now on is outside the section.
  def own_flag do
    case Process.get(:pw_inv) do
      {_pid, _inv, flag} ->
        if live?(flag) do
          flag
        else
          Process.delete(:pw_inv)
          Process.delete(:pw_barrier)
          nil
        end

      nil ->
        nil
    end
  end

  @doc false
  # The calling process's section flag (live or not), if it ran one.
  def section_flag do
    case Process.get(:pw_inv) do
      {_pid, _inv, flag} -> flag
      nil -> nil
    end
  end

  @doc false
  # Runs `fun` (a wait on the runtime itself) with the calling process's section marked as not
  # judged (cell 2 of its flag).
  def runtime_wait(nil, fun), do: fun.()

  def runtime_wait(flag, fun) do
    :atomics.put(flag, 2, 1)

    try do
      fun.()
    after
      :atomics.put(flag, 2, 0)
    end
  end

  @doc """
  One sample of the section process `pid` (the waiter's, every `interval/0` ms): `{:release,
  quiet}` once it waited at `@samples` consecutive samples doing little work (a wait outside
  Playwright, treated as an await), else `{:hold, quiet}` (`quiet`: `nil` at first). CPU work
  never counts (the process is running or runnable), nor does a wait on the runtime (`new_flag/0`).
  """
  def judge(pid, flag, quiet) do
    # Cell 2 read before and after: a runtime wait that starts or ends meanwhile is seen.
    with 0 <- :atomics.get(flag, 2),
         [status: :waiting, reductions: reductions] <- Process.info(pid, [:status, :reductions]),
         0 <- :atomics.get(flag, 2) do
      count =
        case quiet do
          {count, last} when reductions - last < @reductions -> count + 1
          _ -> 1
        end

      {if(count >= @samples, do: :release, else: :hold), {count, reductions}}
    else
      _ -> {:hold, nil}
    end
  end

  @doc false
  # One sample by the waiter of the section of `pid` (the connection, or the caller of its async
  # function): `{:hold, quiet}`; `:released` (judged waiting, and its flag flipped here: it goes
  # on as after an await); or `:yielding` (it flipped the flag first: its yield is on its way).
  def try_release(pid, flag, quiet, event, callers) do
    case judge(pid, flag, quiet) do
      {:hold, quiet} ->
        {:hold, quiet}

      {:release, _quiet} ->
        if end_section(flag) do
          released(pid, event, callers)
          :released
        else
          :yielding
        end
    end
  end

  # The waiter released the section of `pid` (`judge/3`, then `end_section/1`): one warning per
  # listener event (`event`, `{conn, guid, type}`) or per waiting process, logged from a process
  # of its own (a `Logger` in sync mode must not block the waiter, the connection maybe). A
  # finished test kills it (`Callers.detached/2`, `callers` its `$callers`).
  defp released(pid, event, callers) do
    Playwright.Runtime.Callers.detached(pid, callers)
    key = event || {:async, self()}

    if first_warning?(key) do
      stacktrace =
        case Process.info(pid, :current_stacktrace) do
          {:current_stacktrace, stacktrace} -> stacktrace
          nil -> []
        end

      what =
        case event do
          {_conn, _guid, type} -> "A listener for #{inspect(type)}"
          nil -> "An async function"
        end

      spawn(fn ->
        Logger.warning(
          what <>
            " waited outside Playwright for #{@samples * @interval} ms in its synchronous section, " <>
            "so it was treated as awaiting and dispatch went on. Call Playwright.Promise.yield/0 " <>
            "before such a wait (JS: an await) to skip the delay.\n" <>
            Exception.format_stacktrace(stacktrace)
        )
      end)
    end

    :ok
  end

  defp first_warning?(key) do
    :ets.insert_new(Playwright.Runtime.ProcessOwner.warned(), {key})
  rescue
    ArgumentError -> true
  end
end
