defmodule PlaywrightExTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Selector
  alias PlaywrightEx.Tracing

  doctest PlaywrightEx

  @timeout Application.compile_env(:playwright_ex, :timeout)

  @tag :tmp_dir
  test "visit elixir-lang.org and assert title", %{tmp_dir: tmp_dir} do
    {:ok, browser_id} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout)
    on_exit(fn -> Browser.close(browser_id, timeout: @timeout) end)
    {:ok, context_id} = Browser.new_context(browser_id, timeout: @timeout)
    if !System.get_env("CI"), do: on_exit_open_trace(context_id, tmp_dir)

    {:ok, page_id} = BrowserContext.new_page(context_id, timeout: @timeout)
    frame_id = PlaywrightEx.initializer!(page_id).main_frame.guid
    {:ok, _} = Frame.goto(frame_id, "https://elixir-lang.org/", timeout: @timeout)

    assert_has(frame_id, Selector.role("heading", "Elixir is a dynamic, functional language"))
    refute_has(frame_id, Selector.role("heading", "I made this up"))

    {:ok, _} = Frame.click(frame_id, Selector.link("Install"), timeout: @timeout)
    assert_has(frame_id, Selector.link("macOS"))
  end

  defp assert_has(frame_id, selector) do
    assert_expect(frame_id, selector, invert: false)
  end

  defp refute_has(frame_id, selector) do
    assert_expect(frame_id, selector, invert: true)
  end

  defp assert_expect(frame_id, selector, invert: invert?) do
    {:ok, result} =
      Frame.expect(frame_id, selector: selector, is_not: invert?, expression: "to.be.visible", timeout: @timeout)

    assert result != invert?, "expected#{if invert?, do: " not"} to find #{selector}"
  end

  defp on_exit_open_trace(context_id, tmp_dir) do
    tracing_id = PlaywrightEx.initializer!(context_id).tracing.guid
    {:ok, _} = Tracing.tracing_start(tracing_id, timeout: @timeout)
    {:ok, _} = Tracing.tracing_start_chunk(tracing_id, timeout: @timeout)

    on_exit(fn ->
      {:ok, zip_id} = Tracing.tracing_stop_chunk(tracing_id, timeout: @timeout)
      {:ok, _} = Tracing.tracing_stop(tracing_id, timeout: @timeout)
      zip_path = PlaywrightEx.initializer!(zip_id).absolute_path

      trace_file = Path.join(tmp_dir, "trace.zip")
      File.cp!(zip_path, trace_file)

      spawn(fn ->
        args = ["playwright", "show-trace", trace_file]
        System.cmd("npx", args, cd: "assets")
      end)
    end)
  end
end
