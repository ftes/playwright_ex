defmodule Playwright.Test.SetupAllTimeout do
  @moduledoc false
  # The timeout of a module's `setup_all`, as upstream's `beforeAll` hook gets the test timeout
  # (`project.timeout`) in a time slot of its own (`packages/playwright/src/worker/workerMain.ts`,
  # `_runAllHooksForSuite`) and fails with `"beforeAll" hook timeout of 30000ms exceeded.`
  # (`timeoutManager.ts`, `_createTimeoutError`). ExUnit has none: it waits for the `setup_all`
  # process without a timeout, and fails the module when that process exits.
  #
  # So a watchdog, started by the module's first `setup_all` callback (`Playwright.Test.__clock__/1`),
  # exits the `setup_all` process past ExUnit's timeout of the module (its `@moduletag timeout:`,
  # else `mix test --timeout`; none under `--trace`), if it still runs the callbacks then: its
  # stack still has the module's `__ex_unit__/2`, ExUnit's compiled callbacks (which keep their
  # frames: `ExUnit.Callbacks.__noop__/0`). ExUnit then fails the module with the exit reason,
  # upstream's message and the stack the process was at. Elixir only: one slot for all of the
  # module's `setup_all` callbacks, where upstream gives each hook its own. A wait for a pooled
  # browser's seat is not counted (`paused/1`), as upstream's dispatcher queue has no timeout.

  @key {__MODULE__, :watchdog}

  @doc "Starts the watchdog of the calling `setup_all` process, unless the module has no timeout."
  def start(context) do
    case Process.get(@key) || timeout(context) do
      # Once, for a case template's `use` and its `using`'s.
      watchdog when is_pid(watchdog) ->
        :ok

      timeout when is_integer(timeout) ->
        owner = self()
        module = context[:module]
        Process.put(@key, spawn(fn -> watch(owner, module, timeout) end))

      :infinity ->
        :ok
    end

    :ok
  end

  @doc "Runs `fun` with the calling `setup_all`'s clock stopped (a wait for a seat)."
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

  # ExUnit's `get_timeout/2` for the module's tags: none under `--trace`, else the `timeout` tag
  # or the config's.
  defp timeout(context) do
    config = ExUnit.configuration()
    if config[:trace], do: :infinity, else: Map.get(context, :timeout, config[:timeout])
  end

  defp watch(owner, module, timeout) do
    ref = Process.monitor(owner)
    loop(owner, ref, module, timeout, Process.send_after(self(), :timeout, timeout))
  end

  # `timer` is `nil` while paused, `left` the time it then had.
  defp loop(owner, ref, module, timeout, timer, left \\ 0) do
    receive do
      {:DOWN, ^ref, :process, _, _} ->
        :ok

      :pause ->
        left = Process.cancel_timer(timer) || 0
        # Fired already: drop its message; the resume fires at once (`left` 0).
        receive do
          :timeout -> :ok
        after
          0 -> :ok
        end

        loop(owner, ref, module, timeout, nil, left)

      :resume ->
        loop(owner, ref, module, timeout, Process.send_after(self(), :timeout, left))

      :timeout ->
        expire(owner, ref, module, timeout)
    end
  end

  defp expire(owner, ref, module, timeout) do
    with {:current_stacktrace, stack} <- Process.info(owner, :current_stacktrace),
         true <- Enum.any?(stack, &match?({^module, :__ex_unit__, 2, _}, &1)) do
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
