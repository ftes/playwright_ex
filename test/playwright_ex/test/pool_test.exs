defmodule PlaywrightEx.Test.PoolTest do
  # Sets `max_isolated` and stops every driver of `PlaywrightEx.Test` (`after_suite`).
  use ExUnit.Case, async: false

  import PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.Pool

  # A key of its own: `launch_options` no other test passes.
  defp opts(extra \\ []), do: [launch_options: [timeout: 40_000 + System.unique_integer([:positive])]] ++ extra

  def on_start(playwright, test_pid) do
    send(test_pid, {:on_start, playwright})
    :ok
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

  test "a lost browser is launched again" do
    opts = opts()
    %{browser: browser} = browser(opts)
    Browser.close!(browser)
    %{browser: again} = browser(opts)
    assert again != browser
    assert Browser.is_connected(again)
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

    test "each parameter map of a parameterize: module is an owner of its own" do
      opts = opts(isolate: true)
      module = PlaywrightEx.Test.ParameterizeTest
      one = browser(%{module: module, n: 1}, opts)
      two = browser(%{module: module, n: 2}, opts)
      assert one.playwright != two.playwright

      Pool.module_finished({module, %{n: 1}}, true)
      assert gone?(one.browser)
      assert Browser.is_connected(two.browser)
      Pool.module_finished({module, %{n: 2}}, true)
    end

    test "the wait for a slot starts anew on each check-in" do
      opts = opts(isolate: true)
      a = browser(%{module: :module_h}, opts)
      _b = browser(%{module: :module_i}, opts)
      c = Task.async(fn -> browser(%{module: :module_j}, opts) end)
      d = Task.async(fn -> browser(%{module: :module_k}, opts) end)
      assert Task.yield(c, 500) == nil
      %{timer: {first, _}} = :sys.get_state(Pool)

      # A check-in: c gets a's slot, d waits on a new timer.
      Pool.module_finished({:module_h, %{}}, false)
      assert Task.await(c) == a
      %{timer: {second, _}} = :sys.get_state(Pool)
      assert second != first

      # The old timer is stale; the new one gives d a slot above max_isolated.
      send(Pool, {:waited, first})
      assert Task.yield(d, 500) == nil
      send(Pool, {:waited, second})
      assert Task.await(d, 30_000).playwright not in [a.playwright]
      assert :sys.get_state(Pool).timer == nil

      for m <- [:module_i, :module_j, :module_k], do: Pool.module_finished({m, %{}}, true)
    end
  end

  test "stop_all waits for the drivers being discarded" do
    isolated = browser(%{module: :module_l}, opts(isolate: true))
    Pool.module_finished({:module_l, %{}}, true)
    assert [{pid, _key}] = :sys.get_state(Pool).discarding

    Pool.stop_all()
    refute Process.alive?(pid)
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
