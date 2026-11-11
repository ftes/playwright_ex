defmodule PlaywrightEx.SharedDriver do
  @moduledoc """
  The suite's side of `PlaywrightEx.Test`'s shared drivers (`UpstreamCase`, `ExampleCase`):
  cleanup that touches only what a test or module created, and a guard that fails a shared
  module's test that changed the driver or its browser for the modules running alongside.

  `track_test/2` (in `setup`) follows the test's processes (the test and its `Task`s) with a
  `ClientInstrumentation` listener: the contexts they create and the browsers they launch are
  closed after the test, as the driver used to go with the module. `track_module/2` (in
  `setup_all`) does the same for the module's own process (a `setup_all` that launches a
  browser). Upstream leaves both to the worker's end; on a shared driver that is the run's end.

  With `guard: true` (a shared module), each test fails after its `on_exit` callbacks if:

    * the shared browser is closed;
    * the driver has selector engines (`Selectors.register`; they are reset, so the next tests
      pass);
    * the driver's test id attribute is not `data-testid`.

  The selectors and the test id are the driver's, so a module running alongside may be the one
  that changed them: the message names both. Such a module needs `isolate: true`.
  """
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Heap

  require Logger

  @doc """
  Whether the module gets a driver of its own: when it declares `isolate: true`, and on Firefox
  always, which serializes input across the pages of a browser (a `Mouse.move` waits for a frame
  of the whole browser): concurrent modules on one Firefox time out.
  """
  def isolate?(tags), do: tags[:isolate] == true or PlaywrightEx.TestBrowser.name() == "firefox"

  @doc """
  Closes what the test's processes create on `playwright`'s driver, after its `on_exit`
  callbacks (call it before the fixtures' setups). Options: `:shared` (the browsers it must
  not close: the module's), `:guard` (see the moduledoc).
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
      close_browsers(playwright, pids, opts[:shared] || [])
      if opts[:guard], do: guard!(playwright, opts[:shared] || [])
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
  driver, after the module. Option: `:shared`, the browsers it must not close.
  """
  def track_module(playwright, opts) do
    module_pid = self()

    ExUnit.Callbacks.on_exit(fn ->
      contexts = Api.call(nil, playwright, fn -> Client.Playwright._all_contexts(playwright) end)
      for context <- contexts, created_by?(context, [module_pid]), do: BrowserContext.close(context)
      close_browsers(playwright, [module_pid], opts[:shared] || [])
    end)

    :ok
  end

  defp safe_update(agent, fun) do
    Agent.update(agent, fun)
  catch
    # The test is over.
    :exit, _ -> :ok
  end

  defp close_browsers(playwright, pids, shared) do
    browsers =
      Api.call(nil, playwright, fn ->
        for name <- [:chromium, :firefox, :webkit],
            type = Heap.get(playwright, name),
            object <- Heap.map_values(type, :_objects),
            object.type == "Browser",
            object not in shared,
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

  defp guard!(playwright, shared) do
    selectors = Playwright.selectors(playwright)

    {engines, test_id} =
      Api.call(nil, playwright, fn ->
        engines = Heap.get(selectors, :_selectorEngines)
        # The next tests run without them.
        if engines != [], do: Heap.put(selectors, :_selectorEngines, [])
        {engines, Heap.get(selectors, :_testIdAttributeName)}
      end)

    problems =
      Enum.reject(
        [
          if(not Enum.all?(shared, &connected?/1), do: "closed the shared browser"),
          if(engines != [],
            do: "left selector engines #{inspect(Enum.map(engines, & &1.name))} registered (reset now)"
          ),
          if(test_id not in [nil, "data-testid"], do: "left the test id attribute #{inspect(test_id)}")
        ],
        &is_nil/1
      )

    if problems != [] do
      raise ExUnit.AssertionError,
        message:
          "this test (or a module running alongside on the shared driver) " <>
            Enum.join(problems, ", ") <>
            ": a module that changes its driver or browser for others needs `isolate: true`"
    end
  end

  defp connected?(browser) do
    Browser.is_connected(browser)
  rescue
    _ -> false
  end
end
