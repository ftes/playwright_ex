defmodule Playwright.Runtime.Invocation do
  @moduledoc """
  Runtime support (not ported from upstream): the dispatch barrier from the invoked side.

  JS runs a listener (or an async function called without `await`) synchronously until its first
  `await`; only then does the caller (`emit`, the async call) continue. Here a listener runs in a
  process of its own while the connection waits (`Playwright.Runtime.Conn`), and an async
  function in a process of its own while its caller waits (`Playwright.Runtime.Promise.async/2`):
  a synchronous section.

  A section ends when its process yields (`yield/0`: a Playwright await, or
  `Playwright.Promise.yield/0`), returns, dies, or is released by its waiter once it has been
  open for `release_after/0` ms (`try_release/4`). Its flag (`new_flag/0`, an `:atomics` cell)
  goes from 1 to 0 once (`end_section/1`): whoever flips it ends the section, so a released
  process never sends a yield and a waiter never waits for one that won't come.

  Process dictionary of the invoked process:

    * `:pw_inv` - `{waiting_pid, inv, flag}`: whom to tell at the first yield.
    * `:pw_barrier` - `{inv, flag}`: the connection's barrier token while the process runs on its
      behalf (the `inv` the connection waits for, also inherited by an async function it starts,
      with that function's own flag): a `Conn.run/2` with a live token nests, the connection runs
      its listeners before the call returns.
    * `:pw_event` - `{type, key}` of the listener the section runs for (`event/3`, inherited by
      its async functions), for the release warning.
  """
  require Logger

  # The fallback: a section still open this many ms after it started is released as if it had
  # yielded (a wait outside Playwright, treated as an await).
  @release_after 100

  @doc "How long a section may stay open before its waiter releases it, in ms."
  def release_after, do: @release_after

  @doc "A section's flag: 1 while the section is live."
  def new_flag do
    flag = :atomics.new(1, [])
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
    flag = section_flag()

    if flag && !live?(flag) do
      Process.delete(:pw_inv)
      Process.delete(:pw_barrier)
      nil
    else
      flag
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
  # The key of the release warning of a listener (`fun`) for `type` on `emitter`: one per
  # listener function, emitter type and event, so a new page's listener doesn't warn again.
  def event(emitter, type, fun), do: {type, {Map.get(emitter, :__struct__), type, fun_id(fun)}}

  @doc false
  # The same for an async function (`fun`) called outside a listener.
  def async_event(fun), do: {nil, {:async, fun_id(fun)}}

  defp fun_id(fun) do
    info = Function.info(fun)
    {info[:module], info[:name], info[:arity]}
  end

  @doc false
  # The waiter's `@release_after` timer fired for the section of `pid`: `:released` (its flag
  # flipped here: it goes on as after an await) or `:yielding` (it flipped the flag first: its
  # yield is on its way). `event`: `{type, key}` (`event/3`, `async_event/1`).
  def try_release(pid, flag, event) do
    if end_section(flag) do
      released(pid, event)
      :released
    else
      :yielding
    end
  end

  # One warning per key and code location (the first frame outside Playwright, Elixir and OTP),
  # logged from a process of its own (a `Logger` in sync mode must not block the waiter, the
  # connection maybe). None without such a frame (the library's own wait, such as loading a
  # module), nor for a process that waits for its async function (a route handler run by the
  # client's listener): that one is released next, with its stacktrace.
  defp released(pid, {type, key}) do
    stacktrace =
      case Process.info(pid, :current_stacktrace) do
        {:current_stacktrace, stacktrace} -> stacktrace
        nil -> []
      end

    location = location(stacktrace)

    if location != nil and not match?([{Playwright.Runtime.Promise, :handoff, _, _} | _], stacktrace) and
         first_warning?({key, location}) do
      what = if type, do: "A listener for #{inspect(type)}", else: "An async function"

      spawn(fn ->
        Logger.warning(
          what <>
            " did not reach a Playwright await within #{@release_after} ms, so it was treated as " <>
            "awaiting and dispatch went on: its remaining synchronous code may run after later " <>
            "events. Call Playwright.Promise.yield/0 before waiting outside Playwright (JS: an await).\n" <>
            Exception.format_stacktrace(stacktrace)
        )
      end)
    end

    :ok
  end

  defp location(stacktrace) do
    Enum.find_value(stacktrace, fn {module, name, arity, _location} ->
      case :application.get_application(module) do
        {:ok, app} when app in [:playwright, :elixir, :stdlib, :kernel] -> nil
        _ -> {module, name, arity}
      end
    end)
  end

  defp first_warning?(key) do
    :ets.insert_new(Playwright.Runtime.ProcessOwner.warned(), {key})
  rescue
    ArgumentError -> true
  end
end
