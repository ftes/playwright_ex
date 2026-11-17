defmodule Playwright.Runtime.Invocation do
  @moduledoc """
  Runtime support (not ported from upstream): the dispatch barrier from the invoked side.

  JS runs a listener (or an async function called without `await`) synchronously until its first
  `await`; only then does the caller (`emit`, the async call) continue. Here a listener runs in a
  process of its own while the connection waits (`Playwright.Runtime.Conn`), and an async
  function in a process of its own while its caller waits (`Playwright.Runtime.Promise.async/2`):
  a synchronous section.

  A section ends when its process yields (`yield/0`: a Playwright await, or
  `Playwright.Promise.yield/0`), returns or dies, or when its waiter releases it, `release_after/0`
  ms after it started (`try_release/2`). Its flag (`new_flag/0`, an `:atomics` cell) is flipped
  once (`end_section/1`): whoever flips it ends the section, so a released process never sends a
  yield and a waiter never waits for one that won't come.

  Process dictionary of the invoked process:

    * `:pw_inv` - `{waiting_pid, inv, flag}`: whom to tell at the first yield.
    * `:pw_barrier` - `{inv, flag}`: the connection's barrier token while the process runs on its
      behalf (the `inv` the connection waits for, also inherited by an async function it starts,
      with that function's own flag): a `Conn.run/2` with a live token nests, the connection runs
      its listeners before the call returns.
  """
  require Logger

  @release_after 100

  @doc "How long a section may stay open before its waiter releases it, in ms."
  def release_after, do: @release_after

  @doc "A section's flag: 0 while the section is live."
  def new_flag, do: :atomics.new(1, [])

  @doc "Ends the section of `flag`: true for the one caller that ends it (its process or its waiter)."
  def end_section(flag), do: :atomics.compare_exchange(flag, 1, 0, 1) == :ok

  @doc "Whether the section of `flag` is live."
  def live?(flag), do: :atomics.get(flag, 1) == 0

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
  # The barrier `inv` of the calling process's live section, if any (inherited by an async
  # function it starts). A released section's entries go: what it starts or calls from now on is
  # outside the section.
  def barrier do
    case Process.get(:pw_barrier) do
      {inv, flag} ->
        if live?(flag) do
          inv
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
  # The waiter's timer fired for the section of `pid`: `:released` (its flag flipped here: it goes
  # on as after an await, with a warning) or `:yielding` (it flipped the flag first: its yield is
  # on its way).
  def try_release(pid, flag) do
    if end_section(flag) do
      warn(pid)
      :released
    else
      :yielding
    end
  end

  # Once per code location (the first frame outside Playwright, Elixir and OTP; none without one:
  # the library's own wait), logged from a process of its own (a `Logger` in sync mode must not
  # block the waiter, the connection maybe).
  defp warn(pid) do
    {:current_stacktrace, stacktrace} = Process.info(pid, :current_stacktrace) || {:current_stacktrace, []}
    location = Enum.find_value(stacktrace, &user_location/1)

    if location && :ets.insert_new(Playwright.Runtime.ProcessOwner.warned(), {location}) do
      spawn(fn ->
        Logger.warning(
          "A listener (or async function) did not reach a Playwright await within #{@release_after} ms, " <>
            "so it was released and dispatch went on: its remaining synchronous code may run after " <>
            "later events. Call Playwright.Promise.yield/0 before waiting outside Playwright " <>
            "(JS: an await).\n" <> Exception.format_stacktrace(stacktrace)
        )
      end)
    end

    :ok
  rescue
    # The table is gone (the application stops).
    ArgumentError -> :ok
  end

  defp user_location({module, name, arity, _location}) do
    case :application.get_application(module) do
      {:ok, app} when app in [:playwright, :elixir, :logger, :stdlib, :kernel] -> nil
      _ -> if :code.which(module) != :preloaded, do: {module, name, arity}
    end
  end
end
