defmodule PlaywrightExTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Selector
  alias PlaywrightEx.TraceHelper

  doctest PlaywrightEx

  @timeout Application.compile_env(:playwright_ex, :timeout)
  @open_trace_viewer_for_manual_inspection false
  @moduletag tmp_dir: @open_trace_viewer_for_manual_inspection

  setup context do
    {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout)
    {:ok, browser_context} = Browser.new_context(browser.guid, timeout: @timeout)
    {:ok, page} = BrowserContext.new_page(browser_context.guid, timeout: @timeout)
    on_exit(fn -> Browser.close(browser.guid, timeout: @timeout) end)

    if @open_trace_viewer_for_manual_inspection do
      TraceHelper.on_exit_open_trace(browser_context.tracing.guid, context.tmp_dir, @timeout)
    end

    [page: page, frame: page.main_frame]
  end

  test "visit elixir-lang.org, then assert and navigate", %{frame: frame} do
    {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)

    assert_has(frame.guid, Selector.role("heading", "Elixir is a dynamic, functional language"))
    refute_has(frame.guid, Selector.role("heading", "I made this up"))

    {:ok, _} = Frame.click(frame.guid, selector: Selector.link("Install"), timeout: @timeout)
    assert_has(frame.guid, Selector.link("macOS"))
  end

  test "mouse API: move, down, up", %{page: page, frame: frame} do
    # Navigate to a page with a clickable link
    {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)

    # Get the bounding box of the link and calculate its center's coordinates
    {:ok, result} =
      Frame.evaluate(frame.guid,
        expression: """
        () => {
          const el = document.querySelector('a[href="/install.html"]');
          const box = el.getBoundingClientRect();
          return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
        }
        """,
        is_function: true,
        timeout: @timeout
      )

    x = result["x"]
    y = result["y"]

    # Test mouse API: move to the link, then click it using mouse down/up
    {:ok, _} = Page.mouse_move(page.guid, x: x, y: y, timeout: @timeout)
    {:ok, _} = Page.mouse_down(page.guid, timeout: @timeout)
    {:ok, _} = Page.mouse_up(page.guid, timeout: @timeout)

    # Verify navigation to install page
    assert_has(frame.guid, Selector.link("By Operating System"))
  end

  test "hover and manual drag with range slider", %{page: page, frame: frame} do
    # Navigate to a blank page and create a range slider
    {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

    {:ok, _} =
      Frame.evaluate(frame.guid,
        expression: """
        () => {
          const slider = document.createElement('input');
          slider.type = 'range';
          slider.id = 'slider';
          slider.min = '0';
          slider.max = '100';
          slider.value = '0';
          slider.style.width = '300px';
          slider.style.margin = '100px';
          document.body.appendChild(slider);
        }
        """,
        is_function: true,
        timeout: @timeout
      )

    # Hover over the slider handle
    {:ok, _} = Frame.hover(frame.guid, selector: "#slider", timeout: @timeout)

    # Get the slider handle's position
    {:ok, handle_pos} =
      Frame.evaluate(frame.guid,
        expression: """
        () => {
          const slider = document.getElementById('slider');
          const box = slider.getBoundingClientRect();
          // For a slider at value 0, the handle is at the left edge
          return { x: box.x, y: box.y + box.height / 2 };
        }
        """,
        is_function: true,
        timeout: @timeout
      )

    # Manual drag: mouse down on handle, drag right, mouse up
    {:ok, _} = Page.mouse_down(page.guid, timeout: @timeout)
    {:ok, _} = Page.mouse_move(page.guid, x: handle_pos["x"] + 150, y: handle_pos["y"], timeout: @timeout)
    {:ok, _} = Page.mouse_up(page.guid, timeout: @timeout)

    # Verify the slider value changed from dragging
    {:ok, final_value} =
      Frame.evaluate(frame.guid,
        expression: "() => document.getElementById('slider').value",
        is_function: true,
        timeout: @timeout
      )

    # The value should have increased from 0 (exact value depends on drag distance)
    assert String.to_integer(final_value) > 0
  end

  defp assert_has(frame_id, selector) do
    assert_expect(frame_id, selector, invert: false)
  end

  defp refute_has(frame_id, selector) do
    assert_expect(frame_id, selector, invert: true)
  end

  defp assert_expect(frame_id, selector, invert: invert?) do
    opts = [selector: selector, is_not: invert?, expression: "to.be.visible", timeout: @timeout]
    {:ok, result} = Frame.expect(frame_id, opts)
    assert result != invert?, "expected#{if invert?, do: " not"} to find #{selector}"
  end

  def on_exit_open_trace(tracing_id, tmp_dir, timeout) do
    {:ok, _} = Tracing.tracing_start(tracing_id, screenshots: true, snapshots: true, sources: true, timeout: timeout)
    {:ok, _} = Tracing.tracing_start_chunk(tracing_id, timeout: timeout)

    ExUnit.Callbacks.on_exit(fn ->
      {:ok, zip_file} = Tracing.tracing_stop_chunk(tracing_id, timeout: timeout)
      {:ok, _} = Tracing.tracing_stop(tracing_id, timeout: timeout)

      trace_file = Path.join(tmp_dir, "trace.zip")
      File.cp!(zip_file.absolute_path, trace_file)

      spawn(fn ->
        executable = :playwright_ex |> Application.fetch_env!(:executable) |> Path.expand()
        System.cmd(executable, ["show-trace", trace_file])
      end)
    end)
  end
end
