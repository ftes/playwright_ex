defmodule PlaywrightEx.Test.ExclusiveTest do
  # `BrowserPool.exclusive/1` called in `setup_all`: the module holds the browser until it ends.
  # A test's own call is a separate lease (`TestScopeTest`). The release at the scope's end:
  # `BrowserPoolTest`, `EndToEndTest`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Pool

  @opts [driver: [env: [{"PW_EXCLUSIVE_TEST", "module"}]]]

  setup_all do
    browser = BrowserPool.exclusive(@opts)
    again = BrowserPool.exclusive(@opts)
    %{browser: browser, again: again, module_pid: self()}
  end

  def leases(scope), do: Map.get(:sys.get_state(Pool).leases, scope)

  test "setup_all's scope holds one browser across the module's tests, also on a repeated call", ctx do
    assert Browser.is_connected(ctx.browser)
    assert ctx.again == ctx.browser
    assert %{slots: [_]} = leases(ctx.module_pid)
  end

  test "the lease outlives a test of the module", ctx do
    assert %{slots: [_]} = leases(ctx.module_pid)
    assert Browser.is_connected(ctx.browser)
  end
end

defmodule PlaywrightEx.Test.ExclusiveTest.TestScopeTest do
  # Called in a test (or a `Task` of it), the test holds the browser until it ends.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Pool

  @opts [driver: [env: [{"PW_EXCLUSIVE_TEST", "test"}]]]

  defp lease, do: Map.get(:sys.get_state(Pool).leases, self())

  test "a test's call, and its Task's, and repeated calls: one browser of the test's" do
    browser = BrowserPool.exclusive(@opts)
    assert Task.await(Task.async(fn -> BrowserPool.exclusive(@opts) end)) == browser
    assert BrowserPool.exclusive(@opts) == browser
    assert %{slots: [_]} = lease()

    # Another browser key: on the same driver.
    other = BrowserPool.exclusive(Keyword.put(@opts, :launch_options, slow_mo: 1))
    assert other != browser
    assert BrowserPool.playwright(other) == BrowserPool.playwright(browser)
    assert %{slots: [_]} = lease()
  end

  test "another driver key takes a driver of its own" do
    a = BrowserPool.exclusive(@opts)
    b = BrowserPool.exclusive(driver: [env: [{"PW_EXCLUSIVE_TEST", "test 2"}]])
    assert BrowserPool.playwright(a) != BrowserPool.playwright(b)
    assert %{slots: [_, _]} = lease()
    assert Browser.is_connected(a) and Browser.is_connected(b)
  end

  test "a test that asks for none holds none" do
    assert lease() == nil
  end
end

defmodule PlaywrightEx.Test.ExclusiveTest.OutsideTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.BrowserPool

  test "outside ExUnit's processes it raises" do
    test_pid = self()
    spawn(fn -> send(test_pid, {:raised, catch_error(BrowserPool.exclusive())}) end)
    assert_receive {:raised, %ArgumentError{message: "BrowserPool.exclusive/1 is held by a test" <> _}}
  end
end
