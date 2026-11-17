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
  # each hook its own. A pooled browser (`Pool.browser/2`: the wait for a seat, a driver start and
  # launch) is not counted (`paused/1`), as upstream's dispatcher queue has no timeout and its
  # worker fixtures have their own slot. `paused/1` looks in the calling process only: a
  # `setup_all` scope's `BrowserPool.browser/1` runs in the `setup_all` process itself.

  alias Playwright.Test.Options

  @key {__MODULE__, :watchdog}

  @doc """
  Runs the module's `setup_all` callbacks `fun` within the module's timeout (`context` is theirs).
  Once: a case template's callbacks, run from the module's, are part of its time.
  """
  def run(context, fun) do
    case Process.get(@key) || Options.ex_unit_timeout(context) do
      :infinity ->
        fun.()

      timeout when is_integer(timeout) ->
        owner = self()
        watchdog = spawn(fn -> watch(owner, timeout) end)
        Process.put(@key, watchdog)

        try do
          fun.()
        after
          Process.delete(@key)
          send(watchdog, :done)
        end

      # Inside a running one.
      _watchdog ->
        fun.()
    end
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

  defp watch(owner, timeout) do
    ref = Process.monitor(owner)
    %{owner: owner, ref: ref, timeout: timeout, left: timeout} |> start_timer() |> loop()
  end

  # `timer` is the current timer's tag (`nil` while paused), `left` its time when paused.
  # The callbacks' end (`:done`) wins over a timer that fired at the same time.
  defp loop(state) do
    receive do
      {:DOWN, ref, :process, _, _} when ref == state.ref ->
        :ok

      :done ->
        :ok

      :pause when state.timer != nil ->
        left = Process.cancel_timer(state.timer_ref) || 0
        loop(%{state | timer: nil, left: left})

      :resume ->
        state |> start_timer() |> loop()

      # A stale timer's (cancelled after it fired) is ignored.
      {:timeout, tag} when tag == state.timer ->
        receive do
          :done -> :ok
        after
          0 -> expire(state)
        end

      {:timeout, _stale} ->
        loop(state)
    end
  end

  defp start_timer(state) do
    tag = make_ref()
    Map.merge(state, %{timer: tag, timer_ref: Process.send_after(self(), {:timeout, tag}, state.left)})
  end

  defp expire(%{owner: owner, ref: ref, timeout: timeout}) do
    stack =
      case Process.info(owner, :current_stacktrace) do
        {:current_stacktrace, stack} -> stack
        nil -> []
      end

    error = RuntimeError.exception(~s("setup_all" hook timeout of #{timeout}ms exceeded.))
    Process.exit(owner, {error, stack})

    # A process that traps exits got a message instead: killed, unless its callbacks end first.
    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
      :done -> :ok
    after
      1000 -> Process.exit(owner, :kill)
    end

    :ok
  end
end
