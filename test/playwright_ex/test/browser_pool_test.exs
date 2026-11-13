defmodule PlaywrightEx.Test.BrowserPoolTest do
  # Sets `workers` and stops every driver of `PlaywrightEx.Test.BrowserPool` (`after_suite`):
  # not async, so it runs alone, after the async modules. The sync modules after it get new
  # drivers on their first call.
  use ExUnit.Case, async: false
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Options
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Results
  alias PlaywrightEx.Test.TestInfo

  # A worker of this module's (no other module passes this `env`), of each call's options
  # (`launch_options` no other call passes).
  defp opts(extra \\ []) do
    [driver: [env: [{"PW_POOL_TEST", "1"}]], launch_options: [timeout: 40_000 + System.unique_integer([:positive])]] ++
      extra
  end

  defp key(extra), do: Keyword.put(opts(), :driver, env: [{"PW_POOL_TEST", extra}])

  # A test process of its own, watched as the `test` macro's, which ends when sent
  # `{:end, messages, reason}`: `messages` of its pid (`&{:passed, &1}`), then exit `reason`.
  # Released at the test's end, also when the test fails before its `finish/3`.
  defp fake_test(marked \\ Results.outside()) do
    pid =
      spawn(fn ->
        receive do
          {:end, messages, reason} ->
            for message <- messages, do: Results.notify(message.(self()))
            exit(reason)
        end
      end)

    Results.watch(pid, marked)
    on_exit(fn -> Pool.release(pid) end)
    pid
  end

  # Ends the fake test: its result.
  defp end_test(pid, messages, reason) do
    send(pid, {:end, messages, reason})
    Results.result(pid, 5000)
  end

  defp run_test(messages, reason, marked \\ Results.outside()), do: end_test(fake_test(marked), messages, reason)

  # A browser of the fake test `pid`, and its end and release.
  defp lease(pid, opts), do: Pool.browser(Options.pool(opts), {:test, pid})

  defp finish(pid, messages, reason) do
    end_test(pid, messages, reason)
    Pool.release(pid)
  end

  defp passed, do: &{:passed, &1}

  def on_start(playwright, test_pid) do
    send(test_pid, {:on_start, playwright})
    :ok
  end

  # Runs in the slot: its links are the pool and the driver's supervisor.
  def raise_on_start(playwright, test_pid) do
    {:links, links} = Process.info(self(), :links)
    send(test_pid, {:drivers, links -- [Process.whereis(Pool)], playwright})
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

  describe "drivers" do
    test "a scope's concurrent callers get one browser, launched once, after on_start" do
      opts = opts(on_start: {__MODULE__, :on_start, [self()]})
      t = fake_test()
      results = 1..5 |> Enum.map(fn _ -> Task.async(fn -> lease(t, opts) end) end) |> Task.await_many(30_000)

      assert [%{browser: browser, playwright: playwright}] = Enum.uniq(results)
      assert Browser.is_connected(browser)
      assert BrowserPool.playwright(browser) == playwright
      assert_received {:on_start, ^playwright}
      refute_received {:on_start, _}
      finish(t, [], :boom)
    end

    test "an on_start that raises leaves no driver running, nor its row" do
      opts = opts(on_start: {__MODULE__, :raise_on_start, [self()]})
      t = fake_test()
      assert_raise RuntimeError, "on_start failed", fn -> lease(t, opts) end
      assert_received {:drivers, [sup], playwright}
      refute Process.alive?(sup)
      assert :ets.lookup(Results.table(), {:driver, playwright.conn}) == []
      finish(t, [], :boom)
    end

    test "a lost browser is launched again" do
      opts = opts()
      t = fake_test()
      %{browser: browser} = lease(t, opts)
      Browser.close!(browser)
      %{browser: again} = lease(t, opts)
      assert again != browser
      assert Browser.is_connected(again)
      finish(t, [], :boom)
    end

    test "on_start runs again on a driver its supervisor restarted" do
      opts = opts(on_start: {__MODULE__, :on_start, [self()]})
      t = fake_test()
      %{browser: browser, playwright: playwright} = lease(t, opts)
      assert_received {:on_start, ^playwright}

      # kill -9 of the driver: its connection goes, the supervisor starts a new one.
      %{port: port} = :sys.get_state(PlaywrightEx.Runtime.Heap.get(playwright, :driverProcess))
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      ref = Process.monitor(playwright.conn)
      {_, 0} = System.cmd("kill", ["-9", to_string(os_pid)])
      assert_receive {:DOWN, ^ref, :process, _, _}, 10_000

      %{browser: relaunched, playwright: again} = lease(t, opts)
      assert again != playwright
      assert_received {:on_start, ^again}
      assert relaunched != browser
      assert Browser.is_connected(relaunched)
      finish(t, [], :boom)
    end

    test "playwright raises for a browser the pool didn't launch" do
      name = :"#{inspect(__MODULE__)}.own"
      start_supervised!({PlaywrightEx.Supervisor, name: name})
      browser = PlaywrightEx.BrowserType.launch!(PlaywrightEx.TestBrowser.browser_type(PlaywrightEx.playwright(name)))

      assert_raise ArgumentError, ~r/not a browser of PlaywrightEx.Test.BrowserPool/, fn ->
        BrowserPool.playwright(browser)
      end
    end

    test "unknown options and bad values raise" do
      assert_raise ArgumentError, ~r/unknown options \[:headless\]/, fn -> BrowserPool.browser(headless: true) end

      assert_raise ArgumentError, ~r/invalid browser_name: :chrome/, fn ->
        BrowserPool.browser(browser_name: :chrome)
      end
    end
  end

  describe "results" do
    test "passed: the body's end marked, then the process ended as ExUnit ends a test" do
      assert run_test([passed()], :shutdown) == {:passed, []}
    end

    test "failed: an error the test macro caught, or the setup's" do
      failure = {:error, %RuntimeError{message: "boom"}, []}
      assert run_test([&{:failed, &1, failure}], :shutdown) == {:failed, [failure]}
      assert run_test([], :shutdown) == {:failed, [Results.outside()]}
    end

    test "failed: killed (past its timeout), or taken down by a linked process" do
      assert run_test([], :killed) == {:failed, [Results.killed()]}
      assert {:failed, [{{:EXIT, _pid}, {:boom, []}, []}]} = run_test([passed()], {:boom, []})
    end

    test "killed after a soft error: the error its body's end did not take, then the kill; no rows left" do
      error = {:error, %RuntimeError{message: "soft"}, []}
      test_info = TestInfo.current()

      pid =
        spawn(fn ->
          this = %{test_info | test_pid: self()}
          :ets.insert(Results.table(), {{:test_info, self(), :info}, this})
          TestInfo._fail_with_error(this, error)
          Process.sleep(:infinity)
        end)
        |> tap(&Results.watch(&1, Results.outside()))

      wait_until(fn -> :ets.match_object(Results.table(), {{:test_info, pid, {:error, :_}}, :_}) != [] end)
      Process.exit(pid, :kill)
      assert Results.result(pid, 5000) == {:failed, [error, Results.killed()]}
      assert :ets.match_object(Results.table(), {{:test_info, pid, :_}, :_}) == []
    end

    test "unknown for a test of another macro (a doctest), unless its process crashed" do
      assert run_test([], :shutdown, false) == {nil, []}
      assert {:failed, [_]} = run_test([], :boom, false)
      assert Results.result(spawn(fn -> :ok end), 100) == {nil, []}
    end

    test "a finish killed past ExUnit's timeout releases the test's seat as it exits, reset" do
      t = fake_test()
      %{playwright: playwright} = lease(t, opts())
      [seat] = for {pid, %{scope: ^t}} <- :sys.get_state(Pool).seats, do: pid

      # It waits for the result of `t`, which runs on, until ExUnit kills it.
      finisher = spawn(fn -> PlaywrightEx.Test.__finish__(t, :infinity) end)
      wait_until(fn -> match?({:current_function, {:gen, :do_call, 4}}, Process.info(finisher, :current_function)) end)
      Process.exit(finisher, :kill)

      wait_until(fn -> not Map.has_key?(:sys.get_state(Pool).scopes, t) end)
      assert %{scope: nil, key: nil} = :sys.get_state(Pool).seats[seat]
      wait_until(fn -> :ets.lookup(Results.table(), {:driver, playwright.conn}) == [] end)
      finish(t, [], :boom)
    end

    test "forgotten once the test's on_exit took it" do
      pid = fake_test()
      assert end_test(pid, [passed()], :shutdown) == {:passed, []}
      Results.forget(pid)
      assert Results.result(pid, 100) == {nil, []}
    end
  end

  # `workers` for the test (the idle seats of the modules before it restart, or are trimmed at a
  # release).
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

    test "at most workers drivers at once, waiters first come first served; a passing scope's goes back warm, a failed one's stops" do
      opts = opts()
      [ta, tb, tc, td] = for _ <- 1..4, do: fake_test()
      a = lease(ta, opts)
      b = lease(tb, opts)
      assert a.playwright != b.playwright

      c = Task.async(fn -> lease(tc, opts) end)
      assert Task.yield(c, 1_000) == nil

      # Passed: the next waiter gets the same driver and browser.
      finish(ta, [passed()], :shutdown)
      assert Task.await(c) == a

      # Failed: its driver stops, the next scope gets a new one.
      finish(tb, [], :boom)
      d = lease(td, opts)
      assert d.playwright not in [a.playwright, b.playwright]
      assert gone?(b.browser)

      for t <- [tc, td], do: finish(t, [], :boom)
    end

    test "a repeated call returns the scope's browser; other browser options get another worker" do
      put_workers(1)
      opts = opts()
      [t, next] = [fake_test(), fake_test()]
      a = lease(t, opts)
      assert lease(t, opts) == a
      # Other launch options: the browser under test, so CI's one installed browser runs it. Over
      # `workers`: `t` holds a driver already.
      b = lease(t, Keyword.put(opts, :launch_options, opts()[:launch_options]))
      assert a.playwright != b.playwright
      finish(t, [passed()], :shutdown)

      # The seat over `workers` stops at the release, the other restarts for the next options.
      c = lease(next, Keyword.put(opts, :launch_options, opts()[:launch_options]))
      assert c.playwright not in [a.playwright, b.playwright]
      assert gone?(a.browser) and gone?(b.browser)
      finish(next, [], :boom)
    end

    test "at the cap, a new key restarts the longest idle seat of another key" do
      put_workers(2)
      [t1, t2] = for _ <- 1..2, do: fake_test()
      one = lease(t1, key("one"))
      two = lease(t2, key("two"))
      finish(t1, [passed()], :shutdown)
      finish(t2, [passed()], :shutdown)

      t3 = fake_test()
      three = lease(t3, key("three"))
      # `one` was idle longest.
      assert gone?(one.browser)
      assert connected?(two.browser)
      finish(t3, [], :boom)
      assert gone?(three.browser)
    end

    test "idle seats of another key make no room while held seats fill workers" do
      put_workers(4)
      other = opts(on_start: {__MODULE__, :on_start, [self()]})
      ts = for _ <- 1..3, do: fake_test()
      for t <- ts, do: lease(t, other)
      for t <- ts, do: finish(t, [passed()], :shutdown)
      put_workers(2)

      opts = opts()
      [tn, to, tp] = for _ <- 1..3, do: fake_test()
      a = lease(tn, opts)
      _b = lease(to, opts)
      c = Task.async(fn -> lease(tp, opts) end)
      assert Task.yield(c, 1_000) == nil

      finish(tn, [passed()], :shutdown)
      assert Task.await(c) == a
      for t <- [to, tp], do: finish(t, [], :boom)
    end

    test "a seat of another key restarts in place, inside the lease: its old driver exited first" do
      put_workers(1)
      [ta, tb] = [fake_test(), fake_test()]
      a = lease(ta, opts())
      %{port: port} = :sys.get_state(PlaywrightEx.Runtime.Heap.get(a.playwright, :driverProcess))
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      finish(ta, [passed()], :shutdown)

      b = lease(tb, key("other key"))
      assert b.playwright != a.playwright
      assert {_, 1} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
      finish(tb, [], :boom)
    end

    test "waiters are served first come first served, also when a later one's key is idle" do
      put_workers(1)
      opts = opts()
      [holder, first, second] = for _ <- 1..3, do: fake_test()
      a = lease(holder, opts)
      first_waiter = Task.async(fn -> lease(first, key("first")) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 1 end)
      second_waiter = Task.async(fn -> lease(second, opts) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 2 end)

      # The first waiter takes the seat, restarted for its key; the second waits on.
      finish(holder, [passed()], :shutdown)
      assert Task.await(first_waiter, 30_000).playwright != a.playwright
      assert Task.yield(second_waiter, 200) == nil

      finish(first, [passed()], :shutdown)
      Task.await(second_waiter, 30_000)
      finish(second, [], :boom)
    end

    test "a scope with no known result (a doctest's, an unregistered test's) goes back warm; a crash stops it" do
      opts = opts()
      [unknown, unwatched, crashed] = [fake_test(false), spawn(fn -> :ok end), fake_test(false)]
      a = lease(unknown, opts)
      b = lease(unwatched, opts)
      finish(unknown, [], :shutdown)
      Pool.release(unwatched)

      # Both back, warm: the next scopes get them.
      next = fake_test()
      c = lease(crashed, opts)
      assert MapSet.new([lease(next, opts), c]) == MapSet.new([a, b])
      finish(crashed, [], :boom)
      assert gone?(c.browser)
      finish(next, [], :boom)
    end

    test "a waiter that exits, or whose scope was released, is dropped: no driver leaks" do
      put_workers(1)
      opts = opts()
      [holder, killed, released, next] = for _ <- 1..4, do: fake_test()
      a = lease(holder, opts)

      # Killed while waiting, as by its test's timeout.
      waiter = spawn(fn -> lease(killed, opts) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 1 end)
      Process.exit(waiter, :kill)
      released_waiter = Task.async(fn -> catch_error(lease(released, opts)) end)
      # The kill is async: wait until the killed waiter is gone and this one is queued.
      wait_until(fn -> Enum.map(:sys.get_state(Pool).waiting, & &1.scope) == [released] end)
      Pool.release(released)

      assert %ArgumentError{message: "BrowserPool.browser/1 waited past the end of its test or module"} =
               Task.await(released_waiter)

      finish(holder, [passed()], :shutdown)
      assert lease(next, opts) == a
      finish(next, [], :boom)
    end

    test "another scope (a setup_all's) passes when a test of its runner ran and all passed" do
      opts = Options.pool(opts())
      # A `setup_all` process and tests, all spawned by one runner (this process).
      scope = fn -> spawn(fn -> Process.sleep(:infinity) end) end

      none = scope.()
      a = Pool.browser(opts, {:process, none})
      # No test ran: no known result, back warm.
      Pool.release(none)

      passing = scope.()
      assert (b = Pool.browser(opts, {:process, passing})) == a
      assert run_test([passed()], :shutdown) == {:passed, []}
      assert run_test([passed()], :shutdown) == {:passed, []}
      Pool.release(passing)

      failing = scope.()
      assert Pool.browser(opts, {:process, failing}) == b
      assert run_test([passed()], :shutdown) == {:passed, []}
      assert {:failed, _} = run_test([], :boom)
      Pool.release(failing)
      assert gone?(b.browser)
    end
  end

  test "after_suite waits for the drivers being stopped" do
    t = fake_test()
    stopped = lease(t, opts())
    finish(t, [], :boom)
    Pool.after_suite(%{})
    refute connected?(stopped.browser)
  end

  test "after_suite stops every driver" do
    [free, held] = [fake_test(), fake_test()]
    one = lease(free, opts())
    finish(free, [passed()], :shutdown)
    two = lease(held, key("held"))

    Pool.after_suite(%{})
    refute connected?(one.browser) or connected?(two.browser)

    # The next use starts anew.
    next = fake_test()
    assert Browser.is_connected(lease(next, opts()).browser)
    finish(next, [], :boom)
  end
end
