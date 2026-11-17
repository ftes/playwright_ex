defmodule Playwright.Test.SetupAllTimeout do
  @moduledoc false
  # The timeout of a module's `setup_all`, as upstream's `beforeAll` hook gets the test timeout
  # (`project.timeout`) in a time slot of its own (`packages/playwright/src/worker/workerMain.ts`,
  # `_runAllHooksForSuite`) and fails with `"beforeAll" hook timeout of 30000ms exceeded.`
  # (`timeoutManager.ts`, `_createTimeoutError`). ExUnit has none: it waits for the `setup_all`
  # process without a timeout, and fails the module when that process exits.
  #
  # So `use Playwright.Test` wraps the module's compiled `setup_all` callbacks
  # (`__ex_unit__(:setup_all, context)`, see `Playwright.Test.__before_compile__/1`) in `run/2`: a
  # watchdog exits the `setup_all` process if the callbacks still run past ExUnit's timeout of
  # the module (`Options.ex_unit_timeout/1`). ExUnit then fails the module with the exit reason:
  # upstream's message with `beforeAll` renamed to `setup_all`, and the stack the process was at.
  # Elixir only: one slot for all of the module's `setup_all` callbacks, where upstream gives
  # each hook its own. A process that traps exits is killed 1 s later (`:killed`, without the
  # message). A pooled browser (`Pool.browser/2`: the wait for a seat, a driver start and
  # launch) is not counted (`paused/1`), as upstream's dispatcher queue has no timeout and its
  # worker fixtures have a timeout of their own (none here). `paused/1` looks in the calling
  # process only: a `setup_all` scope's `BrowserPool.browser/1` runs in the `setup_all` process
  # itself.
  #
  # A `setup_all` whose callbacks raise tells the pool (`Pool.setup_all_failed/0`): ExUnit catches
  # the error, so its process exits normally, where the pool sees any other failure (past its
  # timeout too) in the process's `DOWN`. Its seats reset at its release, as upstream stops a
  # worker whose job failed (`dispatcher.ts`, `worker.stop(true /* didFail */)`).

  alias Playwright.Test.Options
  alias Playwright.Test.Pool

  @key {__MODULE__, :watchdog}

  @doc """
  Runs the module's `setup_all` callbacks `fun` within the module's timeout (`context` is theirs).
  Once: a case template's callbacks, run from the module's, are part of its time.
  """
  def run(context, fun) do
    case Process.get(@key) || Options.ex_unit_timeout(context) do
      :infinity ->
        raising(fun)

      timeout when is_integer(timeout) ->
        owner = self()
        # The handshake at the deadline (0 running, 1 done, 2 expired): who sets it first decides.
        state = :atomics.new(1, [])
        watchdog = spawn(fn -> watch(owner, state, timeout) end)
        Process.put(@key, watchdog)

        try do
          raising(fun)
        after
          Process.delete(@key)

          case :atomics.compare_exchange(state, 1, 0, 1) do
            :ok -> send(watchdog, :done)
            # Expired: the watchdog's exit is on its way, so the callbacks' result never reaches ExUnit.
            _expired -> Process.sleep(:infinity)
          end
        end

      # Inside a running one.
      _watchdog ->
        fun.()
    end
  end

  # Callbacks that raise, throw or exit (a cast: a twice nested one casts twice).
  defp raising(fun) do
    fun.()
  catch
    kind, reason ->
      Pool.setup_all_failed()
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc "Runs `fun` with the calling `setup_all`'s clock stopped (a pooled browser)."
  def paused(fun) do
    case Process.get(@key) do
      nil ->
        fun.()

      watchdog ->
        send(watchdog, :pause)

        try do
          fun.()
        after
          send(watchdog, :resume)
        end
    end
  end

  defp watch(owner, state, timeout) do
    ref = Process.monitor(owner)

    %{owner: owner, ref: ref, state: state, timeout: timeout, left: timeout, paused: 0, timer: nil}
    |> start_timer()
    |> loop()
  end

  # `timer` is the running timer (`nil` while paused), `left` its time when paused, `paused` the
  # depth of nested `paused/1` calls.
  defp loop(watch) do
    receive do
      {:DOWN, ref, :process, _, _} when ref == watch.ref ->
        :ok

      :done ->
        :ok

      :pause when watch.paused > 0 ->
        loop(%{watch | paused: watch.paused + 1})

      :pause ->
        left = :erlang.cancel_timer(watch.timer) || 0
        loop(%{watch | timer: nil, left: left, paused: 1})

      :resume when watch.paused > 1 ->
        loop(%{watch | paused: watch.paused - 1})

      :resume ->
        watch |> start_timer() |> Map.put(:paused, 0) |> loop()

      # A timer cancelled after it fired leaves a message of another ref.
      {:timeout, ref, :setup_all} when ref == watch.timer ->
        expire(watch)

      {:timeout, _stale, :setup_all} ->
        loop(watch)
    end
  end

  defp start_timer(watch) do
    %{watch | timer: :erlang.start_timer(watch.left, self(), :setup_all)}
  end

  defp expire(%{owner: owner, ref: ref, state: state, timeout: timeout}) do
    # The callbacks ended first: nothing to do.
    if :atomics.compare_exchange(state, 1, 0, 2) == :ok do
      stack =
        case Process.info(owner, :current_stacktrace) do
          {:current_stacktrace, stack} -> stack
          nil -> []
        end

      error = RuntimeError.exception(~s("setup_all" hook timeout of #{timeout}ms exceeded.))
      Process.exit(owner, {error, stack})

      # A process that traps exits got a message instead.
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        1000 -> Process.exit(owner, :kill)
      end
    end

    :ok
  end
end
