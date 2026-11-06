defmodule PlaywrightEx.TestWorkers do
  @moduledoc """
  Upstream's workers (`packages/playwright/src/index.ts`, `tests/config/browserTest.ts`): the
  worker-scoped `playwright` and `browser`, shared by the test modules that run one after
  another in it. At most `max_cases` modules run at once, so there are as many workers per kind
  (`:upstream`, driver under test; `:example`, a plain driver).

  `checkout/1` (in a module's `setup_all`) hands a module a worker of its own for its lifetime,
  launching the browser again if it was closed. `PlaywrightEx.FailuresFormatter` checks it in at
  `module_finished`; a module with a failed test discards its worker (driver and browser), as
  upstream discards a worker after a failure. Checking in closes the browsers the module launched
  and left open.
  """
  use GenServer

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.TestBrowser

  # A worker whose `module_finished` never came (a crashed formatter) is replaced after this.
  @wait 120_000

  def start do
    {:ok, _} = GenServer.start(__MODULE__, ExUnit.configuration()[:max_cases], name: __MODULE__)
    :ok
  end

  @doc "A worker for `module` until its `module_finished`: `%{playwright: _, browser: _, artifacts_dir: _}`."
  def checkout(kind, module), do: GenServer.call(__MODULE__, {:checkout, kind, module}, :infinity)

  @doc false
  def module_finished(module, failed?), do: GenServer.cast(__MODULE__, {:module_finished, module, failed?})

  @impl true
  def init(max) do
    Process.flag(:trap_exit, true)
    {:ok, %{max: max, free: %{}, busy: %{}, waiting: [], count: %{}}}
  end

  @impl true
  def handle_call({:checkout, kind, module}, from, state) do
    case state.free do
      %{^kind => [worker | rest]} ->
        reply(%{state | free: Map.put(state.free, kind, rest)}, from, module, ensure_browser(worker))

      _ ->
        if Map.get(state.count, kind, 0) < state.max do
          reply(%{state | count: Map.update(state.count, kind, 1, &(&1 + 1))}, from, module, start_worker(kind))
        else
          Process.send_after(self(), {:timeout, from}, @wait)
          {:noreply, %{state | waiting: state.waiting ++ [{kind, from, module}]}}
        end
    end
  end

  @impl true
  def handle_cast({:module_finished, module, failed?}, state) do
    case Map.pop(state.busy, module) do
      {nil, _} ->
        {:noreply, state}

      {worker, busy} ->
        state = %{state | busy: busy}
        worker = if failed?, do: discard(worker), else: close_others(worker)
        {:noreply, give(state, worker)}
    end
  end

  @impl true
  def handle_info({:timeout, from}, state) do
    case Enum.split_with(state.waiting, &match?({_, ^from, _}, &1)) do
      {[{kind, ^from, module}], waiting} ->
        state = %{state | waiting: waiting, count: Map.update(state.count, kind, 1, &(&1 + 1))}
        reply(state, from, module, start_worker(kind))

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # A discarded worker (nil) leaves a slot for a new one.
  defp give(state, worker) do
    kind = worker_kind(worker)

    case Enum.split_with(state.waiting, &match?({^kind, _, _}, &1)) do
      {[{^kind, from, module} | more], others} ->
        state = %{state | waiting: more ++ others}
        worker = if is_map(worker), do: ensure_browser(worker), else: start_worker(kind)
        {:noreply, state} = reply(state, from, module, worker)
        state

      {[], _} when is_map(worker) ->
        %{state | free: Map.update(state.free, kind, [worker], &[worker | &1])}

      {[], _} ->
        %{state | count: Map.update!(state.count, kind, &(&1 - 1))}
    end
  end

  defp worker_kind({:discarded, kind}), do: kind
  defp worker_kind(%{kind: kind}), do: kind

  defp reply(state, from, module, worker) do
    GenServer.reply(from, worker)
    {:noreply, %{state | busy: Map.put(state.busy, module, worker)}}
  end

  defp start_worker(kind) do
    debug("start #{kind}")
    name = :"#{__MODULE__}.#{kind}.#{System.unique_integer([:positive])}"
    env = if kind == :upstream, do: [{"PWTEST_UNDER_TEST", "1"}], else: []
    {:ok, sup} = PlaywrightEx.Supervisor.start_link(name: name, env: env)
    playwright = PlaywrightEx.playwright(name)
    artifacts_dir = PlaywrightEx.UpstreamCase.artifacts_dir()
    if kind == :upstream, do: PlaywrightEx.UpstreamCase.setup_playwright(playwright, artifacts_dir)
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
    %{kind: kind, sup: sup, playwright: playwright, browser: browser, artifacts_dir: artifacts_dir}
  end

  # The driver or its browser went away (a test closed `browser`, say): relaunch what's gone.
  defp ensure_browser(worker) do
    cond do
      not Process.alive?(worker.sup) ->
        discard(worker)
        start_worker(worker.kind)

      safe(fn -> Browser.is_connected(worker.browser) end) == true ->
        worker

      true ->
        debug("relaunch #{worker.kind}")
        %{worker | browser: BrowserType.launch!(TestBrowser.browser_type(worker.playwright))}
    end
  end

  defp discard(worker) do
    debug("discard #{worker.kind}")
    Process.unlink(worker.sup)
    ref = Process.monitor(worker.sup)
    Process.exit(worker.sup, :shutdown)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      10_000 -> Process.exit(worker.sup, :kill)
    end

    File.rm_rf(worker.artifacts_dir)
    {:discarded, worker.kind}
  end

  # Browsers the module launched on this driver and left open (the driver used to go with the module).
  defp close_others(worker) do
    browsers = safe(fn -> Api.call(nil, worker.playwright, fn -> other_browsers(worker) end) end)

    for browser <- List.wrap(browsers), do: safe(fn -> Browser.close(browser) end)
    worker
  rescue
    _ -> discard(worker)
  end

  defp other_browsers(worker) do
    for name <- [:chromium, :firefox, :webkit],
        type = Heap.get(worker.playwright, name),
        object <- Heap.map_values(type, :_objects),
        object.type == "Browser" and object.guid != worker.browser.guid,
        do: object
  end

  defp debug(message), do: if(System.get_env("PW_WORKERS_DEBUG"), do: IO.puts(:stderr, "[workers] " <> message))

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
