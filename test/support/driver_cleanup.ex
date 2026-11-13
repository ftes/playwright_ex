defmodule PlaywrightEx.DriverCleanup do
  @moduledoc """
  The suite's cleanup on `PlaywrightEx.Test`'s pooled drivers (`UpstreamCase`, `ExampleCase`),
  which a passing module hands on, warm, to the next: it touches only what a test or module
  created.

  `track_test/2` (in `setup`) follows the test's processes (the test and its `Task`s) with a
  `ClientInstrumentation` listener: the contexts they create and the browsers they launch are
  closed after the test. `track_module/2` (in `setup_all`) does the same for the module's own
  process (a `setup_all` that launches a browser). Upstream leaves both to the worker's end;
  here a worker outlives its module. Option `:keep`: the browsers not to close, the module's.
  """
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Heap

  require Logger

  @doc """
  Closes what the test's processes create on `playwright`'s driver, after its `on_exit`
  callbacks (call it before the fixtures' setups).
  """
  def track_test(playwright, opts) do
    test_pid = self()
    {:ok, created} = Agent.start(fn -> %{contexts: [], pids: MapSet.new([test_pid])} end)
    instrumentation = Heap.get(playwright, :_instrumentation)
    listener = listener(test_pid, created)
    Heap.update(instrumentation, :listeners, &(&1 ++ [listener]))

    ExUnit.Callbacks.on_exit(fn ->
      # Exactly this listener: the ported `remove_listener` removes the last one for an unknown one.
      if Heap.readable?(instrumentation), do: Heap.update(instrumentation, :listeners, &List.delete(&1, listener))
      %{contexts: contexts, pids: pids} = Agent.get(created, & &1)
      Agent.stop(created)
      for context <- contexts, do: BrowserContext.close(context)
      close_browsers(playwright, pids, opts[:keep] || [])
    end)

    :ok
  end

  # Runs in the process that calls the API, for every caller on the driver: records what the
  # test and its `Task`s (`$callers`) create.
  defp listener(test_pid, created) do
    ours? = fn -> self() == test_pid or test_pid in List.wrap(Process.get(:"$callers")) end

    %{
      ref: make_ref(),
      # A `Task` of the test that calls the API may launch a browser: its pid, once.
      onApiCallBegin: fn _api_call, _channel ->
        if self() != test_pid and Process.get({__MODULE__, created}) == nil and ours?.() do
          Process.put({__MODULE__, created}, true)
          pid = self()
          safe_update(created, &%{&1 | pids: MapSet.put(&1.pids, pid)})
        end
      end,
      runAfterCreateBrowserContext: fn context ->
        if ours?.(), do: safe_update(created, &%{&1 | contexts: [context | &1.contexts]})
      end
    }
  end

  @doc """
  Closes the browsers and contexts the module's process (`setup_all`) created on `playwright`'s
  driver, after the module.
  """
  def track_module(playwright, opts) do
    module_pid = self()

    ExUnit.Callbacks.on_exit(fn ->
      contexts = Api.call(nil, playwright, fn -> Client.Playwright._all_contexts(playwright) end)
      for context <- contexts, created_by?(context, [module_pid]), do: BrowserContext.close(context)
      close_browsers(playwright, [module_pid], opts[:keep] || [])
    end)

    :ok
  end

  defp safe_update(agent, fun) do
    Agent.update(agent, fun)
  catch
    # The test is over.
    :exit, _ -> :ok
  end

  defp close_browsers(playwright, pids, keep) do
    browsers =
      Api.call(nil, playwright, fn ->
        for name <- [:chromium, :firefox, :webkit],
            type = Heap.get(playwright, name),
            object <- Heap.map_values(type, :_objects),
            object.type == "Browser",
            object not in keep,
            created_by?(object, pids),
            do: object
      end)

    Enum.each(browsers, &Browser.close/1)
  rescue
    exception -> Logger.warning("could not close a test's browsers: " <> Exception.message(exception))
  end

  defp created_by?(object, pids) do
    Enum.any?(Heap.get(object, :_creators) || [], &(&1 in pids))
  rescue
    _ -> false
  end
end
