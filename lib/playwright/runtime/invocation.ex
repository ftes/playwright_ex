defmodule Playwright.Runtime.Invocation do
  @moduledoc """
  Runtime support (not ported from upstream): the dispatch barrier from the invoked side.

  JS runs a listener (or an async function called without `await`) synchronously until its first
  `await`; only then does the caller (`emit`, the async call) continue. Here a listener runs in a
  process of its own while the connection waits (`Playwright.Runtime.Conn`), and an async
  function in a holder process while its caller waits (`Playwright.Runtime.Promise.async/2`).

  Process dictionary of the invoked process:

    * `:pw_inv` - `{waiting_pid, inv}`: whom to tell at the first blocking Playwright operation
      (`yield/0`), or when the function returns.
    * `:pw_barrier` - the connection's barrier token while the process runs on its behalf (the
      `inv` the connection waits for, also inherited by an async function it starts): an `emit`
      with this token nests, the connection runs its listeners before the emit returns.
    * `:pw_sync_wait` - set while the process waits as part of its synchronous section (a call
      into the connection, an async function it starts), which is no `await` (`awaiting/2`).

  A wait outside Playwright (a `receive`, `Process.sleep/1`, a call to another process) is an
  `await` of a non-Playwright promise in JS, so it yields too. It has no hook, so the waiting
  side checks (`awaiting/2`, every 20 ms) and counts a process blocked on such a wait for a whole
  interval as yielded. Busy work (JS: synchronous code) holds the barrier.
  """

  @check_interval 20

  @doc "How often a waiting side checks the process it waits for (`awaiting/2`), in ms."
  def check_interval, do: @check_interval

  @doc "The first blocking operation (an `await`): the waiting caller continues."
  def yield do
    Process.delete(:pw_barrier)

    case Process.delete(:pw_inv) do
      {pid, inv} -> send(pid, {:pw_yield, inv})
      nil -> :ok
    end

    :ok
  end

  @doc false
  def start(waiting, inv, barrier) do
    Process.put(:pw_inv, {waiting, inv})
    if barrier, do: Process.put(:pw_barrier, barrier)
    :ok
  end

  @doc """
  Runs `fun`, a wait that belongs to the caller's synchronous section (no `await`): `awaiting/2`
  does not count it as one.
  """
  def sync_wait(fun) do
    previous = Process.put(:pw_sync_wait, true)

    try do
      fun.()
    after
      if !previous, do: Process.delete(:pw_sync_wait)
    end
  end

  @doc """
  Whether `pid`, whose yield the caller waits for, awaits outside Playwright: it is blocked in a
  `receive` (not a `sync_wait/1`) and did no work since the previous check, which saw `last` (its
  reductions). Returns `true`, or the reductions to pass to the next check.
  """
  def awaiting(pid, last) do
    # The dictionary is read last: reading it costs the process a reduction.
    case Process.info(pid, [:status, :reductions]) do
      [status: :waiting, reductions: ^last] ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> if !List.keymember?(dictionary, :pw_sync_wait, 0), do: true
          nil -> nil
        end

      [status: :waiting, reductions: reductions] ->
        reductions

      _ ->
        nil
    end
  end
end
