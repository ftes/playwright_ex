defmodule PlaywrightExTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Selector
  alias PlaywrightEx.Tracing

  doctest PlaywrightEx

  @open_trace_viewer_for_manual_inspection false
  @moduletag tmp_dir: @open_trace_viewer_for_manual_inspection

  setup context do
    if @open_trace_viewer_for_manual_inspection do
      on_exit_open_trace(context.browser_context.tracing.guid, context.tmp_dir, @timeout)
    end

    :ok
  end

  test "assert and navigate a fixture page", %{frame: frame} do
    set_html(
      frame.guid,
      """
      <style>
        #install { display: none; }
        #install:target { display: block; }
      </style>
      <h1>Playwright Ex is a browser automation client</h1>
      <a href="#install">Install</a>
      <section id="install">
        <a href="#macos">macOS</a>
      </section>
      """
    )

    assert_has(frame.guid, Selector.role("heading", "Playwright Ex is a browser automation client"))
    refute_has(frame.guid, Selector.role("heading", "I made this up"))

    {:ok, _} = Frame.click(frame.guid, selector: Selector.link("Install"), timeout: @timeout)
    assert_has(frame.guid, Selector.link("macOS"))
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
