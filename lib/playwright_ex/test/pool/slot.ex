defmodule PlaywrightEx.Test.Pool.Slot do
  @moduledoc false
  # One driver and its browser, in a process of its own: starting the driver and launching
  # block this slot and its callers only, and the slot stays alive as the browser's creator,
  # which anchors its rows. Lazy: the driver starts with the first `browser/1`, which adds the
  # recording listener (`PlaywrightEx.Test.Recorder.listener/0`), sets the test id attribute and
  # runs `on_start` on each new driver's Playwright before the launch. Its one browser is the
  # slot's options' (`browser_name`, `launch_options`, `connect_options`), as upstream's worker
  # runs its project's: the listener on the driver's instrumentation sees its contexts, also
  # those of a connected browser, whose connection shares it. A lost browser (closed,
  # disconnected, or its driver gone) is launched or connected again by the next `browser/1`.
  use GenServer

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Facade
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Selectors
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Recorder

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "`%{playwright: _, browser: _}`, starting the driver and launching the browser if needed."
  def browser({pid, _key}) do
    case GenServer.call(pid, :browser, :infinity) do
      {:ok, result} -> result
      {:error, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  def browser(:stopped), do: raise("PlaywrightEx.Test's drivers were stopped (after the suite)")

  def browser(:released),
    do: raise(ArgumentError, "BrowserPool.browser/1 waited past the end of its test or module")

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
    with {:ok, state} <- driver(state),
         {:ok, browser, state} <- launch(state) do
      {:reply, {:ok, %{playwright: state.playwright, browser: browser}}, state}
    else
      {:error, error, state} -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:EXIT, sup, _reason}, %{sup: sup} = state) do
    forget_driver(state)
    {:noreply, %{state | sup: nil, name: nil, playwright: nil, browser: nil}}
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
      state = %{state | playwright: playwright, browser: nil}
      # `_setupContextOptions`' `selectors.setTestIdAttribute(testIdAttribute)`: suite-wide,
      # as the client's value (`get_by_test_id`) is global to the VM.
      Selectors.set_test_id_attribute(Playwright.selectors(playwright), Options.test_id_attribute())
      on_start(state.opts.on_start, playwright)
      {:ok, state}
    end
  rescue
    exception -> {:error, {:error, exception, __STACKTRACE__}, stop_driver(state)}
  end

  # A launch that fails leaves the driver be.
  defp launch(%{browser: nil} = state), do: launch_new(state)

  defp launch(state) do
    if connected?(state.browser) do
      {:ok, state.browser, state}
    else
      forget_browser(state, state.browser)
      launch_new(%{state | browser: nil})
    end
  end

  defp launch_new(%{opts: opts} = state) do
    browser_type = apply(Playwright, opts.browser_name, [state.playwright])
    browser = launch_or_connect(browser_type, opts.launch_options, opts.connect_options)
    # `BrowserPool.playwright/1` of a connected browser: the driver's.
    :ets.insert(PlaywrightEx.Test.Pool.table(), {{:driver, browser.conn}, state.playwright})
    {:ok, browser, %{state | browser: browser}}
  rescue
    exception -> {:error, {:error, exception, __STACKTRACE__}, state}
  end

  # Playwright Test's `browser` fixture: with `connectOptions`, a connection to the server, which
  # launches the browser with the launch options of the `x-playwright-launch-options` header (the
  # client's options, as JSON).
  defp launch_or_connect(browser_type, launch_options, nil), do: BrowserType.launch!(browser_type, launch_options)

  defp launch_or_connect(browser_type, launch_options, connect_options) do
    {ws_endpoint, options} = Keyword.pop!(connect_options, :ws_endpoint)
    launch_options = Facade.options!(launch_options, BrowserType.__options_type__(:launch), "browserType.launch")
    # HTTP headers are ASCII only (not UTF-8).
    headers = %{"x-playwright-launch-options" => json_stringify_force_ascii(launch_options)}

    BrowserType.connect!(
      browser_type,
      ws_endpoint,
      Keyword.put(options, :headers, Map.merge(headers, options[:headers] || %{}))
    )
  end

  # `jsonStringifyForceASCII` (`packages/utils/ascii.ts`): `\uXXXX` for each UTF-16 code unit
  # from U+007F.
  defp json_stringify_force_ascii(object) do
    for <<c::utf8 <- ClientHelper.json_stringify(object)>>, into: "" do
      cond do
        c < 0x7F ->
          <<c>>

        c <= 0xFFFF ->
          unicode_escape(c)

        true ->
          unicode_escape(0xD800 + Bitwise.bsr(c - 0x10000, 10)) <>
            unicode_escape(0xDC00 + Bitwise.band(c - 0x10000, 0x3FF))
      end
    end
  end

  defp unicode_escape(unit), do: "\\u" <> String.pad_leading(Integer.to_string(unit, 16) |> String.downcase(), 4, "0")

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
    %{state | sup: nil, name: nil, playwright: nil, browser: nil}
  catch
    :exit, _ -> %{state | sup: nil, name: nil, playwright: nil, browser: nil}
  end

  defp forget_driver(%{playwright: nil}), do: :ok

  defp forget_driver(state) do
    if state.browser, do: forget_browser(state, state.browser)
    :ets.delete(PlaywrightEx.Test.Pool.table(), {:driver, state.playwright.conn})
  end

  # A connected browser's connection.
  defp forget_browser(state, browser) do
    if browser.conn != state.playwright.conn, do: :ets.delete(PlaywrightEx.Test.Pool.table(), {:driver, browser.conn})
  end
end
