defmodule PlaywrightEx.TracingTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.TraceHelper
  alias PlaywrightEx.Tracing

  @timeout Application.compile_env(:playwright_ex, :timeout)

  describe "tracing groups" do
    @tag :tmp_dir
    test "group/3 with nesting", %{tmp_dir: tmp_dir} do
      {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout)
      on_exit(fn -> Browser.close(browser.guid, timeout: @timeout) end)

      {:ok, context} = Browser.new_context(browser.guid, timeout: @timeout)
      if !System.get_env("CI"), do: TraceHelper.on_exit_open_trace(context.tracing.guid, tmp_dir, @timeout)

      {:ok, page} = BrowserContext.new_page(context.guid, timeout: @timeout)
      frame = page.main_frame

      Tracing.group(context.tracing.guid, [name: "Outer Group", timeout: @timeout], fn ->
        {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)

        Tracing.group(
          context.tracing.guid,
          [name: "Inner Group with location", location: [file: __ENV__.file, line: 30], timeout: @timeout],
          fn ->
            {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/blog/", timeout: @timeout)
          end
        )
      end)
    end

    test "group/3 returns function result" do
      {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout)
      on_exit(fn -> Browser.close(browser.guid, timeout: @timeout) end)

      {:ok, context} = Browser.new_context(browser.guid, timeout: @timeout)
      tracing_id = context.tracing.guid

      {:ok, _} = Tracing.tracing_start(tracing_id, screenshots: true, snapshots: true, timeout: @timeout)
      {:ok, _} = Tracing.tracing_start_chunk(tracing_id, timeout: @timeout)

      {:ok, page} = BrowserContext.new_page(context.guid, timeout: @timeout)
      frame = page.main_frame

      result =
        Tracing.group(tracing_id, [name: "Wrapped Navigation", timeout: @timeout], fn ->
          {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)
          :success
        end)

      assert result == :success

      {:ok, zip_file} = Tracing.tracing_stop_chunk(tracing_id, timeout: @timeout)
      {:ok, _} = Tracing.tracing_stop(tracing_id, timeout: @timeout)

      assert File.exists?(zip_file.absolute_path)
    end

    test "group/3 cleans up even when function raises" do
      {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout)
      on_exit(fn -> Browser.close(browser.guid, timeout: @timeout) end)

      {:ok, context} = Browser.new_context(browser.guid, timeout: @timeout)
      tracing_id = context.tracing.guid

      {:ok, _} = Tracing.tracing_start(tracing_id, screenshots: true, snapshots: true, timeout: @timeout)
      {:ok, _} = Tracing.tracing_start_chunk(tracing_id, timeout: @timeout)

      {:ok, page} = BrowserContext.new_page(context.guid, timeout: @timeout)
      frame = page.main_frame

      assert_raise RuntimeError, "intentional error", fn ->
        Tracing.group(tracing_id, [name: "Error Group", timeout: @timeout], fn ->
          {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)
          raise "intentional error"
        end)
      end

      {:ok, zip_file} = Tracing.tracing_stop_chunk(tracing_id, timeout: @timeout)
      {:ok, _} = Tracing.tracing_stop(tracing_id, timeout: @timeout)

      assert File.exists?(zip_file.absolute_path)
    end
  end
end
