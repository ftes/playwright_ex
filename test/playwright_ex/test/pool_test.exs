defmodule PlaywrightEx.Test.PoolTest do
  # Sets `max_isolated` and stops every driver of `PlaywrightEx.Test` (`after_suite`,
  # `stop_all`): not async, so it runs alone, after the async modules. The sync modules after it
  # get new drivers from their `setup_all`.
  use ExUnit.Case, async: false
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.Pool

  # A driver of this module's (no other module passes this `env`) and a browser of each test's
  # (`launch_options` no other test passes).
  defp opts(extra \\ []) do
    [driver: [env: [{"PW_POOL_TEST", "1"}]], launch_options: [timeout: 40_000 + System.unique_integer([:positive])]] ++
      extra
  end

  # The context map of a module of its own (as its `setup_all` gives it).
  defp module, do: %{playwright_ex_module: Pool.start_module()}

  # A test of `module` whose process exits with `reason` after sending `messages` (as the `test`
  # macro does): its result.
  defp run_test(module, messages, reason, opts \\ []) do
    pid =
      spawn(fn ->
        receive do
          :go ->
            for message <- messages, do: Pool.notify(message.(self()))
            exit(reason)
        end
      end)

    Pool.watch(pid, module.playwright_ex_module, Keyword.get(opts, :marked, "setup failed"), opts[:timeout_error])
    send(pid, :go)
    Pool.result(pid, 5000)
  end

  defp passed, do: &{:passed, &1}

  def on_start(playwright, test_pid) do
    send(test_pid, {:on_start, playwright})
    :ok
  end

  # Runs in the slot: its links are the pool and the driver's supervisor.
  def raise_on_start(_playwright, test_pid) do
    {:links, links} = Process.info(self(), :links)
    send(test_pid, {:drivers, links -- [Process.whereis(Pool)]})
    raise "on_start failed"
  end

  # A stopped driver's handles may be unreadable (TargetClosedError).
  defp connected?(browser) do
    Browser.is_connected(browser)
  rescue
    PlaywrightEx.TargetClosedError -> false
  end

  defp gone?(browser, attempts \\ 200) do
    cond do
      not connected?(browser) -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && gone?(browser, attempts - 1)
    end
  end

  test "modules with the same options share one browser, launched once" do
    opts = opts(on_start: {__MODULE__, :on_start, [self()]})
    results = 1..5 |> Enum.map(fn _ -> Task.async(fn -> browser(opts) end) end) |> Task.await_many(30_000)

    assert [%{browser: browser, playwright: playwright}] = Enum.uniq(results)
    assert Browser.is_connected(browser)
    assert_received {:on_start, ^playwright}
    refute_received {:on_start, _}
  end

  test "an on_start that raises leaves no driver running" do
    opts = opts(on_start: {__MODULE__, :raise_on_start, [self()]})
    assert_raise RuntimeError, "on_start failed", fn -> browser(opts) end
    assert_received {:drivers, [sup]}
    refute Process.alive?(sup)
  end

  test "one driver hosts every browser type" do
    a = browser(opts())
    b = browser(Keyword.put(opts(), :browser_name, PlaywrightEx.TestBrowser.other_name()))
    assert a.playwright == b.playwright
    assert a.browser != b.browser
  end

  test "a lost browser is launched again" do
    opts = opts()
    %{browser: browser} = browser(opts)
    Browser.close!(browser)
    %{browser: again} = browser(opts)
    assert again != browser
    assert Browser.is_connected(again)
  end

  test "on_start runs again on a driver its supervisor restarted" do
    opts = opts(on_start: {__MODULE__, :on_start, [self()]})
    %{playwright: playwright, browser: browser} = browser(opts)
    assert_received {:on_start, ^playwright}

    # kill -9 of the driver: its connection goes, the supervisor starts a new one.
    %{port: port} = :sys.get_state(PlaywrightEx.Runtime.Heap.get(playwright, :driverProcess))
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    ref = Process.monitor(playwright.conn)
    {_, 0} = System.cmd("kill", ["-9", to_string(os_pid)])
    assert_receive {:DOWN, ^ref, :process, _, _}, 10_000

    %{playwright: again, browser: relaunched} = browser(opts)
    assert again != playwright
    assert_received {:on_start, ^again}
    assert relaunched != browser
    assert Browser.is_connected(relaunched)
  end

  describe "results" do
    test "passed: the body's end marked, then the process ended as ExUnit ends a test" do
      assert run_test(module(), [passed()], :shutdown) == {:passed, []}
    end

    test "failed: an error the test macro caught, or the setup's" do
      failure = {:error, %RuntimeError{message: "boom"}, []}
      assert run_test(module(), [&{:failed, &1, failure}], :shutdown) == {:failed, [failure]}
      assert run_test(module(), [], :shutdown) == {:failed, ["setup failed"]}
    end

    test "failed: killed past the timeout, or taken down by a linked process" do
      timeout = ExUnit.TimeoutError.exception(timeout: 100, type: "test")
      assert run_test(module(), [], :killed, timeout_error: timeout) == {:failed, [{:error, timeout, []}]}
      assert {:failed, [{{:EXIT, _pid}, {:boom, []}, []}]} = run_test(module(), [passed()], {:boom, []})
    end

    test "unknown for a test of another macro (a doctest), unless its process crashed" do
      assert run_test(module(), [], :shutdown, marked: false) == {nil, []}
      assert {:failed, [_]} = run_test(module(), [], :boom, marked: false)
      assert Pool.result(spawn(fn -> :ok end), 100) == {nil, []}
    end

    test "a module finishes once its tests have ended, then forgets their results" do
      module = module()
      pid = spawn(fn -> receive(do: (:go -> exit(:shutdown))) end)
      Pool.watch(pid, module.playwright_ex_module, "setup failed", nil)
      finished = Task.async(fn -> Pool.module_finished(module.playwright_ex_module) end)
      assert Task.yield(finished, 200) == nil
      send(pid, :go)
      assert Task.await(finished) == :ok
      assert Pool.result(pid, 100) == {nil, []}
    end
  end

  describe "isolate" do
    setup do
      config = Application.get_env(:playwright_ex, :test)
      Application.put_env(:playwright_ex, :test, Keyword.put(config, :max_isolated, 2))
      on_exit(fn -> Application.put_env(:playwright_ex, :test, config) end)
    end

    test "at most max_isolated modules have a driver at once; a failed module's is discarded" do
      opts = opts(isolate: true)
      [ma, mb, mc, md] = for _ <- 1..4, do: module()
      a = browser(ma, opts)
      b = browser(mb, opts)
      assert a.playwright != b.playwright

      c = Task.async(fn -> browser(mc, opts) end)
      assert Task.yield(c, 1_000) == nil

      # Checked in: the next module gets the same driver and browser.
      run_test(ma, [passed()], :shutdown)
      Pool.module_finished(ma.playwright_ex_module)
      assert Task.await(c) == a

      # Discarded after a failure: its driver stops, the next module gets a new one.
      run_test(mb, [], :boom)
      Pool.module_finished(mb.playwright_ex_module)
      d = browser(md, opts)
      assert d.playwright not in [a.playwright, b.playwright]
      assert gone?(b.browser)

      for m <- [mc, md], do: run_test(m, [], :boom) && Pool.module_finished(m.playwright_ex_module)
    end

    # Idle slots above `max_isolated` (the suite's, when this test lowers it): busy slots alone
    # count against it.
    test "idle slots of another key make no room while busy slots fill max_isolated" do
      config = Application.get_env(:playwright_ex, :test)
      Application.put_env(:playwright_ex, :test, Keyword.put(config, :max_isolated, 4))
      other = opts(isolate: true, on_start: {__MODULE__, :on_start, [self()]})
      ms = for _ <- 1..3, do: module()
      for m <- ms, do: browser(m, other)
      for m <- ms, do: Pool.module_finished(m.playwright_ex_module)
      Application.put_env(:playwright_ex, :test, Keyword.put(config, :max_isolated, 2))

      opts = opts(isolate: true)
      [mn, mo, mp] = for _ <- 1..3, do: module()
      a = browser(mn, opts)
      _b = browser(mo, opts)
      c = Task.async(fn -> browser(mp, opts) end)
      assert Task.yield(c, 1_000) == nil

      Pool.module_finished(mn.playwright_ex_module)
      assert Task.await(c) == a
      for m <- [mo, mp], do: run_test(m, [], :boom) && Pool.module_finished(m.playwright_ex_module)
    end

    test "a checked-in module's extra browsers are closed" do
      opts = opts(isolate: true)
      [me, mf] = [module(), module()]
      a = browser(me, opts)
      extra = PlaywrightEx.BrowserType.launch!(PlaywrightEx.Browser.browser_type(a.browser))
      Pool.module_finished(me.playwright_ex_module)
      assert gone?(extra)
      assert browser(mf, opts) == a
      assert Browser.is_connected(a.browser)
      run_test(mf, [], :boom)
      Pool.module_finished(mf.playwright_ex_module)
    end

    test "one driver per module and driver key: another browser key launches on it" do
      opts = opts(isolate: true)
      m = module()
      a = browser(m, opts)
      assert browser(m, opts) == a
      b = browser(m, Keyword.put(opts, :browser_name, PlaywrightEx.TestBrowser.other_name()))
      assert a.playwright == b.playwright
      c = browser(m, Keyword.put(opts, :on_start, {__MODULE__, :on_start, [self()]}))
      assert c.playwright != a.playwright
      run_test(m, [], :boom)
      Pool.module_finished(m.playwright_ex_module)
      assert gone?(a.browser) and gone?(c.browser)
    end

    test "a module that never asks for a browser holds none" do
      m = module()
      Pool.module_finished(m.playwright_ex_module)
      refute Map.has_key?(:sys.get_state(Pool).busy, m.playwright_ex_module)
    end
  end

  test "after_suite waits for the drivers being discarded" do
    m = module()
    isolated = browser(m, opts(isolate: true))
    run_test(m, [], :boom)
    Pool.module_finished(m.playwright_ex_module)
    Pool.after_suite(%{})
    refute connected?(isolated.browser)
  end

  test "after_suite stops every driver" do
    %{browser: one} = browser(opts())
    %{browser: two} = browser(opts())
    isolated = browser(module(), opts(isolate: true))

    Pool.after_suite(%{})
    refute connected?(one) or connected?(two) or connected?(isolated.browser)

    # The next use starts anew.
    assert %{browser: three} = browser(opts())
    assert Browser.is_connected(three)
  end
end
