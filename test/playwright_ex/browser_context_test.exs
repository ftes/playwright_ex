defmodule PlaywrightEx.BrowserContextTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame

  describe "add_init_script/2" do
    test "applies script to newly created pages", %{browser_context: browser_context} do
      assert {:ok, _} =
               BrowserContext.add_init_script(browser_context.guid,
                 source: "window.__browser_context_add_init_script = 'ok';",
                 timeout: @timeout
               )

      {:ok, page} = BrowserContext.new_page(browser_context.guid, timeout: @timeout)
      {:ok, _} = Frame.goto(page.main_frame.guid, url: "about:blank", timeout: @timeout)

      assert {:ok, "ok"} = eval(page.main_frame.guid, "() => window.__browser_context_add_init_script")
    end
  end

  describe "clock_install/2" do
    test "installs the clock from a DateTime", %{browser_context: browser_context, frame: frame} do
      datetime = ~U[2024-01-02 03:04:05Z]
      expected_now = DateTime.to_unix(datetime, :millisecond)

      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = BrowserContext.clock_install(browser_context.guid, time: datetime, timeout: @timeout)
      assert {:ok, installed_now} = eval(frame.guid, "() => Date.now()")
      assert installed_now in (expected_now - 100)..(expected_now + 100)

      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)

      assert {:ok, advanced_now} = eval(frame.guid, "() => Date.now()")
      assert advanced_now in (expected_now + 60_001)..(expected_now + 60_101)
    end
  end

  describe "clock_fast_forward/2" do
    test "advances Date.now after installing the clock", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, before_now} = eval(frame.guid, "() => Date.now()")

      assert {:ok, _} = BrowserContext.clock_install(browser_context.guid, timeout: @timeout)
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)

      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      assert after_now in (before_now + 60_001)..(before_now + 60_101)
    end

    test "starts the clock near zero without installing first", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, before_now} = eval(frame.guid, "() => Date.now()")

      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)

      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      assert before_now > 1_000_000
      assert after_now in 60_001..60_101
    end

    test "accepts string ticks", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, before_now} = eval(frame.guid, "() => Date.now()")

      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: "01:01", timeout: @timeout)

      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      assert before_now > 1_000_000
      assert after_now in 61_000..61_100
    end
  end
end
