defmodule PlaywrightEx.Test.IsolateTest do
  # `browser(ctx, isolate: true)` from any test of a module, or from a process given its context
  # map: one driver for the module, taken on first use, as upstream's worker-scoped `browser`
  # fixture is lazy. Its check-in at the module's end: `EndToEndTest`.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Test.Pool

  # The playwright of the module's first test, for the others.
  setup_all do
    :ets.new(__MODULE__, [:named_table, :public])
    :ok
  end

  def workers(ctx), do: Map.get(:sys.get_state(Pool).busy, ctx.playwright_ex_module, [])

  defp first(playwright) do
    :ets.insert_new(__MODULE__, {:first, playwright})
    :ets.lookup_element(__MODULE__, :first, 2)
  end

  for i <- 1..10 do
    test "test #{i} gets the module's one driver", ctx do
      %{playwright: playwright} = browser(ctx, isolate: true)
      assert [_] = workers(ctx)
      assert playwright == first(playwright)
    end
  end

  test "a process given the test's context map gets it too", ctx do
    {:ok, agent} = Agent.start_link(fn -> browser(ctx, isolate: true) end)
    %{playwright: playwright} = Agent.get(agent, & &1)
    assert [_] = workers(ctx)
    assert playwright == first(playwright)
  end

  test "another browser key launches on the module's one driver", ctx do
    %{browser: own} = browser(ctx, isolate: true)
    %{playwright: playwright, browser: browser} = browser(ctx, isolate: true, launch_options: [slow_mo: 1])
    assert browser != own
    assert [_] = workers(ctx)
    assert playwright == first(playwright)
  end
end

defmodule PlaywrightEx.Test.IsolateTest.TwoDrivers do
  # Upstream runs tests with other worker-scoped options in another worker.
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Test.IsolateTest

  test "another driver key takes a driver of its own", ctx do
    a = browser(ctx, isolate: true)
    b = browser(ctx, isolate: true, driver: [env: [{"PW_ISOLATE_TEST", "1"}]])
    assert a.playwright != b.playwright
    assert length(IsolateTest.workers(ctx)) == 2
  end
end

defmodule PlaywrightEx.Test.IsolateTest.NoBrowser do
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  test "a module that asks for no browser holds no driver", ctx do
    assert PlaywrightEx.Test.IsolateTest.workers(ctx) == []
  end
end
