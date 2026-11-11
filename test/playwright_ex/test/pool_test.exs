defmodule PlaywrightEx.Test.PoolTest do
  # Sets `workers` and stops every driver of `PlaywrightEx.Test` (`after_suite`,
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

    Pool.watch(pid, module.playwright_ex_module, Keyword.get(opts, :marked, Pool.outside()))
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

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("timed out waiting")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
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
      assert run_test(module(), [], :shutdown) == {:failed, [Pool.outside()]}
    end

    test "failed: killed (past its timeout), or taken down by a linked process" do
      assert run_test(module(), [], :killed) == {:failed, [Pool.killed()]}
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
      Pool.watch(pid, module.playwright_ex_module, Pool.outside())
      finished = Task.async(fn -> Pool.module_finished(module.playwright_ex_module) end)
      assert Task.yield(finished, 200) == nil
      send(pid, :go)
      assert Task.await(finished) == :ok
      assert Pool.result(pid, 100) == {nil, []}
    end

    test "a watch after the module finished is ignored" do
      %{playwright_ex_module: token} = module()
      Pool.module_finished(token)
      pid = spawn(fn -> :ok end)
      Pool.watch(pid, token, Pool.outside())
      state = :sys.get_state(Pool)
      refute Map.has_key?(state.modules, token) or Map.has_key?(state.tests, pid) or Map.has_key?(state.results, pid)
    end
  end

  # `workers` for the test (the checked-in drivers of the modules before it are stopped for room).
  defp put_workers(workers) do
    config = Application.get_env(:playwright_ex, :test)
    Application.put_env(:playwright_ex, :test, Keyword.put(config, :workers, workers))
  end

  describe "workers" do
    setup do
      config = Application.get_env(:playwright_ex, :test)
      put_workers(2)
      on_exit(fn -> Application.put_env(:playwright_ex, :test, config) end)
    end

    test "shared drivers, one per key, are outside workers" do
      put_workers(1)
      [mi, ms] = [module(), module()]
      browser(mi, opts(isolate: true))
      %{playwright: shared} = browser(ms, opts())
      assert browser(opts()).playwright == shared
      Pool.module_finished(mi.playwright_ex_module)
      Pool.module_finished(ms.playwright_ex_module)
    end

    test "at most workers drivers at once; a failed module's is discarded" do
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

    # Checked-in drivers above `workers` (when this test lowers it) are stopped for room: drivers
    # in use alone count against it.
    test "checked-in drivers of another key make no room while drivers in use fill workers" do
      put_workers(4)
      other = opts(isolate: true, on_start: {__MODULE__, :on_start, [self()]})
      ms = for _ <- 1..3, do: module()

      for m <- ms do
        browser(m, other)
        run_test(m, [passed()], :shutdown)
      end

      for m <- ms, do: Pool.module_finished(m.playwright_ex_module)
      put_workers(2)

      opts = opts(isolate: true)
      [mn, mo, mp] = for _ <- 1..3, do: module()
      a = browser(mn, opts)
      _b = browser(mo, opts)
      c = Task.async(fn -> browser(mp, opts) end)
      assert Task.yield(c, 1_000) == nil

      run_test(mn, [passed()], :shutdown)
      Pool.module_finished(mn.playwright_ex_module)
      assert Task.await(c) == a
      for m <- [mo, mp], do: run_test(m, [], :boom) && Pool.module_finished(m.playwright_ex_module)
    end

    test "a stopping driver counts toward workers: the next starts once it exited" do
      put_workers(1)
      [ma, mb] = [module(), module()]
      browser(ma, opts(isolate: true))
      run_test(ma, [passed()], :shutdown)
      Pool.module_finished(ma.playwright_ex_module)
      [{stopping, _key}] = :sys.get_state(Pool).free

      # Holds the slot, so its stop waits, until released.
      test_pid = self()

      hold = fn state ->
        send(test_pid, :held)
        receive(do: (:release -> state))
      end

      spawn(fn -> :sys.replace_state(stopping, hold) end)
      assert_receive :held

      other = Keyword.put(opts(isolate: true), :driver, env: [{"PW_POOL_TEST", "other key"}])
      b = Task.async(fn -> browser(mb, other) end)
      assert Task.yield(b, 500) == nil
      send(stopping, :release)
      Task.await(b, 30_000)
      refute Process.alive?(stopping)
      run_test(mb, [], :boom)
      Pool.module_finished(mb.playwright_ex_module)
    end

    test "a waiter for room does not block one after it whose key has a checked-in driver" do
      opts = opts(isolate: true)
      key = &Keyword.put(opts(isolate: true), :driver, env: [{"PW_POOL_TEST", &1}])
      [ha, hb, full, ready] = for _ <- 1..4, do: module()
      a = browser(ha, opts)
      browser(hb, key.("b"))
      # Over workers: hb holds a driver already.
      browser(hb, key.("b2"))

      full_waiter = Task.async(fn -> browser(full, key.("full")) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 1 end)
      ready_waiter = Task.async(fn -> browser(ready, opts) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 2 end)

      run_test(ha, [passed()], :shutdown)
      Pool.module_finished(ha.playwright_ex_module)
      assert Task.await(ready_waiter) == a
      assert Task.yield(full_waiter, 200) == nil

      run_test(hb, [], :boom)
      Pool.module_finished(hb.playwright_ex_module)
      Task.await(full_waiter, 30_000)
      for m <- [full, ready], do: run_test(m, [], :boom) && Pool.module_finished(m.playwright_ex_module)
    end

    test "a module's driver is checked in only if a test of it ran and all passed" do
      opts = opts(isolate: true)
      # No test ran (a raising setup_all, all skipped), or one did not pass (a doctest's).
      [none, unknown] = [module(), module()]
      a = browser(none, opts)
      b = browser(unknown, opts)
      run_test(unknown, [passed()], :shutdown)
      run_test(unknown, [], :shutdown, marked: false)
      for m <- [none, unknown], do: Pool.module_finished(m.playwright_ex_module)
      assert gone?(a.browser) and gone?(b.browser)
    end

    test "a waiter that exits, or whose module ended, is dropped: no slot leaks" do
      put_workers(1)
      opts = opts(isolate: true)
      [holder, killed, ended, next] = for _ <- 1..4, do: module()
      a = browser(holder, opts)

      # Killed while waiting, as by its test's timeout.
      waiter = spawn(fn -> browser(killed, opts) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 1 end)
      Process.exit(waiter, :kill)
      ended_waiter = Task.async(fn -> catch_error(browser(ended, opts)) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 1 end)
      Pool.module_finished(ended.playwright_ex_module)
      assert %ArgumentError{message: "browser/1 after the end of its module"} = Task.await(ended_waiter)

      run_test(holder, [passed()], :shutdown)
      Pool.module_finished(holder.playwright_ex_module)
      assert browser(next, opts) == a
      refute Map.has_key?(:sys.get_state(Pool).busy, killed.playwright_ex_module)
      for m <- [killed, next], do: Pool.module_finished(m.playwright_ex_module)
    end

    test "a module that holds a driver takes its next driver key over workers, not waiting" do
      put_workers(1)
      m = module()
      a = browser(m, opts(isolate: true))
      b = browser(m, Keyword.put(opts(isolate: true), :driver, env: [{"PW_POOL_TEST", "next key"}]))
      assert a.playwright != b.playwright
      Pool.module_finished(m.playwright_ex_module)
    end

    test "a checked-in module's extra browsers are closed" do
      opts = opts(isolate: true)
      [me, mf] = [module(), module()]
      a = browser(me, opts)
      extra = PlaywrightEx.BrowserType.launch!(PlaywrightEx.Browser.browser_type(a.browser))
      run_test(me, [passed()], :shutdown)
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
