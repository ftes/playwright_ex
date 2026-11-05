defmodule PlaywrightEx.Runtime.Invocation do
  @moduledoc """
  Runtime support (not ported from upstream): the dispatch barrier from the invoked side.

  JS runs a listener (or an async function called without `await`) synchronously until its first
  `await`; only then does the caller (`emit`, the async call) continue. Here a listener runs in a
  process of its own while the connection waits (`PlaywrightEx.Runtime.Conn`), and an async
  function in a holder process while its caller waits (`PlaywrightEx.Runtime.Promise.async/2`).

  Process dictionary of the invoked process:

    * `:pw_inv` - `{waiting_pid, inv}`: whom to tell at the first blocking Playwright operation
      (`yield/0`), or when the function returns.
    * `:pw_barrier` - the connection's barrier token while the process runs on its behalf (the
      `inv` the connection waits for, also inherited by an async function it starts): an `emit`
      with this token nests, the connection runs its listeners before the emit returns.
  """

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
end
