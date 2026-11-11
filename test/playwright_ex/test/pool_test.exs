defmodule PlaywrightEx.Test.PoolTest do
  # Sets `max_isolated` and stops every driver of `PlaywrightEx.Test` (`after_suite`,
  # `stop_all`): not async, so it runs alone, after the async modules. The sync modules after it
  # get new drivers from their `setup_all`.
  use ExUnit.Case, async: false

  import PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.Pool

  # As ExUnit's `parameterize:` module (its internal config).
  defmodule Parameterized do
    def __ex_unit__(:config), do: %{parameterize: [%{n: 1}, %{n: 2}]}
  end

  # A driver of this module's (no other module passes this `env`) and a browser of each test's
  # (`launch_options` no other test passes).
  defp opts(extra \\ []) do
    [driver: [env: [{"PW_POOL_TEST", "1"}]], launch_options: [timeout: 40_000 + System.unique_integer([:positive])]] ++
      extra
  end

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

  describe "isolate" do
    setup do
      config = Application.get_env(:playwright_ex, :test)
      Application.put_env(:playwright_ex, :test, Keyword.put(config, :max_isolated, 2))
      on_exit(fn -> Application.put_env(:playwright_ex, :test, config) end)
    end

    test "at most max_isolated modules have a driver at once; a failed module's is discarded" do
      opts = opts(isolate: true)
      a = browser(%{module: :module_a}, opts)
      b = browser(%{module: :module_b}, opts)
      assert a.playwright != b.playwright

      c = Task.async(fn -> browser(%{module: :module_c}, opts) end)
      assert Task.yield(c, 1_000) == nil

      # Checked in: the next module gets the same driver and browser.
      Pool.module_finished({:module_a, %{}}, false)
      assert Task.await(c) == a

      # Discarded after a failure: its driver stops, the next module gets a new one.
      Pool.module_finished({:module_b, %{}}, true)
      d = browser(%{module: :module_d}, opts)
      assert d.playwright not in [a.playwright, b.playwright]
      assert gone?(b.browser)

      Pool.module_finished({:module_c, %{}}, true)
      Pool.module_finished({:module_d, %{}}, true)
    end

    # Idle slots above `max_isolated` (the suite's, when this test lowers it): busy slots alone
    # count against it.
    test "idle slots of another key make no room while busy slots fill max_isolated" do
      config = Application.get_env(:playwright_ex, :test)
      Application.put_env(:playwright_ex, :test, Keyword.put(config, :max_isolated, 4))
      other = opts(isolate: true, on_start: {__MODULE__, :on_start, [self()]})
      for m <- [:module_m1, :module_m2, :module_m3], do: browser(%{module: m}, other)
      for m <- [:module_m1, :module_m2, :module_m3], do: Pool.module_finished({m, %{}}, false)
      Application.put_env(:playwright_ex, :test, Keyword.put(config, :max_isolated, 2))

      opts = opts(isolate: true)
      a = browser(%{module: :module_n}, opts)
      _b = browser(%{module: :module_o}, opts)
      c = Task.async(fn -> browser(%{module: :module_p}, opts) end)
      assert Task.yield(c, 1_000) == nil

      Pool.module_finished({:module_n, %{}}, false)
      assert Task.await(c) == a
      for m <- [:module_o, :module_p], do: Pool.module_finished({m, %{}}, true)
    end

    test "a checked-in module's extra browsers are closed" do
      opts = opts(isolate: true)
      a = browser(%{module: :module_e}, opts)
      extra = PlaywrightEx.BrowserType.launch!(PlaywrightEx.Browser.browser_type(a.browser))
      Pool.module_finished({:module_e, %{}}, false)
      assert gone?(extra)
      assert browser(%{module: :module_f}, opts) == a
      assert Browser.is_connected(a.browser)
      Pool.module_finished({:module_f, %{}}, true)
    end

    test "an owner's further browser/2 calls share its driver" do
      opts = opts(isolate: true)
      a = browser(%{module: :module_m}, opts)
      b = browser(%{module: :module_m}, Keyword.put(opts, :browser_name, PlaywrightEx.TestBrowser.other_name()))
      assert a.playwright == b.playwright
      Pool.module_finished({:module_m, %{}}, true)
    end

    test "each parameter map of a parameterize: module is an owner of its own" do
      opts = opts(isolate: true)
      module = __MODULE__.Parameterized
      one = browser(%{module: module, n: 1}, opts)
      two = browser(%{module: module, n: 2}, opts)
      assert one.playwright != two.playwright

      Pool.module_finished({module, %{n: 1}}, true)
      assert gone?(one.browser)
      assert Browser.is_connected(two.browser)
      Pool.module_finished({module, %{n: 2}}, true)
    end

    test "a waiter gets a slot after the wait, logged" do
      opts = opts(isolate: true)
      a = browser(%{module: :module_h}, opts)
      b = browser(%{module: :module_i}, opts)
      c = Task.async(fn -> browser(%{module: :module_j}, opts) end)
      assert Task.yield(c, 500) == nil

      # The wait's timer, fired early.
      %{timer: {ref, _}} = :sys.get_state(Pool)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(Pool, {:waited, ref})
          assert Task.await(c, 30_000).playwright not in [a.playwright, b.playwright]
        end)

      assert log =~ "PlaywrightEx.Test could not get :module_j an isolated driver: none was checked in for 120 s"

      for m <- [:module_h, :module_i, :module_j], do: Pool.module_finished({m, %{}}, true)
    end
  end

  test "after_suite waits for the drivers being discarded" do
    isolated = browser(%{module: :module_l}, opts(isolate: true))
    Pool.module_finished({:module_l, %{}}, true)
    Pool.after_suite(%{})
    refute connected?(isolated.browser)
  end

  test "after_suite stops every driver" do
    %{browser: one} = browser(opts())
    %{browser: two} = browser(opts())
    isolated = browser(%{module: :module_g}, opts(isolate: true))

    Pool.after_suite(%{})
    refute connected?(one) or connected?(two) or connected?(isolated.browser)

    # The next use starts anew.
    assert %{browser: three} = browser(opts())
    assert Browser.is_connected(three)
  end
end
