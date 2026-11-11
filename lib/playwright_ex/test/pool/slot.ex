defmodule PlaywrightEx.Test.Pool.Slot do
  @moduledoc false
  # One driver and its browser, in a process of its own (after Fluffy's `BrowserRuntime.Slot`):
  # starting the driver and launching block this slot and its callers only, and the slot stays
  # alive as the browser's creator, which anchors its rows. Lazy: the driver starts with the
  # first `browser/1`, which runs `on_start` on each new driver's Playwright before any launch.
  # A lost browser (closed, or its driver gone) is launched again by the next `browser/1`.
  use GenServer

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Heap

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "`%{playwright: _, browser: _}`, starting the driver and launching the browser if needed."
  def browser({pid, _key}) do
    case GenServer.call(pid, :browser, :infinity) do
      {:ok, result} -> result
      {:error, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  def browser(:stopped), do: raise("PlaywrightEx.Test's drivers were stopped (after the suite)")

  @doc "Closes the browsers a module launched on this driver and left open."
  def check_in({pid, _key}), do: GenServer.cast(pid, :check_in)

  @doc "Stops the driver (waiting for it to exit) and the slot."
  def stop({pid, _key}) do
    GenServer.stop(pid, :normal, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{opts: opts, sup: nil, name: nil, playwright: nil, browser: nil}}
  end

  @impl true
  def handle_call(:browser, _from, state) do
    state = ensure_browser(state)
    {:reply, {:ok, %{playwright: state.playwright, browser: state.browser}}, state}
  rescue
    exception ->
      # A driver in an unknown state (its `on_start` failed, say) is replaced next time.
      {:reply, {:error, exception, __STACKTRACE__}, stop_driver(state)}
  end

  @impl true
  def handle_cast(:check_in, state) do
    close_others(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, sup, _reason}, %{sup: sup} = state),
    do: {:noreply, %{state | sup: nil, name: nil, playwright: nil, browser: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_driver(state)

  defp ensure_browser(state) do
    state = ensure_driver(state)

    if state.browser && connected?(state.browser) do
      state
    else
      browser_type = apply(Playwright, state.opts.browser_name, [state.playwright])
      %{state | browser: BrowserType.launch!(browser_type, state.opts.launch_options)}
    end
  end

  # A driver restarted by its supervisor has a new root: `on_start` runs on it too.
  defp ensure_driver(%{sup: nil} = state) do
    name = :"#{inspect(__MODULE__)}.#{System.unique_integer([:positive])}"
    {:ok, sup} = PlaywrightEx.Supervisor.start_link([name: name] ++ state.opts.driver)
    ensure_driver(%{state | sup: sup, name: name})
  end

  defp ensure_driver(state) do
    playwright = PlaywrightEx.playwright(state.name)

    if playwright == state.playwright do
      state
    else
      on_start(state.opts.on_start, playwright)
      %{state | playwright: playwright, browser: nil}
    end
  end

  defp on_start(nil, _playwright), do: :ok
  defp on_start({m, f, a}, playwright), do: apply(m, f, [playwright | a])
  defp on_start(fun, playwright), do: fun.(playwright)

  defp connected?(browser) do
    Browser.is_connected(browser)
  rescue
    _ -> false
  end

  defp stop_driver(%{sup: nil} = state), do: state

  defp stop_driver(state) do
    Supervisor.stop(state.sup, :normal, :infinity)
    %{state | sup: nil, name: nil, playwright: nil, browser: nil}
  catch
    :exit, _ -> %{state | sup: nil, name: nil, playwright: nil, browser: nil}
  end

  # Browsers launched on this driver other than the slot's, still open.
  defp close_others(%{browser: nil}), do: :ok

  defp close_others(state) do
    others =
      Api.call(nil, state.playwright, fn ->
        for name <- [:chromium, :firefox, :webkit],
            type = Heap.get(state.playwright, name),
            object <- Heap.map_values(type, :_objects),
            object.type == "Browser" and object.guid != state.browser.guid,
            do: object
      end)

    Enum.each(others, &Browser.close/1)
  rescue
    exception ->
      Logger.warning("PlaywrightEx.Test could not close a module's browsers: " <> Exception.message(exception))
  end
end
