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
      install_started_at = System.monotonic_time(:millisecond)
      assert {:ok, _} = BrowserContext.clock_install(browser_context.guid, time: datetime, timeout: @timeout)
      assert {:ok, installed_now} = eval(frame.guid, "() => Date.now()")
      install_elapsed = System.monotonic_time(:millisecond) - install_started_at
      assert installed_now in expected_now..(expected_now + install_elapsed + 100)

      fast_forward_started_at = System.monotonic_time(:millisecond)
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)
      assert {:ok, advanced_now} = eval(frame.guid, "() => Date.now()")
      fast_forward_elapsed = System.monotonic_time(:millisecond) - fast_forward_started_at
      assert advanced_now in (installed_now + 60_001)..(installed_now + 60_001 + fast_forward_elapsed + 100)
    end
  end

  describe "clock_fast_forward/2" do
    test "advances Date.now after installing the clock", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = BrowserContext.clock_install(browser_context.guid, timeout: @timeout)
      started_at = System.monotonic_time(:millisecond)
      assert {:ok, installed_now} = eval(frame.guid, "() => Date.now()")
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)
      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      elapsed = System.monotonic_time(:millisecond) - started_at
      assert after_now in (installed_now + 60_001)..(installed_now + 60_001 + elapsed + 100)
    end

    test "starts the clock near zero without installing first", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, before_now} = eval(frame.guid, "() => Date.now()")

      started_at = System.monotonic_time(:millisecond)
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)
      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      elapsed = System.monotonic_time(:millisecond) - started_at
      assert before_now > 1_000_000
      assert after_now in 60_001..(60_001 + elapsed + 100)
    end

    test "accepts string ticks", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, before_now} = eval(frame.guid, "() => Date.now()")

      started_at = System.monotonic_time(:millisecond)
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: "01:01", timeout: @timeout)
      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      elapsed = System.monotonic_time(:millisecond) - started_at
      assert before_now > 1_000_000
      assert after_now in 61_000..(61_000 + elapsed + 100)
    end
  end
end
