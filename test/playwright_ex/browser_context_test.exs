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

  describe "clock_fast_forward/2" do
    test "advances Date.now after installing the clock", %{browser_context: browser_context, frame: frame} do
      assert_clock_advanced_from_current_time(browser_context.guid, frame.guid, ticks: 60_001)
    end

    test "starts the clock near zero without installing first", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, before_now} = eval(frame.guid, "() => Date.now()")

      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)

      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      assert before_now > 1_000_000
      assert after_now >= 60_001
      assert after_now < before_now
    end

    test "accepts string ticks", %{browser_context: browser_context, frame: frame} do
      assert_clock_advanced_from_current_time(browser_context.guid, frame.guid, ticks: "01:01", expected_delta: 61_000)
    end
  end

  defp assert_clock_advanced_from_current_time(context_id, frame_id, opts) do
    opts = Keyword.validate!(opts, [:ticks, expected_delta: nil])
    expected_delta = opts[:expected_delta] || opts[:ticks]

    assert {:ok, _} = Frame.goto(frame_id, url: "about:blank", timeout: @timeout)
    assert {:ok, before_now} = eval(frame_id, "() => Date.now()")

    assert {:ok, _} = BrowserContext.clock_install(context_id, timeout: @timeout)
    assert {:ok, _} = BrowserContext.clock_fast_forward(context_id, ticks: opts[:ticks], timeout: @timeout)

    assert {:ok, after_now} = eval(frame_id, "() => Date.now()")
    assert after_now >= before_now + expected_delta
  end
end
