defmodule PlaywrightEx.Test.ScopeTest do
  # `BrowserPool.browser/1` called in `setup_all`: the module holds the browser until it ends,
  # and its tests' own calls go to it. The release at the scope's end: `BrowserPoolTest`,
  # `EndToEndTest`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Pool

  @opts [driver: [env: [{"PW_SCOPE_TEST", "module"}]]]

  setup_all do
    browser = BrowserPool.browser(@opts)
    again = BrowserPool.browser(@opts)
    %{browser: browser, again: again, module_pid: self()}
  end

  def leases(scope), do: Map.get(:sys.get_state(Pool).leases, scope)

  test "setup_all's scope holds one browser across the module's tests, also on a repeated call", ctx do
    assert Browser.is_connected(ctx.browser)
    assert ctx.again == ctx.browser
    # (and the other test's driver key, by the order they run in)
    assert %{slots: [_ | _]} = leases(ctx.module_pid)
  end

  test "a test's calls, and its Task's, go to its module's lease; another key joins it", ctx do
    assert BrowserPool.browser(@opts) == ctx.browser
    assert Task.await(Task.async(fn -> BrowserPool.browser(@opts) end)) == ctx.browser
    other = BrowserPool.browser(Keyword.put(@opts, :launch_options, slow_mo: 1))
    assert BrowserPool.playwright(other) != BrowserPool.playwright(ctx.browser)
    assert leases(self()) == nil
    assert %{slots: [_, _]} = leases(ctx.module_pid)
  end
end

defmodule PlaywrightEx.Test.ScopeTest.TestScopeTest do
  # Called in a test (or a `Task` of it) of a module that holds none, the test holds the
  # browser until it ends.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Pool

  @opts [driver: [env: [{"PW_SCOPE_TEST", "test"}]]]

  defp lease, do: Map.get(:sys.get_state(Pool).leases, self())

  test "a test's call, and its Task's, and repeated calls: one browser of the test's" do
    browser = BrowserPool.browser(@opts)
    assert Task.await(Task.async(fn -> BrowserPool.browser(@opts) end)) == browser
    assert BrowserPool.browser(@opts) == browser
    assert %{slots: [_]} = lease()

    # Other browser options: another worker.
    other = BrowserPool.browser(Keyword.put(@opts, :launch_options, slow_mo: 1))
    assert BrowserPool.playwright(other) != BrowserPool.playwright(browser)
    assert %{slots: [_, _]} = lease()
  end

  test "other driver options take a driver of their own" do
    a = BrowserPool.browser(@opts)
    b = BrowserPool.browser(driver: [env: [{"PW_SCOPE_TEST", "test 2"}]])
    assert BrowserPool.playwright(a) != BrowserPool.playwright(b)
    assert %{slots: [_, _]} = lease()
    assert Browser.is_connected(a) and Browser.is_connected(b)
  end

  test "a test that asks for none holds none" do
    assert lease() == nil
  end
end

defmodule PlaywrightEx.Test.ScopeTest.OutsideTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.BrowserPool

  test "outside ExUnit's processes it raises" do
    test_pid = self()
    spawn(fn -> send(test_pid, {:raised, catch_error(BrowserPool.browser())}) end)
    assert_receive {:raised, %ArgumentError{message: "BrowserPool.browser/1 is held by a test" <> _}}
  end
end
