defmodule PlaywrightEx.Test.Pool.Slot do
  @moduledoc false
  # One driver and its browsers, in a process of its own: starting the driver and launching
  # block this slot and its callers only, and the slot stays alive as the browsers' creator,
  # which anchors their rows. Lazy: the driver starts with the first `browser/2`, which adds the
  # recording listener (`PlaywrightEx.Test.Recorder.listener/0`) and runs `on_start` on each new
  # driver's Playwright before any launch.
  # It hosts a browser per `{browser_name, launch_options}`, as upstream runs every browser type
  # on one Playwright: the listener on the driver's instrumentation sees all of their contexts. A
  # lost browser (closed, or its driver gone) is launched again by the next `browser/2`.
  use GenServer

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Test.Recorder

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "`%{playwright: _, browser: _}`, starting the driver and launching the browser if needed."
  def browser({pid, _key}, opts) do
    case GenServer.call(pid, {:browser, opts.browser_name, Enum.sort(opts.launch_options)}, :infinity) do
      {:ok, result} -> result
      {:error, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  def browser(:stopped, _opts), do: raise("PlaywrightEx.Test's drivers were stopped (after the suite)")

  def browser(:released, _opts),
    do: raise(ArgumentError, "BrowserPool.exclusive/1 waited past the end of its test or module")

  @doc "The Playwright of the driver whose connection is `conn`, `nil` for one the pool didn't start."
  def playwright(conn) do
    case PlaywrightEx.Test.Pool.started?() && :ets.lookup(PlaywrightEx.Test.Pool.table(), {:driver, conn}) do
      [{_key, playwright}] -> playwright
      _ -> nil
    end
  end

  @doc "Closes the browsers a lease's holder launched on this driver and left open."
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
    {:ok, %{opts: opts, sup: nil, name: nil, playwright: nil, browsers: %{}}}
  end

  @impl true
  def handle_call({:browser, browser_name, launch_options}, _from, state) do
    with {:ok, state} <- driver(state),
         {:ok, browser, state} <- launch(state, browser_name, launch_options) do
      {:reply, {:ok, %{playwright: state.playwright, browser: browser}}, state}
    else
      {:error, error, state} -> {:reply, error, state}
    end
  end

  @impl true
  def handle_cast(:check_in, state) do
    close_others(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, sup, _reason}, %{sup: sup} = state) do
    forget_driver(state)
    {:noreply, %{state | sup: nil, name: nil, playwright: nil, browsers: %{}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_driver(state)

  # The driver, started and set up. A start that fails leaves none.
  defp driver(state) do
    state |> start_driver() |> set_up()
  rescue
    exception -> {:error, {:error, exception, __STACKTRACE__}, state}
  end

  defp start_driver(%{sup: nil} = state) do
    name = :"#{inspect(__MODULE__)}.#{System.unique_integer([:positive])}"
    {:ok, sup} = PlaywrightEx.Supervisor.start_link([name: name] ++ state.opts.driver)
    %{state | sup: sup, name: name}
  end

  defp start_driver(state), do: state

  # A driver restarted by its supervisor has a new root: `on_start` runs on it too. A driver in
  # an unknown state (its `on_start` failed, say) is stopped, also one this call started: the
  # next call starts another.
  defp set_up(state) do
    playwright = PlaywrightEx.playwright(state.name)

    if playwright == state.playwright do
      {:ok, state}
    else
      forget_driver(state)
      ClientInstrumentation.add_listener(Heap.get(playwright, :_instrumentation), Recorder.listener())
      :ets.insert(PlaywrightEx.Test.Pool.table(), {{:driver, playwright.conn}, playwright})
      state = %{state | playwright: playwright, browsers: %{}}
      on_start(state.opts.on_start, playwright)
      {:ok, state}
    end
  rescue
    exception -> {:error, {:error, exception, __STACKTRACE__}, stop_driver(state)}
  end

  # A launch that fails leaves the driver and its other browsers be.
  defp launch(state, browser_name, launch_options) do
    browser_key = {browser_name, launch_options}

    case state.browsers do
      %{^browser_key => browser} ->
        if connected?(browser), do: {:ok, browser, state}, else: launch_new(state, browser_key)

      _ ->
        launch_new(state, browser_key)
    end
  end

  defp launch_new(state, {browser_name, launch_options} = browser_key) do
    browser_type = apply(Playwright, browser_name, [state.playwright])
    browser = BrowserType.launch!(browser_type, launch_options)
    {:ok, browser, %{state | browsers: Map.put(state.browsers, browser_key, browser)}}
  rescue
    exception -> {:error, {:error, exception, __STACKTRACE__}, state}
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
    forget_driver(state)
    Supervisor.stop(state.sup, :normal, :infinity)
    %{state | sup: nil, name: nil, playwright: nil, browsers: %{}}
  catch
    :exit, _ -> %{state | sup: nil, name: nil, playwright: nil, browsers: %{}}
  end

  defp forget_driver(%{playwright: nil}), do: :ok
  defp forget_driver(state), do: :ets.delete(PlaywrightEx.Test.Pool.table(), {:driver, state.playwright.conn})

  # Browsers launched on this driver other than the slot's, still open.
  defp close_others(%{playwright: nil}), do: :ok

  defp close_others(state) do
    own = for {_key, browser} <- state.browsers, do: browser.guid

    others =
      Api.call(nil, state.playwright, fn ->
        for name <- [:chromium, :firefox, :webkit],
            type = Heap.get(state.playwright, name),
            object <- Heap.map_values(type, :_objects),
            object.type == "Browser" and object.guid not in own,
            do: object
      end)

    Enum.each(others, &Browser.close/1)
  rescue
    exception ->
      Logger.warning("PlaywrightEx.Test could not close a module's browsers: " <> Exception.message(exception))
  end
end
