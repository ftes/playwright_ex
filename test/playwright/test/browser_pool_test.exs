defmodule Playwright.Test.BrowserPoolTest do
  # Sets `workers` and stops every driver of `Playwright.Test.BrowserPool` (`after_suite`):
  # not async, so it runs alone, after the async modules. The sync modules after it get new
  # drivers on their first call.
  use ExUnit.Case, async: false
  use Playwright.Test

  alias Playwright.Browser
  alias Playwright.Test.BrowserPool
  alias Playwright.Test.Options
  alias Playwright.Test.Pool
  alias Playwright.Test.Results
  alias Playwright.Test.SetupAllTimeout
  alias Playwright.Test.TestInfo

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
  defp hold(pid, opts), do: Pool.browser(Options.pool(opts), {:test, pid})

  defp finish(pid, messages, reason) do
    end_test(pid, messages, reason)
    Pool.release(pid)
  end

  defp passed, do: &{:passed, &1}

  # A fake test that holds a browser of `opts` and passes.
  defp finish_held(opts) do
    t = fake_test()
    hold(t, opts)
    finish(t, [passed()], :shutdown)
  end

  # The same, its browser.
  defp finish_held_browser(opts) do
    t = fake_test()
    held = hold(t, opts)
    finish(t, [passed()], :shutdown)
    held
  end

  def on_start(playwright, test_pid) do
    send(test_pid, {:on_start, playwright})
    :ok
  end

  # Runs in the worker: its links are the pool and the driver's supervisor.
  def raise_on_start(playwright, test_pid) do
    {:links, links} = Process.info(self(), :links)
    send(test_pid, {:drivers, links -- [Process.whereis(Pool)], playwright})
    raise "on_start failed"
  end

  # A stopped driver's handles may be unreadable (TargetClosedError).
  defp connected?(browser) do
    Browser.is_connected(browser)
  rescue
    Playwright.TargetClosedError -> false
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
      results = 1..5 |> Enum.map(fn _ -> Task.async(fn -> hold(t, opts) end) end) |> Task.await_many(30_000)

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
      assert_raise RuntimeError, "on_start failed", fn -> hold(t, opts) end
      assert_received {:drivers, [sup], playwright}
      refute Process.alive?(sup)
      assert :ets.lookup(Results.table(), {:driver, playwright.conn}) == []
      finish(t, [], :boom)
    end

    test "a lost browser is launched again" do
      opts = opts()
      t = fake_test()
      %{browser: browser} = hold(t, opts)
      Browser.close!(browser)
      %{browser: again} = hold(t, opts)
      assert again != browser
      assert Browser.is_connected(again)
      finish(t, [], :boom)
    end

    test "on_start runs again on a driver its supervisor restarted" do
      opts = opts(on_start: {__MODULE__, :on_start, [self()]})
      t = fake_test()
      %{browser: browser, playwright: playwright} = hold(t, opts)
      assert_received {:on_start, ^playwright}

      # kill -9 of the driver: its connection goes, the supervisor starts a new one.
      %{port: port} = :sys.get_state(Playwright.Runtime.Heap.get(playwright, :driverProcess))
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      ref = Process.monitor(playwright.conn)
      {_, 0} = System.cmd("kill", ["-9", to_string(os_pid)])
      assert_receive {:DOWN, ^ref, :process, _, _}, 10_000

      %{browser: relaunched, playwright: again} = hold(t, opts)
      assert again != playwright
      assert_received {:on_start, ^again}
      assert relaunched != browser
      assert Browser.is_connected(relaunched)
      finish(t, [], :boom)
    end

    test "playwright raises for a browser the pool didn't launch" do
      name = :"#{inspect(__MODULE__)}.own"
      start_supervised!({Playwright.Supervisor, name: name})
      browser = Playwright.BrowserType.launch!(Playwright.TestBrowser.browser_type(Playwright.instance(name)))

      assert_raise ArgumentError, ~r/^Playwright.Test.BrowserPool.playwright\/1: not a pooled browser, got: /, fn ->
        BrowserPool.playwright(browser)
      end
    end

    test "unknown options and bad values raise" do
      assert_raise ArgumentError, ~r/unknown option slow_mo, /, fn ->
        BrowserPool.browser(slow_mo: 1)
      end

      assert_raise ArgumentError, ~r/invalid value :chrome for browser_name, /, fn ->
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

    test "a finish killed past ExUnit's timeout releases the test's worker as it exits, reset" do
      t = fake_test()
      %{playwright: playwright} = hold(t, opts())
      [worker] = for {pid, %{scope: ^t}} <- :sys.get_state(Pool).workers, do: pid

      # It waits for the result of `t`, which runs on, until ExUnit kills it.
      finisher = spawn(fn -> Playwright.Test.__finish__(t, :infinity) end)
      wait_until(fn -> match?({:current_function, {:gen, :do_call, 4}}, Process.info(finisher, :current_function)) end)
      Process.exit(finisher, :kill)

      wait_until(fn -> not Map.has_key?(:sys.get_state(Pool).scopes, t) end)
      assert %{scope: nil, key: nil} = :sys.get_state(Pool).workers[worker]
      wait_until(fn -> :ets.lookup(Results.table(), {:driver, playwright.conn}) == [] end)
      finish(t, [], :boom)
    end

    test "a finish past its budget resets the test's worker, and kills a recorder that doesn't answer" do
      t = fake_test()
      hold(t, opts())
      [worker] = for {pid, %{scope: ^t}} <- :sys.get_state(Pool).workers, do: pid

      Playwright.Test.__register__(
        Map.merge(Map.new(Playwright.Test.use(trace: :on)), %{
          test_pid: t,
          module: __MODULE__,
          test: :"test abandoned",
          file: __ENV__.file,
          line: 1,
          "playwright.test": :marked
        })
      )

      # A recorder that is blocked: the finish's budget runs out waiting for it.
      recorder = Results.recorder(t)
      ref = Process.monitor(recorder)
      :sys.suspend(recorder)
      assert end_test(t, [passed()], :shutdown) == {:passed, []}
      Playwright.Test.__finish__(t, 100)

      # Its contexts may be left open: the worker resets, though the test passed.
      assert %{scope: nil, key: nil} = :sys.get_state(Pool).workers[worker]
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 10_000
    end

    # `Playwright.Test.on_exit/2`'s `{:failed_in_teardown, pid, failure}`, from the process that
    # runs the test's `on_exit` callbacks (here a Task).
    test "an on_exit callback's failure fails a passed test and resets its worker; not once its finish began" do
      failure = {:error, %RuntimeError{message: "teardown boom"}, []}

      for finishing? <- [false, true] do
        t = fake_test()
        hold(t, opts())
        [worker] = for {pid, %{scope: ^t}} <- :sys.get_state(Pool).workers, do: pid
        assert end_test(t, [passed()], :shutdown) == {:passed, []}

        result =
          Task.await(
            Task.async(fn ->
              if finishing?, do: Results.finishing(t)
              Results.notify({:failed_in_teardown, t, failure})
              result = Results.result(t, 5000)
              Pool.release(t)
              result
            end)
          )

        %{scope: nil, key: key} = :sys.get_state(Pool).workers[worker]

        if finishing? do
          assert result == {:passed, []}
          assert key != nil
        else
          assert {:failed, [{:error, %RuntimeError{message: "teardown boom"}, []}]} = result
          assert key == nil
        end
      end
    end

    test "an on_exit callback's failure of a process that is no test (a setup_all) fails nothing" do
      opts = opts()
      test = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(test, {:held, Pool.browser(Options.pool(opts), {:process, self()})})
          receive do: (:end -> :ok)
        end)

      assert_receive {:held, held}, 30_000
      Results.notify({:failed_in_teardown, pid, {:error, %RuntimeError{message: "teardown boom"}, []}})
      refute :sys.get_state(Pool).scopes[pid].failed?
      send(pid, :end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
      Pool.release(pid)

      t = fake_test()
      assert hold(t, opts).playwright == held.playwright
      finish(t, [passed()], :shutdown)
    end

    test "forgotten once the test's on_exit took it" do
      pid = fake_test()
      assert end_test(pid, [passed()], :shutdown) == {:passed, []}
      Results.forget(pid)
      assert Results.result(pid, 100) == {nil, []}
    end
  end

  describe "setup_all" do
    # A registered `setup_all` scope's process (`use Playwright.Test`'s), as ExUnit's: its
    # callbacks, `failed` after a hold of `opts` and a context on it, their error caught, then the
    # wait for the module's end. Its `on_exit` release, after it exited (the real one: the
    # `modules` mode of `Playwright.Test.EndToEndTest`).
    defp failed_setup_all(opts, failed) do
      test = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Playwright.Test.__setup_all__(%{})

          try do
            SetupAllTimeout.run(%{module: __MODULE__, timeout: 3000}, fn ->
              %{browser: browser} = held = Pool.browser(Options.pool(opts), {:process, self()})
              Browser.new_context!(browser)
              send(test, {:held, held})
              fail(failed)
            end)
          catch
            _kind, _reason -> :ok
          end

          receive do: (:module_end -> :ok)
        end)

      assert_receive {:held, held}, 30_000
      send(pid, :module_end)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000
      Pool.release(pid)
      held
    end

    # Raised: ExUnit catches it, the process exits normally.
    defp fail(:raised), do: raise("boom")
    defp fail(:timed_out), do: Process.sleep(:infinity)

    # Taken down by a linked process, also one that stops as a `GenServer` does when shut down.
    defp fail(:linked_crash) do
      spawn_link(fn -> exit(:boom) end)
      Process.sleep(:infinity)
    end

    defp fail(:linked_shutdown) do
      spawn_link(fn -> exit({:shutdown, :closed}) end)
      Process.sleep(:infinity)
    end

    # Past the timeout: none under `mix test --trace`.
    for failed <- [
          :raised,
          :linked_crash,
          :linked_shutdown | if(ExUnit.configuration()[:trace], do: [], else: [:timed_out])
        ] do
      @tag :capture_log
      test "a #{failed} setup_all resets its worker: the next scope of its options gets a fresh browser, without its contexts" do
        opts = opts()
        warm = finish_held_browser(opts)
        held = failed_setup_all(opts, unquote(failed))
        assert held.playwright == warm.playwright

        t = fake_test()
        fresh = hold(t, opts)
        assert fresh.playwright != warm.playwright
        assert Browser.contexts(fresh.browser) == []
        assert gone?(warm.browser)
        finish(t, [passed()], :shutdown)
      end
    end

    @tag :capture_log
    test "an unregistered setup_all's (a plain ExUnit module's) failure is not its worker's" do
      opts = opts()
      test = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(test, {:held, Pool.browser(Options.pool(opts), {:process, self()})})
          exit(:boom)
        end)

      assert_receive {:held, held}, 30_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}, 10_000
      Pool.release(pid)

      t = fake_test()
      assert hold(t, opts).playwright == held.playwright
      finish(t, [passed()], :shutdown)
    end

    test "a passed setup_all's worker goes back warm" do
      opts = opts()
      test = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Playwright.Test.__setup_all__(%{})

          SetupAllTimeout.run(%{module: __MODULE__, timeout: :infinity}, fn ->
            send(test, {:held, Pool.browser(Options.pool(opts), {:process, self()})})
          end)

          receive do: (:module_end -> :ok)
        end)

      assert_receive {:held, held}, 30_000
      send(pid, :module_end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
      Pool.release(pid)

      t = fake_test()
      assert hold(t, opts).playwright == held.playwright
      finish(t, [passed()], :shutdown)
    end
  end

  # `workers` for the test (the idle workers of the modules before it restart, or are trimmed at a
  # release).
  defp put_workers(workers) do
    config = Application.get_env(:playwright, :test)
    Application.put_env(:playwright, :test, Keyword.put(config, :workers, workers))
  end

  describe "workers" do
    setup do
      config = Application.get_env(:playwright, :test)
      put_workers(2)

      on_exit(fn -> Application.put_env(:playwright, :test, config) end)
    end

    test "read once per config, not on each hold and release" do
      opts = opts()
      # `call_count` counts the calls of the processes with the `call` flag: the pool's.
      :erlang.trace(Process.whereis(Pool), true, [:call, tracer: self()])
      :erlang.trace_pattern({Options, :workers, 0}, true, [:call_count])

      try do
        for _ <- 1..3, do: finish_held(opts)
        assert {:call_count, 1} = :erlang.trace_info({Options, :workers, 0}, :call_count)
        put_workers(1)
        finish_held(opts)
        assert {:call_count, 2} = :erlang.trace_info({Options, :workers, 0}, :call_count)
      after
        :erlang.trace_pattern({Options, :workers, 0}, false, [:call_count])
        :erlang.trace(Process.whereis(Pool), false, [:call])
      end
    end

    test "at most workers drivers at once, waiters first come first served; a passing scope's goes back warm, a failed one's stops" do
      opts = opts()
      [ta, tb, tc, td] = for _ <- 1..4, do: fake_test()
      a = hold(ta, opts)
      b = hold(tb, opts)
      assert a.playwright != b.playwright

      c = Task.async(fn -> hold(tc, opts) end)
      assert Task.yield(c, 1_000) == nil

      # Passed: the next waiter gets the same driver and browser.
      finish(ta, [passed()], :shutdown)
      assert Task.await(c) == a

      # Failed: its driver stops, the next scope gets a new one.
      finish(tb, [], :boom)
      d = hold(td, opts)
      assert d.playwright not in [a.playwright, b.playwright]
      assert gone?(b.browser)

      for t <- [tc, td], do: finish(t, [], :boom)
    end

    test "a repeated call returns the scope's browser; other browser options get another worker" do
      put_workers(1)
      opts = opts()
      [t, next] = [fake_test(), fake_test()]
      a = hold(t, opts)
      assert hold(t, opts) == a
      # Other launch options: the browser under test, so CI's one installed browser runs it. Over
      # `workers`: `t` holds a driver already.
      b = hold(t, Keyword.put(opts, :launch_options, opts()[:launch_options]))
      assert a.playwright != b.playwright
      finish(t, [passed()], :shutdown)

      # The worker over `workers` stops at the release, the other restarts for the next options.
      c = hold(next, Keyword.put(opts, :launch_options, opts()[:launch_options]))
      assert c.playwright not in [a.playwright, b.playwright]
      assert gone?(a.browser) and gone?(b.browser)
      finish(next, [], :boom)
    end

    test "at the cap, a new key restarts the longest idle worker of another key" do
      put_workers(2)
      [t1, t2] = for _ <- 1..2, do: fake_test()
      one = hold(t1, key("one"))
      two = hold(t2, key("two"))
      finish(t1, [passed()], :shutdown)
      finish(t2, [passed()], :shutdown)

      t3 = fake_test()
      three = hold(t3, key("three"))
      # `one` was idle longest.
      assert gone?(one.browser)
      assert connected?(two.browser)
      finish(t3, [], :boom)
      assert gone?(three.browser)
    end

    test "idle workers of another key make no room while held workers fill the cap" do
      put_workers(4)
      other = opts(on_start: {__MODULE__, :on_start, [self()]})
      ts = for _ <- 1..3, do: fake_test()
      for t <- ts, do: hold(t, other)
      for t <- ts, do: finish(t, [passed()], :shutdown)
      put_workers(2)

      opts = opts()
      [tn, to, tp] = for _ <- 1..3, do: fake_test()
      a = hold(tn, opts)
      _b = hold(to, opts)
      c = Task.async(fn -> hold(tp, opts) end)
      assert Task.yield(c, 1_000) == nil

      finish(tn, [passed()], :shutdown)
      assert Task.await(c) == a
      for t <- [to, tp], do: finish(t, [], :boom)
    end

    test "a worker of another key restarts in place, inside the hold: its old driver exited first" do
      put_workers(1)
      [ta, tb] = [fake_test(), fake_test()]
      a = hold(ta, opts())
      %{port: port} = :sys.get_state(Playwright.Runtime.Heap.get(a.playwright, :driverProcess))
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      finish(ta, [passed()], :shutdown)

      b = hold(tb, key("other key"))
      assert b.playwright != a.playwright
      assert {_, 1} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
      finish(tb, [], :boom)
    end

    test "waiters are served first come first served, also when a later one's key is idle" do
      put_workers(1)
      opts = opts()
      [holder, first, second] = for _ <- 1..3, do: fake_test()
      a = hold(holder, opts)
      first_waiter = Task.async(fn -> hold(first, key("first")) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 1 end)
      second_waiter = Task.async(fn -> hold(second, opts) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 2 end)

      # The first waiter takes the worker, restarted for its key; the second waits on.
      finish(holder, [passed()], :shutdown)
      assert Task.await(first_waiter, 30_000).playwright != a.playwright
      assert Task.yield(second_waiter, 200) == nil

      finish(first, [passed()], :shutdown)
      Task.await(second_waiter, 30_000)
      finish(second, [], :boom)
    end

    test "a waiter whose scope got a worker while it waited is served, also behind a scope that waits on" do
      put_workers(1)
      opts = opts()
      [holder, t, u] = for _ <- 1..3, do: fake_test()
      a = hold(holder, opts)
      waiting = fn n -> wait_until(fn -> length(:sys.get_state(Pool).waiting) == n end) end
      t_first = Task.async(fn -> hold(t, opts) end)
      waiting.(1)
      u_waiter = Task.async(fn -> hold(u, opts) end)
      waiting.(2)
      t_second = Task.async(fn -> hold(t, opts) end)
      waiting.(3)

      # `t`'s first call takes the worker, so its second is a repeated call: not left behind `u`,
      # which waits for `t`.
      finish(holder, [passed()], :shutdown)
      assert Task.await(t_first, 30_000) == a
      assert Task.yield(t_second, 1_000) == {:ok, a}
      assert Task.yield(u_waiter, 200) == nil

      finish(t, [passed()], :shutdown)
      assert Task.await(u_waiter, 30_000) == a
      finish(u, [], :boom)
    end

    test "a scope with no known result (a doctest's, an unregistered test's) goes back warm; a crash stops it" do
      opts = opts()
      [unknown, unwatched, crashed] = [fake_test(false), spawn(fn -> :ok end), fake_test(false)]
      a = hold(unknown, opts)
      b = hold(unwatched, opts)
      finish(unknown, [], :shutdown)
      Pool.release(unwatched)

      # Both back, warm: the next scopes get them.
      next = fake_test()
      c = hold(crashed, opts)
      assert MapSet.new([hold(next, opts), c]) == MapSet.new([a, b])
      finish(crashed, [], :boom)
      assert gone?(c.browser)
      finish(next, [], :boom)
    end

    test "a waiter that exits, or whose scope was released, is dropped: no driver leaks" do
      put_workers(1)
      opts = opts()
      [holder, killed, released, next] = for _ <- 1..4, do: fake_test()
      a = hold(holder, opts)

      # Killed while waiting, as by its test's timeout.
      waiter = spawn(fn -> hold(killed, opts) end)
      wait_until(fn -> length(:sys.get_state(Pool).waiting) == 1 end)
      Process.exit(waiter, :kill)
      released_waiter = Task.async(fn -> catch_error(hold(released, opts)) end)
      # The kill is async: wait until the killed waiter is gone and this one is queued.
      wait_until(fn -> Enum.map(:sys.get_state(Pool).waiting, & &1.scope) == [released] end)
      Pool.release(released)

      assert %RuntimeError{message: "Playwright.Test.BrowserPool.browser/1: waited past the end of its test or module"} =
               Task.await(released_waiter)

      finish(holder, [passed()], :shutdown)
      assert hold(next, opts) == a
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
    stopped = hold(t, opts())
    finish(t, [], :boom)
    Pool.after_suite(%{})
    refute connected?(stopped.browser)
  end

  test "after_suite stops every driver" do
    [free, held] = [fake_test(), fake_test()]
    one = hold(free, opts())
    finish(free, [passed()], :shutdown)
    two = hold(held, key("held"))

    Pool.after_suite(%{})
    refute connected?(one.browser) or connected?(two.browser)

    # The next use starts anew.
    next = fake_test()
    assert Browser.is_connected(hold(next, opts()).browser)
    finish(next, [], :boom)
  end
end
